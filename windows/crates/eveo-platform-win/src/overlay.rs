// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的叠加层（架构文档 4.2 节），对应 macOS 内容视图里画面之上的几层：占位、标题、跳过标记、战斗提醒。
// DWM 把缩略图画面合成在窗口客户区的最上面，窗口自己用 GDI 画的东西都会被它盖住，所以叠加层是另一个窗口：
// - 分层窗口（WS_EX_LAYERED）用 UpdateLayeredWindow 提交逐像素透明的位图，文字与圆角都有抗锯齿；
// - WS_EX_TRANSPARENT 让鼠标穿透到下面的缩略图窗口，手势仍由缩略图窗口处理；
// - 由缩略图窗口拥有（owner）：系统让它始终在主人之上，主人置顶时它也置顶；显隐与位置由主人同步。
// 位图用 Direct2D 画到 32 位 DIB 上（预乘 alpha），文字用 DirectWrite，中文等字形由系统字体回退补齐。
// 内容没变、尺寸没变时不重画；只移动时只挪窗口。提醒的闪烁由调用方逐帧改强度，每帧重画一次。
//
// 几个没有采用的做法，以及原因：
// - 子窗口：DWM 缩略图画在整个窗口（含子窗口）之上，子窗口同样会被盖住，只能用另一个顶层窗口。
// - 颜色键透明（LWA_COLORKEY，上游 Windows 版的做法）：只有全透明与不透明两档，
//   文字与圆角的抗锯齿边缘会混进键色，出现彩色毛边；半透明的标题底与提醒底色也画不出来。
// - GDI 画字：GDI 不写 alpha 通道，画到 32 位位图上的文字整体透明，需要逐像素补 alpha。
// - HWND 渲染目标：分层窗口用 UpdateLayeredWindow 提交内容后不再收 WM_PAINT，HWND 目标没有地方画，
//   所以用 DC 渲染目标画到内存 DC，再由同一个 DC 提交。

//! 缩略图上的叠加层窗口。

use std::cell::RefCell;
use std::collections::HashMap;

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D_RECT_F, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1_DRAW_TEXT_OPTIONS_CLIP, D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_FEATURE_LEVEL_DEFAULT,
    D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE,
    D2D1_ROUNDED_RECT, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE, D2D1CreateFactory, ID2D1DCRenderTarget,
    ID2D1Factory,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
    DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_MEASURING_MODE_NATURAL,
    DWRITE_PARAGRAPH_ALIGNMENT_CENTER, DWRITE_PARAGRAPH_ALIGNMENT_NEAR, DWRITE_TEXT_ALIGNMENT_CENTER,
    DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_TEXT_METRICS, DWRITE_TRIMMING,
    DWRITE_TRIMMING_GRANULARITY_CHARACTER, DWRITE_WORD_WRAPPING_NO_WRAP, DWRITE_WORD_WRAPPING_WRAP,
    DWriteCreateFactory, IDWriteFactory, IDWriteTextFormat,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION, CreateCompatibleDC,
    CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, HBRUSH, ReleaseDC, SelectObject,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, HTTRANSPARENT, MA_NOACTIVATE, SPI_GETCLIENTAREAANIMATION,
    SW_HIDE, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetWindowPos, ShowWindow, SystemParametersInfoW, ULW_ALPHA,
    UpdateLayeredWindow, WM_MOUSEACTIVATE, WM_NCHITTEST, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    WS_EX_TRANSPARENT, WS_POPUP,
};
use windows::core::{PCWSTR, Result, w};

use crate::{text::wide, window_class};

/// 叠加层窗口的类名；探针按它找叠加层。
pub const OVERLAY_CLASS: &str = "EVEOPreview.Overlay";

/// 标题：左上角的角色名，带半透明的圆角底。
#[derive(Debug, Clone, PartialEq)]
pub struct OverlayTitle {
    /// 文字。
    pub text: String,
    /// 字号，DIP（与 macOS 的点相同），画的时候乘以缩放。
    pub size: f32,
    /// 文字颜色，`0xRRGGBB`。
    pub color: u32,
}

/// 战斗提醒：一圈边框和（或）一层底色，按强度闪烁。
#[derive(Debug, Clone, PartialEq)]
pub struct OverlayAlert {
    /// 颜色，`0xRRGGBB`。
    pub color: u32,
    /// 是否画边框。
    pub border: bool,
    /// 是否铺底色。
    pub wash: bool,
    /// 当前强度，0～1；闪烁时由调用方逐帧改变。
    pub intensity: f32,
}

