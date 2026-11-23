// SPDX-License-Identifier: GPL-3.0-or-later
//
// DWM 缩略图窗口（架构文档 4.2 节）：一个不抢焦点、不进任务栏与 Alt+Tab 的弹出窗口，
// 用 DwmRegisterThumbnail 让系统把客户端窗口的画面直接合成到它上面。只取客户区（去掉标题栏与边框）。
// 目标矩形向内缩进边框的粗细，露出的窗口底色就是边框；底色按窗口单独设（高亮色或中性边框色）。
// 不透明度作用于整个窗口（分层窗口的 alpha），与 macOS 的面板 alphaValue 相同：画面、边框与叠加层一起变淡，
// 透出的是窗口后面的桌面或游戏。不用 DWM 缩略图自己的 opacity：那样半透明的画面叠在不透明的底色上，
// 未悬停时整块缩略图会蒙上一层边框色（真机测试发现，高亮色时几乎看不出画面）。
// 鼠标输入（按下、移动、松开、离开、失去捕获）交给 `set_input_handler` 设的处理函数，手势由应用层的状态机判断。
// 处理函数与窗口状态放在线程局部的表里，以窗口句柄为键；窗口与处理函数都在主线程上。
// 标题、占位、跳过标记与提醒画在它拥有的叠加层窗口上（overlay 模块），位置与显隐随本窗口同步。

//! DWM 缩略图窗口。

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::OnceLock;

use eveo_core::geometry::{ScreenPoint, ScreenRect};
use eveo_core::model::WindowId;
use windows::Win32::Foundation::POINT;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWM_THUMBNAIL_PROPERTIES, DWM_TNP_OPACITY, DWM_TNP_RECTDESTINATION, DWM_TNP_SOURCECLIENTAREAONLY,
    DWM_TNP_VISIBLE, DwmQueryThumbnailSourceSize, DwmRegisterThumbnail, DwmUnregisterThumbnail,
    DwmUpdateThumbnailProperties,
};
use windows::Win32::Graphics::Gdi::{CreateSolidBrush, DeleteObject, FillRect, HBRUSH, HDC, InvalidateRect};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, ReleaseCapture, SetCapture, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent, VK_CONTROL,
    VK_MENU, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetClientRect, GetCursorPos, HCURSOR, HTCLIENT,
    HWND_NOTOPMOST, HWND_TOPMOST, IDC_ARROW, IDC_SIZEALL, IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE,
    LWA_ALPHA, LoadCursorW, MA_NOACTIVATE, SW_HIDE, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SetCursor,
    SetLayeredWindowAttributes, SetWindowPos, ShowWindow, WM_CAPTURECHANGED, WM_ERASEBKGND, WM_LBUTTONDOWN,
    WM_LBUTTONUP, WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SETCURSOR, WS_EX_LAYERED,
    WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};
use windows::core::{PCWSTR, Result};

use crate::overlay::{OverlayContent, OverlayWindow};
use crate::{hwnd, text::wide, window_class};

/// 缩略图窗口的底色（边框露出的颜色）：深灰。M4 起按设置里的边框颜色重画。
const BACKGROUND: COLORREF = COLORREF(0x0020_2020);

/// `WM_MOUSELEAVE`。windows crate 把它放在 `UI_Controls` 特性里，为一个常量不开整个特性。
const WM_MOUSELEAVE: u32 = 0x02A3;

/// 窗口类的底色画刷，进程内只建一次。
fn background_brush() -> HBRUSH {
    /// 画刷句柄的数值；HBRUSH 本身不是 Sync，存成整数。
    static BRUSH: OnceLock<isize> = OnceLock::new();
    // SAFETY: 建一个纯色画刷，作为窗口类的底色一直用到进程退出。
    let value = *BRUSH.get_or_init(|| unsafe { CreateSolidBrush(BACKGROUND) }.0 as isize);
    HBRUSH(value as *mut core::ffi::c_void)
}

/// 缩略图窗口上的鼠标按键。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    /// 左键。
    Left,
    /// 右键。
    Right,
}

/// 事件发生时按着的修饰键。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct KeyModifiers {
    /// Ctrl。
    pub ctrl: bool,
    /// Alt。
    pub alt: bool,
    /// Shift。
    pub shift: bool,
}

