// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的离屏宿主：浮窗不用 winit 的窗口，而是用 Slint 的软件渲染器画进内存，由应用层交给 Win32 的分层窗口
// （UpdateLayeredWindow，逐像素 alpha）显示。这样才能做到 macOS 的观感（8.4 节、Q21）：
// - 背景半透明、圆角处透明，文字始终不透明。winit 的软件渲染在 Windows 上用 BitBlt 提交，没有 alpha 通道，
//   透明处会变成黑色；整窗透明度（LWA_ALPHA）又会让文字一起变淡。
// - 窗口的样式（不抢焦点、不进任务栏、置顶）完全由应用层的 Win32 代码决定，不受 winit 的默认值影响。
//
// 做法：
// - 建 OverlayWindow 之前把一个 MinimalSoftwareWindow 放进线程局部的「待用适配器」，平台的 create_window_adapter
//   先取它（应用里是包了一层 winit 后端的平台，截图与测试里是 screenshot 模块的 Headless）。
// - 应用层把 Win32 窗口收到的鼠标输入按物理像素交进来，这里换成逻辑坐标的 Slint 事件。
// - render 在 Slint 请求重画时把画面画进缓冲区（只重画变化的区域），再转成 Win32 要的 BGRA（预乘 alpha）。
//
// 只在主线程上用；Slint 的组件与窗口都不能跨线程。

//! 浮窗的离屏宿主。

use std::cell::RefCell;
use std::rc::Rc;

use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType};
use slint::platform::{PointerEventButton, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, LogicalPosition, PhysicalSize, PlatformError};

use eveo_core::model::AppLanguage;

use super::OverlayView;
use crate::OverlayWindow;

/// 滚轮一格（WHEEL_DELTA，120）滚动的逻辑像素，与 Slint 的 winit 后端一致（一行 60）。
pub const WHEEL_STEP: f32 = 60.0;

/// 滚轮数值的一格。
const WHEEL_DELTA: f32 = 120.0;

thread_local! {
    /// 待用的窗口适配器：下一个建出的 Slint 组件用它，而不是平台默认的窗口。用一次即清空。
    static PENDING: RefCell<Option<Rc<dyn WindowAdapter>>> = const { RefCell::new(None) };
}

/// 取走待用的窗口适配器。平台的 create_window_adapter 先调它，有就用它。
pub fn take_pending_adapter() -> Option<Rc<dyn WindowAdapter>> {
    PENDING.with(|cell| cell.borrow_mut().take())
}

/// 一个浮窗的离屏宿主：Slint 组件、它的软件渲染窗口、内容视图与画面缓冲区。
pub struct OverlayHost {
    /// 软件渲染窗口，组件画在它上面。
    adapter: Rc<MinimalSoftwareWindow>,
    /// 内容视图。
    view: Rc<RefCell<OverlayView>>,
    /// 渲染器写的缓冲区（预乘 RGBA），在两次重画之间保留，渲染器只重画变化的区域。
    pixels: Vec<PremultipliedRgbaColor>,
    /// 交给 Win32 的缓冲区（预乘 BGRA，自上而下）。
    bgra: Vec<u8>,
    /// 物理像素的宽与高。
    size: (u32, u32),
    /// 缩放比例（DPI ÷ 96）。
    scale: f32,
}

impl OverlayHost {
    /// 建宿主：软件渲染窗口、浮窗组件与内容视图。尺寸先是 1×1，应用层随后按规划结果设。
    pub fn new(language: AppLanguage) -> Result<Self, PlatformError> {
        // ReusedBuffer：缓冲区在两次重画之间保留，渲染器只重画变化的区域（新消息、悬停变化）。
        let adapter = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
        PENDING.with(|cell| *cell.borrow_mut() = Some(adapter.clone()));
        let window = OverlayWindow::new();
        // 建组件失败时平台没有取走它，这里清掉，不留给下一个组件。
        PENDING.with(|cell| cell.borrow_mut().take());
        let window = window?;
        window.show()?;
        let view = OverlayView::attach(window, language);
        let mut host = Self {
            adapter,
            view,
            pixels: Vec::new(),
            bgra: Vec::new(),
            size: (0, 0),
            scale: 1.0,
        };
        host.resize(1, 1, 1.0);
        Ok(host)
    }