/// 叠加层上要画的全部内容。各项都没有时窗口隐藏，不占合成开销。
#[derive(Debug, Clone, PartialEq)]
pub struct OverlayContent {
    /// 标题；`None` 表示不显示。
    pub title: Option<OverlayTitle>,
    /// 是否显示跳过标记（右上角的红色禁行符号）。
    pub skipped: bool,
    /// 占位说明；`None` 表示不显示占位。有占位时整块铺一层深色半透明底。
    pub placeholder: Option<String>,
    /// 战斗提醒；`None` 表示没有。
    pub alert: Option<OverlayAlert>,
    /// 所在显示器的缩放（1.0 = 96 DPI），字号、边距与粗细都乘以它。
    pub scale: f32,
}

impl Default for OverlayContent {
    fn default() -> Self {
        Self {
            title: None,
            skipped: false,
            placeholder: None,
            alert: None,
            scale: 1.0,
        }
    }
}

impl OverlayContent {
    /// 是否什么都不用画。
    pub fn is_empty(&self) -> bool {
        self.title.is_none() && !self.skipped && self.placeholder.is_none() && self.alert.is_none()
    }
}

/// 一个叠加层窗口。丢弃时销毁窗口。
pub struct OverlayWindow {
    /// 窗口句柄。
    hwnd: HWND,
    /// 位置与尺寸（物理像素）：x, y, 宽, 高。
    frame: (i32, i32, i32, i32),
    /// 主人是否显示着。主人隐藏时叠加层也隐藏：被拥有的窗口不会随主人的 SW_HIDE 自动隐藏
    /// （只随主人最小化而隐藏），要由这里跟着同步。
    owner_shown: bool,
    /// 要画的内容。
    content: OverlayContent,
    /// 当前位图是否就是按 `content` 与当前尺寸画的。
    rendered: bool,
    /// 窗口此刻是否可见。
    visible: bool,
    /// 整体不透明度（0～255），跟着主人的不透明度走，提交位图时作为常量 alpha。
    alpha: u8,
}

impl OverlayWindow {
    /// 建一个属于 `owner` 的叠加层窗口，先隐藏，有内容时才显示。
    pub fn create(owner: HWND) -> Result<Self> {
        let class = window_class::ensure(OVERLAY_CLASS, Some(window_proc), HBRUSH::default())?;
        let title = wide("EVE-O Preview overlay");
        // SAFETY: 类名与标题的缓冲区在调用期间有效；owner 是本线程的窗口。
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                PCWSTR(class.as_ptr()),
                PCWSTR(title.as_ptr()),
                WS_POPUP,
                0,
                0,
                0,
                0,
                Some(owner),
                None,
                Some(window_class::instance()?),
                None,
            )?
        };
        Ok(Self {
            hwnd,
            frame: (0, 0, 0, 0),
            owner_shown: true,
            content: OverlayContent::default(),
            rendered: false,
            visible: false,
            alpha: 255,
        })
    }

    /// 跟着主人移动与缩放。尺寸变了要重画；只移动时直接挪窗口。
    pub fn set_frame(&mut self, frame: (i32, i32, i32, i32)) {
        if frame == self.frame {
            return;
        }
        let resized = (frame.2, frame.3) != (self.frame.2, self.frame.3);
        self.frame = frame;
        if resized {
            self.rendered = false;
        } else if self.visible {
            // 只移动时位图不变：系统保留最近一次提交的位图，挪窗口即可，拖动缩略图时每次鼠标移动都走这里。
            // SAFETY: 窗口属于本线程；只改位置，不改大小、层次，不激活。
            let _ = unsafe {
                SetWindowPos(
                    self.hwnd,
                    None,
                    frame.0,
                    frame.1,
                    0,
                    0,
                    SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
                )
            };
            return;
        }
        self.refresh();
    }

    /// 跟着主人显示或隐藏。
    pub fn set_owner_shown(&mut self, shown: bool) {
        if shown != self.owner_shown {
            self.owner_shown = shown;
            self.refresh();
        }
    }

    /// 换内容；与上次相同时什么也不做。
    pub fn set_content(&mut self, content: OverlayContent) {
        if content != self.content {
            self.content = content;
            self.rendered = false;
            self.refresh();
        }
    }

    /// 设整体不透明度。变了要重新提交：常量 alpha 是 UpdateLayeredWindow 的参数，随位图一起给。
    pub fn set_alpha(&mut self, alpha: u8) {
        if alpha != self.alpha {
            self.alpha = alpha;
            self.rendered = false;
            self.refresh();
        }
    }

    /// 窗口句柄，探针与测试用来核对位置。
    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }

    /// 按主人的显隐、内容与尺寸决定是否显示，需要时重画。
    ///
    /// 先画后显示：分层窗口在第一次 UpdateLayeredWindow 之前什么也不显示，
    /// 内容或尺寸变化后若先显示再画，会有一帧看到旧的位图被拉到新尺寸上。
    /// 隐藏期间内容变了只记下来（rendered 置假），到再次显示时才画，隐藏的缩略图不花渲染的开销。
    fn refresh(&mut self) {
        let (_, _, width, height) = self.frame;
        let wanted = self.owner_shown && !self.content.is_empty() && width > 0 && height > 0;
        if wanted && !self.rendered {
            // 画失败（例如显卡驱动重置）时保持隐藏，下次内容或尺寸变化再试。
            self.rendered = render(self.hwnd, self.frame, &self.content, self.alpha).is_ok();
        }
        let visible = wanted && self.rendered;
        if visible != self.visible {
            self.visible = visible;
            let command = if visible { SW_SHOWNOACTIVATE } else { SW_HIDE };
            // SAFETY: 窗口属于本线程。
            let _ = unsafe { ShowWindow(self.hwnd, command) };
        }
    }
}