/// 缩略图窗口收到的一条鼠标输入。坐标是全局屏幕坐标（物理像素），取自光标位置。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ThumbnailInput {
    /// 鼠标进入窗口（离开后的第一次移动）。
    Enter,
    /// 按下。按下后窗口捕获鼠标，移出窗口也继续收到移动与松开。
    Press {
        /// 按键。
        button: MouseButton,
        /// 修饰键。
        modifiers: KeyModifiers,
        /// 光标位置。
        point: ScreenPoint,
    },
    /// 移动。
    Move {
        /// 光标位置。
        point: ScreenPoint,
        /// 修饰键（拖动中按 Shift 绕过吸附）。
        modifiers: KeyModifiers,
    },
    /// 松开。
    Release(MouseButton),
    /// 鼠标离开窗口（没有捕获时）。
    Leave,
    /// 捕获被别的窗口拿走（例如弹出了菜单、按了 Alt+Tab），进行中的手势要取消。
    CaptureLost,
}

/// 光标停在缩略图上时的形状：普通箭头，或缩放某条边、某个角的双向箭头。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CursorShape {
    /// 普通箭头。
    #[default]
    Arrow,
    /// 左右缩放。
    SizeWestEast,
    /// 上下缩放。
    SizeNorthSouth,
    /// 左上、右下角缩放。
    SizeNorthwestSoutheast,
    /// 右上、左下角缩放。
    SizeNortheastSouthwest,
    /// 移动。
    Move,
}

/// 输入处理函数的类型。
type Handler = Box<dyn FnMut(ThumbnailInput)>;

/// 每个缩略图窗口在窗口过程里要用的状态。
struct WindowState {
    /// 输入处理函数。
    handler: Option<Handler>,
    /// 底色，`0x00BBGGRR`。
    background: u32,
    /// 光标形状。
    cursor: CursorShape,
    /// 已请求 `WM_MOUSELEAVE`（鼠标在窗口里）。
    tracking: bool,
}

thread_local! {
    /// 各缩略图窗口的状态，以窗口句柄的数值为键。
    static STATES: RefCell<HashMap<usize, WindowState>> = RefCell::new(HashMap::new());
}

/// 一个缩略图窗口与它的 DWM 缩略图。丢弃时注销缩略图并销毁窗口。
pub struct ThumbnailWindow {
    hwnd: HWND,
    thumbnail: Option<isize>,
    frame: ScreenRect,
    inset: i32,
    visible: bool,
    opacity: u8,
    shown: bool,
    /// 叠加层；建不出来时（极少见）为 `None`，缩略图照常显示，只是没有标题等内容。
    overlay: Option<OverlayWindow>,
}

impl ThumbnailWindow {
    /// 在本线程上建一个缩略图窗口并显示（不激活）。frame 是物理像素的全局坐标。
    pub fn create(frame: ScreenRect, topmost: bool) -> Result<Self> {
        let class = window_class::ensure("EVEOPreview.Thumbnail", Some(window_proc), background_brush())?;
        let title = wide("EVE-O Preview thumbnail");
        // 分层窗口只用 SetLayeredWindowAttributes 设整体 alpha，内容仍按普通窗口绘制（WM_ERASEBKGND），
        // DWM 缩略图也照常合成在上面，并跟着窗口一起变淡。
        let mut ex_style = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED;
        if topmost {
            ex_style |= WS_EX_TOPMOST;
        }
        let (x, y, w, h) = round(frame);
        // SAFETY: 类名与标题的缓冲区在调用期间有效。
        let hwnd = unsafe {
            CreateWindowExW(
                ex_style,
                PCWSTR(class.as_ptr()),
                PCWSTR(title.as_ptr()),
                WS_POPUP,
                x,
                y,
                w,
                h,
                None,
                None,
                Some(window_class::instance()?),
                None,
            )?
        };
        STATES.with(|s| {
            s.borrow_mut().insert(
                hwnd.0 as usize,
                WindowState {
                    handler: None,
                    background: BACKGROUND.0,
                    cursor: CursorShape::Arrow,
                    tracking: false,
                },
            )
        });
        // 分层窗口在设属性之前不显示任何内容；先设成不透明再显示。
        // SAFETY: 窗口刚建好，属于本线程。
        unsafe {
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        }
        let overlay = OverlayWindow::create(hwnd).ok().map(|mut overlay| {
            overlay.set_frame((x, y, w, h));
            overlay
        });
        Ok(Self {
            hwnd,
            thumbnail: None,
            frame,
            inset: 0,
            visible: true,
            opacity: 255,
            shown: true,
            overlay,
        })
    }

