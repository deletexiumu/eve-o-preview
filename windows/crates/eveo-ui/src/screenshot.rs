// SPDX-License-Identifier: GPL-3.0-or-later
//
// 无窗口截图（架构文档 8.4 节的界面截图回归）：用 Slint 的软件渲染器把界面画进内存，再编码成 PNG。
// 不需要显示器，Linux 容器与 CI 都能跑；云端改界面时直接看图。
// Slint 的平台每个进程只能设一次，所以这里的窗口放在线程局部变量里，各次截图共用。

//! 用软件渲染器把界面画成 PNG。

use std::cell::RefCell;
use std::rc::Rc;

use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, PhysicalSize, PlatformError};

use crate::SettingsWindow;

/// 一次截图的设定。
#[derive(Debug, Clone)]
pub struct ShotOptions {
    /// 暗色外观。
    pub dark: bool,
    /// 逻辑尺寸（与 Windows 100% 缩放时的像素相同）。
    pub size: (u32, u32),
    /// 缩放比例，1.5 对应 Windows 的 150%。
    pub scale: f32,
    /// 界面字体。Windows 上是 Segoe UI Variable；Linux 截图用装着的近似字体。
    pub font: String,
}

/// 只给软件渲染器用的平台。
struct Headless {
    window: Rc<MinimalSoftwareWindow>,
}

impl Platform for Headless {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        Ok(self.window.clone())
    }
}

thread_local! {
    /// 本线程的软件渲染窗口；第一次截图时创建并设为 Slint 的平台。
    static WINDOW: RefCell<Option<Rc<MinimalSoftwareWindow>>> = const { RefCell::new(None) };
}

/// 取（或创建）软件渲染窗口。
fn window() -> Result<Rc<MinimalSoftwareWindow>, String> {
    WINDOW.with(|cell| {
        if let Some(window) = cell.borrow().as_ref() {
            return Ok(window.clone());
        }
        let window = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
        slint::platform::set_platform(Box::new(Headless {
            window: window.clone(),
        }))
        .map_err(|e| format!("设置 Slint 平台失败：{e}"))?;
        *cell.borrow_mut() = Some(window.clone());
        Ok(window)
    })
}

/// 设好软件渲染平台（每个进程一次），单元测试建窗口前调用。
#[cfg(test)]
pub(crate) fn ensure_platform() -> Result<(), String> {
    window().map(|_| ())
}

/// 把设置窗口画成 PNG，返回文件内容。
pub fn settings_png(options: &ShotOptions) -> Result<Vec<u8>, String> {
    let window = window()?;
    // 先设缩放比例，再按物理像素设窗口大小：逻辑尺寸乘缩放比例。
    window.dispatch_event(WindowEvent::ScaleFactorChanged {
        scale_factor: options.scale,
    });
    // 每次截图新建组件，明暗与字体互不影响。
    let ui = SettingsWindow::new().map_err(|e| e.to_string())?;
    ui.set_dark(options.dark);
    ui.set_ui_font(options.font.as_str().into());
    // 各页显示一个新配置方案的默认值，与第一次打开应用时看到的一样。
    crate::bind::show_previews(&ui, &eveo_core::model::Profile::make_new("shot", "Default"));
    let width = (options.size.0 as f32 * options.scale).round() as u32;
    let height = (options.size.1 as f32 * options.scale).round() as u32;
    window.set_size(PhysicalSize::new(width, height));
    ui.show().map_err(|e| e.to_string())?;
    // 推进一次定时器与动画，让 init 与 changed 回调里改的状态（如明暗配色）生效。
    slint::platform::update_timers_and_animations();
    // NewBuffer：每次都整幅重画，不依赖上一帧的内容。
    let mut pixels = vec![PremultipliedRgbaColor::default(); width as usize * height as usize];
    window.request_redraw();
    window.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, width as usize);
    });
    // 隐藏后组件释放，下一次截图从干净的状态开始。
    ui.hide().map_err(|e| e.to_string())?;
    encode(&pixels, width, height)
}

/// 预乘的 RGBA → PNG。
fn encode(pixels: &[PremultipliedRgbaColor], width: u32, height: u32) -> Result<Vec<u8>, String> {
    // PNG 要的是非预乘的 RGBA；完全透明的像素颜色无意义，写成 0。
    let mut rgba = Vec::with_capacity(pixels.len() * 4);
    for p in pixels {
        let unpremultiply = |c: u8| match p.alpha {
            0 => 0,
            a => ((u16::from(c) * 255 + u16::from(a) / 2) / u16::from(a)).min(255) as u8,
        };
        rgba.extend_from_slice(&[
            unpremultiply(p.red),
            unpremultiply(p.green),
            unpremultiply(p.blue),
            p.alpha,
        ]);
    }
    // 8 位 RGBA，不压缩调优，截图工具不在意体积。
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
        writer.write_image_data(&rgba).map_err(|e| e.to_string())?;
    }
    Ok(out)
}