impl Drop for OverlayWindow {
    fn drop(&mut self) {
        // SAFETY: 窗口由 create 建立，只销毁一次；主人先销毁时这里返回错误，无害。
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// 系统是否允许界面动画（「设置 → 辅助功能 → 动画效果」）。关掉时提醒静止显示，不闪烁。
pub fn animations_enabled() -> bool {
    let mut enabled = windows::core::BOOL(1);
    // SAFETY: 输出位置是一个 BOOL，与 SPI_GETCLIENTAREAANIMATION 要求的类型一致。
    let read = unsafe {
        SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some((&raw mut enabled).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    read.is_err() || enabled.as_bool()
}

/// 窗口过程：不被鼠标激活，命中测试一律穿透。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        // SAFETY: 参数原样转交。
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// Direct2D 与 DirectWrite 的对象，每个线程建一份（叠加层窗口都在主线程上）。
struct Renderer {
    /// Direct2D 工厂。
    d2d: ID2D1Factory,
    /// DirectWrite 工厂。
    dwrite: IDWriteFactory,
    /// 画到 GDI 设备上下文的渲染目标；设备丢失时丢弃重建。
    target: Option<ID2D1DCRenderTarget>,
    /// 文本格式缓存，键是（字号的位模式，是否标题）。
    /// 字号只随设置与显示器缩放变化，实际只有几项，不需要淘汰。
    formats: HashMap<(u32, bool), IDWriteTextFormat>,
}

thread_local! {
    /// 本线程的渲染器；第一次画时建立。
    static RENDERER: RefCell<Option<Renderer>> = const { RefCell::new(None) };
}

/// 把内容画成位图并提交给分层窗口，位置与尺寸取 `frame`。
fn render(hwnd: HWND, frame: (i32, i32, i32, i32), content: &OverlayContent, alpha: u8) -> Result<()> {
    RENDERER.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            *slot = Some(Renderer::new()?);
        }
        let renderer = slot.as_mut().expect("刚建好");
        let result = renderer.render(hwnd, frame, content, alpha);
        if result.is_err() {
            // 设备丢失等错误：丢掉渲染目标，下次重建。
            renderer.target = None;
        }
        result
    })
}

impl Renderer {
    /// 建两个工厂。
    fn new() -> Result<Self> {
        // SAFETY: 工厂函数没有指针参数，返回的接口由 windows crate 管理引用计数。
        let d2d: ID2D1Factory = unsafe { D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)? };
        // SAFETY: 同上。
        let dwrite: IDWriteFactory = unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)? };
        Ok(Self {
            d2d,
            dwrite,
            target: None,
            formats: HashMap::new(),
        })
    }

    /// 取渲染目标：BGRA、预乘 alpha，按 96 DPI 工作（坐标就是物理像素，缩放由调用方乘）。
    fn target(&mut self) -> Result<ID2D1DCRenderTarget> {
        if let Some(target) = &self.target {
            return Ok(target.clone());
        }
        let properties = D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: 96.0,
            dpiY: 96.0,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        // SAFETY: 属性结构在调用期间有效。
        let target = unsafe { self.d2d.CreateDCRenderTarget(&properties)? };
        // SAFETY: 渲染目标刚建好。透明底上不能用 ClearType（它按子像素混色，需要不透明的底）。
        unsafe { target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE) };
        self.target = Some(target.clone());
        Ok(target)
    }

    /// 取文本格式。标题：半粗、不换行、超长时以省略号截断；占位：常规、居中、可换行。
    fn format(&mut self, size: f32, title: bool) -> Result<IDWriteTextFormat> {
        let key = (size.to_bits(), title);
        if let Some(format) = self.formats.get(&key) {
            return Ok(format.clone());
        }
        let weight = if title {
            DWRITE_FONT_WEIGHT_SEMI_BOLD
        } else {
            DWRITE_FONT_WEIGHT_NORMAL
        };
        // SAFETY: 字体名与区域名是静态的宽字符串；返回的接口由 windows crate 管理。
        let format = unsafe {
            self.dwrite.CreateTextFormat(
                w!("Segoe UI"),
                None,
                weight,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                size,
                w!("zh-CN"),
            )?
        };
        // SAFETY: format 刚建好；修剪设置结构在调用期间有效。
        unsafe {
            if title {
                format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
                format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING)?;
                format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR)?;
                let sign = self.dwrite.CreateEllipsisTrimmingSign(&format)?;
                let trimming = DWRITE_TRIMMING {
                    granularity: DWRITE_TRIMMING_GRANULARITY_CHARACTER,
                    delimiter: 0,
                    delimiterCount: 0,
                };
                format.SetTrimming(&trimming, &sign)?;
            } else {
                format.SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP)?;
                format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER)?;
                format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
            }
        }
        self.formats.insert(key, format.clone());
        Ok(format)
    }

    /// 文字在一行里的宽与高（像素）。
    fn measure(&self, text: &[u16], format: &IDWriteTextFormat) -> Result<(f32, f32)> {
        // SAFETY: text 与 format 在调用期间有效；metrics 是有效的输出位置。
        unsafe {
            let layout = self.dwrite.CreateTextLayout(text, format, f32::MAX, f32::MAX)?;
            let mut metrics = DWRITE_TEXT_METRICS::default();
            layout.GetMetrics(&mut metrics)?;
            Ok((metrics.widthIncludingTrailingWhitespace, metrics.height))
        }
    }

    /// 建 DIB、画、提交给分层窗口，最后释放 GDI 对象。
    ///
    /// DIB 每次现建现删：一个 480×270 的缩略图约 0.5 MB，建一次的开销远小于画，
    /// 不缓存也就不必跟踪尺寸变化。UpdateLayeredWindow 会把位图复制给系统，返回后即可释放。
    fn render(
        &mut self,
        hwnd: HWND,
        frame: (i32, i32, i32, i32),
        content: &OverlayContent,
        alpha: u8,
    ) -> Result<()> {
        let (x, y, width, height) = frame;
        let target = self.target()?;
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                // 负的高度表示从上到下的位图，与 Direct2D 的坐标方向一致。
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        // SAFETY: 设备上下文与位图在本块内创建，按相反的顺序释放；info 在调用期间有效。
        // 渲染目标绑定到内存 DC，画完再用同一个 DC 提交给分层窗口。
        unsafe {
            let screen = GetDC(None);
            let memory = CreateCompatibleDC(Some(screen));
            let mut bits = std::ptr::null_mut();
            let bitmap = CreateDIBSection(Some(memory), &info, DIB_RGB_COLORS, &mut bits, None, 0);
            let result = match bitmap {
                Ok(bitmap) => {
                    let previous = SelectObject(memory, bitmap.into());
                    let bounds = RECT {
                        left: 0,
                        top: 0,
                        right: width,
                        bottom: height,
                    };
                    let drawn = target
                        .BindDC(memory, &bounds)
                        .and_then(|()| self.draw(&target, (width as f32, height as f32), content));
                    let committed = drawn.and_then(|()| {
                        let blend = BLENDFUNCTION {
                            BlendOp: AC_SRC_OVER as u8,
                            BlendFlags: 0,
                            SourceConstantAlpha: alpha,
                            AlphaFormat: AC_SRC_ALPHA as u8,
                        };
                        UpdateLayeredWindow(
                            hwnd,
                            Some(screen),
                            Some(&POINT { x, y }),
                            Some(&SIZE {
                                cx: width,
                                cy: height,
                            }),
                            Some(memory),
                            Some(&POINT::default()),
                            COLORREF(0),
                            Some(&blend),
                            ULW_ALPHA,
                        )
                    });
                    SelectObject(memory, previous);
                    let _ = DeleteObject(bitmap.into());
                    committed
                }
                Err(error) => Err(error),
            };
            let _ = DeleteDC(memory);
            ReleaseDC(None, screen);
            result
        }
    }

    /// 按从下到上的顺序画：占位、标题、跳过标记、提醒（与 macOS 的图层顺序一致，提醒在最上面）。
    fn draw(
        &mut self,
        target: &ID2D1DCRenderTarget,
        size: (f32, f32),
        content: &OverlayContent,
    ) -> Result<()> {
        let scale = content.scale.max(0.5);
        // SAFETY: 渲染目标已绑定到有效的 DC；BeginDraw 与 EndDraw 成对出现。
        unsafe {
            target.BeginDraw();
            target.Clear(Some(&color(0, 0.0)));
        }
        let drawn = self.draw_layers(target, size, scale, content);
        // SAFETY: 与上面的 BeginDraw 配对；EndDraw 的错误（例如设备丢失）由调用方重建渲染目标。
        let ended = unsafe { target.EndDraw(None, None) };
        drawn.and(ended)
    }

    /// 逐层画；任何一步失败都返回错误，但 EndDraw 仍由调用方执行。
    fn draw_layers(
        &mut self,
        target: &ID2D1DCRenderTarget,
        (width, height): (f32, f32),
        scale: f32,
        content: &OverlayContent,
    ) -> Result<()> {
        let full = rect(0.0, 0.0, width, height);
        if let Some(text) = &content.placeholder {
            // 深色半透明底：最小化时还能隐约看到最后一帧。
            fill(target, &full, color(0x14_14_14, 0.85))?;
            let format = self.format(12.0 * scale, false)?;
            let inset = 8.0 * scale;
            let area = rect(inset, 0.0, (width - inset).max(inset), height);
            draw_text(target, &wide_text(text), &format, &area, color(0xD9_D9_D9, 1.0))?;
        }
        if let Some(title) = &content.title {
            self.draw_title(target, width, scale, title)?;
        }
        if content.skipped {
            draw_skip_badge(target, width, height, scale)?;
        }
        if let Some(alert) = &content.alert {
            let intensity = alert.intensity.clamp(0.0, 1.0);
            if alert.wash {
                fill(target, &full, color(alert.color, 0.25 * intensity))?;
            }
            if alert.border {
                // 4 DIP 的边框完整落在窗口内：描边以矩形边为中线，所以向内缩进半个粗细。
                let stroke = 4.0 * scale;
                let half = stroke / 2.0;
                let edge = rect(half, half, width - half, height - half);
                let brush = brush(target, color(alert.color, intensity))?;
                // SAFETY: 矩形与画刷在调用期间有效。
                unsafe { target.DrawRectangle(&edge, &brush, stroke, None) };
            }
        }
        Ok(())
    }

    /// 左上角的标题：底按文字宽度收缩，最宽到窗口宽度减去两侧边距，超出部分以省略号截断。
    fn draw_title(
        &mut self,
        target: &ID2D1DCRenderTarget,
        width: f32,
        scale: f32,
        title: &OverlayTitle,
    ) -> Result<()> {
        let format = self.format(title.size.max(1.0) * scale, true)?;
        let text = wide_text(&title.text);
        // 量的是不换行时整行的宽度（含结尾空格），底的宽度据此收缩；超出可用宽度时由格式的省略号截断。
        let (text_width, text_height) = self.measure(&text, &format)?;
        let margin = 4.0 * scale;
        let padding = 5.0 * scale;
        let pill_width = (text_width + 2.0 * padding).min((width - 2.0 * margin).max(0.0));
        let pill_height = text_height + 4.0 * scale;
        let pill = D2D1_ROUNDED_RECT {
            rect: rect(margin, margin, margin + pill_width, margin + pill_height),
            radiusX: 3.0 * scale,
            radiusY: 3.0 * scale,
        };
        let background = brush(target, color(0, 0.5))?;
        // SAFETY: 圆角矩形与画刷在调用期间有效。
        unsafe { target.FillRoundedRectangle(&pill, &background) };
        let area = rect(
            margin + padding,
            margin + 2.0 * scale,
            (margin + pill_width - padding).max(margin + padding),
            margin + pill_height,
        );
        draw_text(target, &text, &format, &area, color(title.color, 1.0))
    }
}