    /// 设置叠加层的内容（标题、占位、跳过标记、提醒）。与上次相同时不重画。
    pub fn set_overlay(&mut self, content: OverlayContent) {
        if let Some(overlay) = &mut self.overlay {
            overlay.set_content(content);
        }
    }

    /// 设置鼠标输入的处理函数。替换已有的处理函数。
    pub fn set_input_handler(&self, handler: impl FnMut(ThumbnailInput) + 'static) {
        self.with_state(|state| state.handler = Some(Box::new(handler)));
    }

    /// 设置底色（边框露出的颜色），`0x00BBGGRR`。变了才重画。
    pub fn set_background(&self, bgr: u32) {
        let changed = self.with_state(|state| std::mem::replace(&mut state.background, bgr) != bgr);
        if changed == Some(true) {
            // SAFETY: 窗口属于本线程；整个客户区重画。
            let _ = unsafe { InvalidateRect(Some(self.hwnd), None, true) };
        }
    }

    /// 设置光标停在窗口上时的形状。
    pub fn set_cursor(&self, shape: CursorShape) {
        self.with_state(|state| state.cursor = shape);
    }

    /// 显示或隐藏整个窗口（不激活）。隐藏的窗口不收鼠标输入。
    pub fn set_shown(&mut self, shown: bool) {
        if shown == self.shown {
            return;
        }
        self.shown = shown;
        let command = if shown { SW_SHOWNOACTIVATE } else { SW_HIDE };
        // SAFETY: 窗口属于本线程。
        let _ = unsafe { ShowWindow(self.hwnd, command) };
        if let Some(overlay) = &mut self.overlay {
            overlay.set_owner_shown(shown);
        }
    }

    /// 窗口是否显示着。
    pub fn is_shown(&self) -> bool {
        self.shown
    }

    /// 在本窗口的状态上执行 `body`；窗口不在表里时返回 `None`。
    fn with_state<R>(&self, body: impl FnOnce(&mut WindowState) -> R) -> Option<R> {
        STATES.with(|s| s.borrow_mut().get_mut(&(self.hwnd.0 as usize)).map(body))
    }

    /// 窗口句柄的编号，便于核对前台与截图位置。
    pub fn id(&self) -> WindowId {
        crate::window_id(self.hwnd)
    }

    /// 当前的窗口矩形。
    pub fn frame(&self) -> ScreenRect {
        self.frame
    }

    /// 把源窗口的画面注册到本窗口；已注册过时先注销旧的。
    pub fn register(&mut self, source: WindowId) -> Result<()> {
        self.unregister();
        // SAFETY: 两个句柄都是顶层窗口；源窗口已不存在时返回错误。
        let thumbnail = unsafe { DwmRegisterThumbnail(self.hwnd, hwnd(source))? };
        self.thumbnail = Some(thumbnail);
        self.apply()
    }

    /// 注销缩略图；没注册时什么也不做。
    pub fn unregister(&mut self) {
        if let Some(thumbnail) = self.thumbnail.take() {
            // SAFETY: 句柄由 register 得到，只注销一次。
            let _ = unsafe { DwmUnregisterThumbnail(thumbnail) };
        }
    }

    /// 是否已注册。
    pub fn is_registered(&self) -> bool {
        self.thumbnail.is_some()
    }

    /// 源窗口画面的尺寸（物理像素）。
    pub fn source_size(&self) -> Option<(i32, i32)> {
        let thumbnail = self.thumbnail?;
        // SAFETY: 句柄有效。
        let size: SIZE = unsafe { DwmQueryThumbnailSourceSize(thumbnail) }.ok()?;
        Some((size.cx, size.cy))
    }

    /// 设置目标矩形的缩进（边框粗细，物理像素）、可见性与整个窗口的不透明度（0～255）。
    /// 不透明度同时交给叠加层：它是另一个窗口，要单独变淡才与缩略图一致。
    pub fn set_appearance(&mut self, inset: i32, visible: bool, opacity: u8) -> Result<()> {
        self.inset = inset.max(0);
        self.visible = visible;
        if opacity != self.opacity {
            self.opacity = opacity;
            // SAFETY: 窗口属于本线程，建窗口时已设为分层窗口。
            unsafe { SetLayeredWindowAttributes(self.hwnd, COLORREF(0), opacity, LWA_ALPHA)? };
            if let Some(overlay) = &mut self.overlay {
                overlay.set_alpha(opacity);
            }
        }
        self.apply()
    }