    /// 内容视图。
    pub fn view(&self) -> &Rc<RefCell<OverlayView>> {
        &self.view
    }

    /// 物理像素的宽与高。
    pub fn size(&self) -> (u32, u32) {
        self.size
    }

    /// 设尺寸（物理像素）与缩放比例；有变化时清空缓冲区并整幅重画。
    pub fn resize(&mut self, width: u32, height: u32, scale: f32) {
        let (width, height) = (width.max(1), height.max(1));
        if (width, height) == self.size && scale == self.scale {
            return;
        }
        if scale != self.scale {
            self.adapter
                .dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor: scale });
        }
        self.size = (width, height);
        self.scale = scale;
        self.adapter.set_size(PhysicalSize::new(width, height));
        let count = width as usize * height as usize;
        self.pixels = vec![PremultipliedRgbaColor::default(); count];
        self.bgra = vec![0; count * 4];
        self.adapter.request_redraw();
    }

    /// Slint 请求过重画时（内容、悬停、滚动变了）画一帧。返回新画面（预乘 BGRA，自上而下，宽 × 高 × 4 字节）；
    /// 没有变化时返回 None，应用层不必再提交。
    pub fn render(&mut self) -> Option<&[u8]> {
        let width = self.size.0 as usize;
        let pixels = &mut self.pixels;
        let drew = self.adapter.draw_if_needed(|renderer| {
            renderer.render(pixels, width);
        });
        if !drew {
            return None;
        }
        to_bgra(&self.pixels, &mut self.bgra);
        Some(&self.bgra)
    }

    /// 光标移到 (x, y)：相对窗口左上角的物理像素。
    pub fn pointer_moved(&self, x: f64, y: f64) {
        let position = self.logical(x, y);
        self.adapter
            .dispatch_event(WindowEvent::PointerMoved { position });
    }

    /// 光标离开窗口：Slint 清掉悬停状态（hovered-row 回到 -1、新消息条的悬停色）。
    pub fn pointer_exited(&self) {
        self.adapter.dispatch_event(WindowEvent::PointerExited);
    }

    /// 左键按下或松开（点新消息条）。右键与拖动由应用层的手势处理，不交给 Slint。
    pub fn left_button(&self, x: f64, y: f64, pressed: bool) {
        let position = self.logical(x, y);
        let button = PointerEventButton::Left;
        self.adapter.dispatch_event(if pressed {
            WindowEvent::PointerPressed { position, button }
        } else {
            WindowEvent::PointerReleased { position, button }
        });
    }

    /// 滚轮：wheel_delta 是 WM_MOUSEWHEEL 的数值，向前滚为正（列表往上翻）。
    pub fn wheel(&self, x: f64, y: f64, wheel_delta: i32) {
        let position = self.logical(x, y);
        let delta_y = wheel_delta as f32 / WHEEL_DELTA * WHEEL_STEP;
        self.adapter.dispatch_event(WindowEvent::PointerScrolled {
            position,
            delta_x: 0.0,
            delta_y,
        });
    }

    /// 光标下那一行的下标；不在任何一行上时为 None。
    pub fn hovered_row(&self) -> Option<usize> {
        usize::try_from(self.view.borrow().window().get_hovered_row()).ok()
    }

    /// 物理像素换成逻辑坐标。
    fn logical(&self, x: f64, y: f64) -> LogicalPosition {
        LogicalPosition::new(x as f32 / self.scale, y as f32 / self.scale)
    }
}

/// 预乘的 RGBA 换成预乘的 BGRA（32 位 DIB 的字节顺序）。out 的长度是 pixels 的 4 倍。
pub fn to_bgra(pixels: &[PremultipliedRgbaColor], out: &mut [u8]) {
    // as_chunks_mut 把字节切成定长的 [u8; 4]，编译器能省掉每个像素的边界检查；不足 4 字节的尾巴不会出现。
    let (chunks, _) = out.as_chunks_mut::<4>();
    for (pixel, chunk) in pixels.iter().zip(chunks) {
        *chunk = [pixel.blue, pixel.green, pixel.red, pixel.alpha];
    }
}