/// 右上角的跳过标记：红色圆形加一条白色横杠（禁行符号），直径随窗口高度在 14～24 DIP 之间。
fn draw_skip_badge(target: &ID2D1DCRenderTarget, width: f32, height: f32, scale: f32) -> Result<()> {
    // 直径先按 DIP 算（窗口高度换回 DIP 再取 12%），夹在 14～24 之间后再乘缩放：
    // 小缩略图上标记不至于小到看不清，大缩略图上也不会喧宾夺主。
    let diameter = (height / scale * 0.12).clamp(14.0, 24.0) * scale;
    let margin = 4.0 * scale;
    let left = width - diameter - margin;
    let circle = D2D1_ROUNDED_RECT {
        rect: rect(left, margin, left + diameter, margin + diameter),
        radiusX: diameter / 2.0,
        radiusY: diameter / 2.0,
    };
    // 与 macOS 的 systemRed 相同的颜色。
    let red = brush(target, color(0xFF_3B_30, 1.0))?;
    // SAFETY: 圆角矩形与画刷在调用期间有效。
    unsafe { target.FillRoundedRectangle(&circle, &red) };
    let bar = rect(
        left + diameter * 0.2,
        margin + diameter * 0.42,
        left + diameter * 0.8,
        margin + diameter * 0.58,
    );
    fill(target, &bar, color(0xFF_FF_FF, 1.0))
}