    /// 移动并缩放窗口，目标矩形跟着改。
    pub fn set_frame(&mut self, frame: ScreenRect, topmost: bool) -> Result<()> {
        let (x, y, w, h) = round(frame);
        let after = if topmost { HWND_TOPMOST } else { HWND_NOTOPMOST };
        // SAFETY: 窗口属于本线程；不激活。
        unsafe { SetWindowPos(self.hwnd, Some(after), x, y, w, h, SWP_NOACTIVATE)? };
        self.frame = frame;
        // 叠加层是本窗口拥有的窗口，层次由系统保持在本窗口之上，这里只同步位置与大小。
        if let Some(overlay) = &mut self.overlay {
            overlay.set_frame((x, y, w, h));
        }
        self.apply()
    }

    /// 把属性写给 DWM：目标矩形与可见性取最近一次设的值。画面本身总是不透明，变淡靠窗口的 alpha。
    fn apply(&self) -> Result<()> {
        let visible = self.visible;
        let Some(thumbnail) = self.thumbnail else {
            return Ok(());
        };
        let (_, _, w, h) = round(self.frame);
        let properties = DWM_THUMBNAIL_PROPERTIES {
            dwFlags: DWM_TNP_RECTDESTINATION
                | DWM_TNP_VISIBLE
                | DWM_TNP_OPACITY
                | DWM_TNP_SOURCECLIENTAREAONLY,
            rcDestination: RECT {
                left: self.inset,
                top: self.inset,
                right: (w - self.inset).max(self.inset),
                bottom: (h - self.inset).max(self.inset),
            },
            opacity: 255,
            fVisible: visible.into(),
            fSourceClientAreaOnly: true.into(),
            ..Default::default()
        };
        // SAFETY: 句柄有效，属性结构在调用期间有效。
        unsafe { DwmUpdateThumbnailProperties(thumbnail, &properties) }
    }
}

impl Drop for ThumbnailWindow {
    fn drop(&mut self) {
        // 先销毁叠加层：销毁主人时系统也会销毁它，之后再 DestroyWindow 就是对失效句柄操作。
        self.overlay = None;
        self.unregister();
        STATES.with(|s| s.borrow_mut().remove(&(self.hwnd.0 as usize)));
        // SAFETY: 窗口由 create 建立，只销毁一次。
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// 矩形取整成 Win32 的 (x, y, 宽, 高)。
fn round(frame: ScreenRect) -> (i32, i32, i32, i32) {
    (
        frame.x.round() as i32,
        frame.y.round() as i32,
        frame.width.round() as i32,
        frame.height.round() as i32,
    )
}

/// 窗口过程：鼠标按下时不激活本窗口（点击缩略图不抢焦点）；按窗口的底色擦背景、按设定的形状设光标；
/// 鼠标消息换成 `ThumbnailInput` 交给处理函数。其余交给默认处理。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEACTIVATE => return LRESULT(MA_NOACTIVATE as isize),
        WM_ERASEBKGND => {
            erase(hwnd, HDC(wparam.0 as *mut core::ffi::c_void));
            return LRESULT(1);
        }
        WM_SETCURSOR if (lparam.0 & 0xFFFF) as u32 == HTCLIENT => {
            let shape = state_of(hwnd, |s| s.cursor).unwrap_or_default();
            set_cursor(shape);
            return LRESULT(1);
        }
        WM_LBUTTONDOWN | WM_RBUTTONDOWN => {
            let button = if msg == WM_LBUTTONDOWN {
                MouseButton::Left
            } else {
                MouseButton::Right
            };
            // SAFETY: 窗口属于本线程；捕获鼠标，拖出窗口也能收到移动与松开。
            unsafe { SetCapture(hwnd) };
            dispatch(
                hwnd,
                ThumbnailInput::Press {
                    button,
                    modifiers: modifiers(),
                    point: cursor_position(),
                },
            );
            return LRESULT(0);
        }
        WM_LBUTTONUP | WM_RBUTTONUP => {
            let button = if msg == WM_LBUTTONUP {
                MouseButton::Left
            } else {
                MouseButton::Right
            };
            // 先交给处理函数再放开捕获：放开会发 WM_CAPTURECHANGED，此时手势已经结束，取消不起作用。
            dispatch(hwnd, ThumbnailInput::Release(button));
            // SAFETY: 放开本线程的捕获；没有捕获时无害。
            let _ = unsafe { ReleaseCapture() };
            return LRESULT(0);
        }
        WM_MOUSEMOVE => {
            if state_of(hwnd, |s| std::mem::replace(&mut s.tracking, true)) == Some(false) {
                track_leave(hwnd);
                dispatch(hwnd, ThumbnailInput::Enter);
            }
            dispatch(
                hwnd,
                ThumbnailInput::Move {
                    point: cursor_position(),
                    modifiers: modifiers(),
                },
            );
            return LRESULT(0);
        }
        WM_MOUSELEAVE => {
            state_of(hwnd, |s| s.tracking = false);
            dispatch(hwnd, ThumbnailInput::Leave);
            return LRESULT(0);
        }
        WM_CAPTURECHANGED if lparam.0 as usize != hwnd.0 as usize => {
            dispatch(hwnd, ThumbnailInput::CaptureLost);
            return LRESULT(0);
        }
        _ => {}
    }
    // SAFETY: 参数原样转交。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// 在窗口状态上执行 `body`；窗口不在表里（建窗口期间、已销毁）时返回 `None`。
fn state_of<R>(hwnd: HWND, body: impl FnOnce(&mut WindowState) -> R) -> Option<R> {
    STATES.with(|s| s.try_borrow_mut().ok()?.get_mut(&(hwnd.0 as usize)).map(body))
}

/// 调用窗口的处理函数。调用期间先把它从表里取出，处理函数里再移动、销毁窗口或换处理函数都不会重复借用；
/// 调用结束后窗口还在、且没有换上新的处理函数时放回去。
fn dispatch(hwnd: HWND, input: ThumbnailInput) {
    let Some(Some(mut handler)) = state_of(hwnd, |s| s.handler.take()) else {
        return;
    };
    handler(input);
    state_of(hwnd, |s| {
        if s.handler.is_none() {
            s.handler = Some(handler);
        }
    });
}

/// 用窗口的底色填满客户区。
fn erase(hwnd: HWND, dc: HDC) {
    let color = state_of(hwnd, |s| s.background).unwrap_or(BACKGROUND.0);
    let mut rect = RECT::default();
    // SAFETY: 窗口属于本线程，rect 是有效的输出位置；画刷用完即删。
    unsafe {
        let _ = GetClientRect(hwnd, &mut rect);
        let brush = CreateSolidBrush(COLORREF(color));
        FillRect(dc, &rect, brush);
        let _ = DeleteObject(brush.into());
    }
}

/// 请求在鼠标离开窗口时收到 `WM_MOUSELEAVE`。
fn track_leave(hwnd: HWND) {
    let mut request = TRACKMOUSEEVENT {
        cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
        dwFlags: TME_LEAVE,
        hwndTrack: hwnd,
        dwHoverTime: 0,
    };
    // SAFETY: 结构的大小已填好，窗口属于本线程。
    let _ = unsafe { TrackMouseEvent(&mut request) };
}

/// 当前光标位置，全局屏幕坐标（物理像素，进程按每显示器 DPI 感知运行）。
pub fn cursor_position() -> ScreenPoint {
    let mut point = POINT::default();
    // SAFETY: point 是有效的输出位置。
    let _ = unsafe { GetCursorPos(&mut point) };
    ScreenPoint::new(f64::from(point.x), f64::from(point.y))
}

/// 当前按着的修饰键。`GetKeyState` 读的是本线程消息队列里的状态，与正在处理的消息同步。
fn modifiers() -> KeyModifiers {
    // SAFETY: 只读键盘状态。
    let down = |key| unsafe { GetKeyState(i32::from(key)) } < 0;
    KeyModifiers {
        ctrl: down(VK_CONTROL.0),
        alt: down(VK_MENU.0),
        shift: down(VK_SHIFT.0),
    }
}

/// 设置光标形状。
fn set_cursor(shape: CursorShape) {
    let id = match shape {
        CursorShape::Arrow => IDC_ARROW,
        CursorShape::SizeWestEast => IDC_SIZEWE,
        CursorShape::SizeNorthSouth => IDC_SIZENS,
        CursorShape::SizeNorthwestSoutheast => IDC_SIZENWSE,
        CursorShape::SizeNortheastSouthwest => IDC_SIZENESW,
        CursorShape::Move => IDC_SIZEALL,
    };
    // SAFETY: 加载系统预置的光标，实例传 None；失败时保持原光标。
    if let Ok(cursor) = unsafe { LoadCursorW(None, id) } {
        // SAFETY: 光标句柄来自系统，共享且不用释放。
        unsafe { SetCursor(Some(HCURSOR(cursor.0))) };
    }
}