/// 在矩形里画文字，超出矩形的部分裁掉。
fn draw_text(
    target: &ID2D1DCRenderTarget,
    text: &[u16],
    format: &IDWriteTextFormat,
    area: &D2D_RECT_F,
    fill: D2D1_COLOR_F,
) -> Result<()> {
    let brush = brush(target, fill)?;
    // SAFETY: 文字、格式、矩形与画刷在调用期间有效。
    unsafe {
        target.DrawText(
            text,
            format,
            area,
            &brush,
            D2D1_DRAW_TEXT_OPTIONS_CLIP,
            DWRITE_MEASURING_MODE_NATURAL,
        );
    }
    Ok(())
}

/// 用纯色填满矩形。
fn fill(target: &ID2D1DCRenderTarget, area: &D2D_RECT_F, fill: D2D1_COLOR_F) -> Result<()> {
    let brush = brush(target, fill)?;
    // SAFETY: 矩形与画刷在调用期间有效。
    unsafe { target.FillRectangle(area, &brush) };
    Ok(())
}

/// 建一个纯色画刷。画刷很轻，每次画时现建，不缓存。
fn brush(
    target: &ID2D1DCRenderTarget,
    fill: D2D1_COLOR_F,
) -> Result<windows::Win32::Graphics::Direct2D::ID2D1SolidColorBrush> {
    // SAFETY: 颜色结构在调用期间有效。
    unsafe { target.CreateSolidColorBrush(&fill, None) }
}

/// `0xRRGGBB` 与不透明度换成 Direct2D 的颜色（直通 alpha，Direct2D 自己预乘）。
fn color(rgb: u32, alpha: f32) -> D2D1_COLOR_F {
    let channel = |shift: u32| ((rgb >> shift) & 0xFF) as f32 / 255.0;
    D2D1_COLOR_F {
        r: channel(16),
        g: channel(8),
        b: channel(0),
        a: alpha.clamp(0.0, 1.0),
    }
}

/// 矩形。
fn rect(left: f32, top: f32, right: f32, bottom: f32) -> D2D_RECT_F {
    D2D_RECT_F {
        left,
        top,
        right,
        bottom,
    }
}

/// 文字换成 UTF-16，不带结尾的 0（DirectWrite 按长度读）。
fn wide_text(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}
