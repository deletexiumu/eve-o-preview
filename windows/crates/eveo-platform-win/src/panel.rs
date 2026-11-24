// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译浮窗的窗口，对应 macOS 的 InfoOverlayPanel（docs/macos/design-intel-translate.md 8.3 节）。
// 画面由 eveo-ui 的离屏宿主用 Slint 的软件渲染器画好（预乘 alpha 的 BGRA），这里只负责：
// - 分层窗口（WS_EX_LAYERED）用 UpdateLayeredWindow 提交逐像素透明的位图：背景半透明、圆角处透明，文字不透明。
// - 不抢焦点：WS_EX_NOACTIVATE，鼠标按下时回 MA_NOACTIVATE，显示用 SW_SHOWNOACTIVATE。点浮窗不会让游戏失去焦点。
// - 不进任务栏与 Alt+Tab：WS_EX_TOOLWINDOW。没有主人窗口，自己就是顶层窗口；置顶由应用层按规划结果切换。
// - 鼠标输入（进入、按下、移动、松开、滚轮、离开、失去捕获）交给 `set_input_handler` 设的处理函数，
//   坐标是全局屏幕坐标（物理像素）。手势（移动、缩放、菜单）由应用层的状态机判断，与缩略图共用一套。
// 浮窗不让点击穿透到游戏（Q20）：没有 WS_EX_TRANSPARENT，透明的圆角处也算窗口的一部分（UpdateLayeredWindow
// 的命中测试按 alpha 为 0 的像素穿透，四个圆角外的几个像素会穿透，这与 macOS 面板的行为相同，不影响使用）。
//
// 处理函数与窗口状态放在线程局部的表里，以窗口句柄为键；窗口与处理函数都在主线程上。

//! 浮窗的分层窗口。

use std::cell::RefCell;
use std::collections::HashMap;

use eveo_core::geometry::ScreenPoint;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION, CreateCompatibleDC,
    CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, HBRUSH, ReleaseDC, SelectObject,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, HTCLIENT, HWND_NOTOPMOST, HWND_TOPMOST, MA_NOACTIVATE,
    SW_HIDE, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SetWindowPos,
    ShowWindow, ULW_ALPHA, UpdateLayeredWindow, WM_CAPTURECHANGED, WM_LBUTTONDOWN, WM_LBUTTONUP,
    WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SETCURSOR, WS_EX_LAYERED,
    WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP,
};
use windows::core::{PCWSTR, Result};

use crate::thumbnail::{
    CursorShape, KeyModifiers, MouseButton, cursor_position, modifiers, set_cursor, track_leave,
};
use crate::{text::wide, window_class};

/// `WM_MOUSELEAVE`，同 thumbnail 模块。
const WM_MOUSELEAVE: u32 = 0x02A3;

/// 浮窗收到的一条鼠标输入。坐标是全局屏幕坐标（物理像素），取自光标位置。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PanelInput {
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
    Release {
        /// 按键。
        button: MouseButton,
        /// 光标位置（左键松开时交给 Slint，判断是否点在新消息条上）。
        point: ScreenPoint,
    },
    /// 滚轮。delta 是 WM_MOUSEWHEEL 的数值，一格 120，向前滚为正。
    Wheel {
        /// 滚动量。
        delta: i32,
        /// 光标位置。
        point: ScreenPoint,
    },
    /// 鼠标离开窗口（没有捕获时）。
    Leave,
    /// 捕获被别的窗口拿走（例如弹出了菜单、按了 Alt+Tab），进行中的手势要取消。
    CaptureLost,
}

/// 输入处理函数的类型。
type Handler = Box<dyn FnMut(PanelInput)>;

/// 每个浮窗在窗口过程里要用的状态。
struct PanelState {
    /// 输入处理函数。
    handler: Option<Handler>,
    /// 光标形状。
    cursor: CursorShape,
    /// 已请求 `WM_MOUSELEAVE`（鼠标在窗口里）。
    tracking: bool,
}

thread_local! {
    /// 各浮窗的状态，以窗口句柄的数值为键。
    static STATES: RefCell<HashMap<usize, PanelState>> = RefCell::new(HashMap::new());
}

/// 一个浮窗窗口。建好时隐藏，第一次提交画面后才能显示。丢弃时销毁窗口。
pub struct PanelWindow {
    /// 窗口句柄。
    hwnd: HWND,
    /// 位置与尺寸（物理像素）：x, y, 宽, 高；还没提交过画面时是 0。
    frame: (i32, i32, i32, i32),
    /// 已提交过画面。分层窗口在第一次 UpdateLayeredWindow 之前什么也不显示，显示要等到这之后。
    presented: bool,
    /// 应显示。
    shown: bool,
    /// 置顶。
    topmost: bool,
}

impl PanelWindow {
    /// 在本线程上建一个隐藏的浮窗窗口。
    ///
    /// 窗口类不设背景画刷：分层窗口的内容全由 UpdateLayeredWindow 提交，系统不会再擦背景。
    pub fn create() -> Result<Self> {
        let class = window_class::ensure("EVEOPreview.InfoOverlay", Some(window_proc), HBRUSH::default())?;
        let title = wide("EVE-O Preview overlay panel");
        // SAFETY: 类名与标题的缓冲区在调用期间有效；没有主人窗口。
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                PCWSTR(class.as_ptr()),
                PCWSTR(title.as_ptr()),
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                Some(window_class::instance()?),
                None,
            )?
        };
        STATES.with(|s| {
            s.borrow_mut().insert(
                hwnd.0 as usize,
                PanelState {
                    handler: None,
                    cursor: CursorShape::Arrow,
                    tracking: false,
                },
            )
        });
        Ok(Self {
            hwnd,
            frame: (0, 0, 0, 0),
            presented: false,
            shown: false,
            topmost: false,
        })
    }

    /// 窗口句柄。
    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }

    /// 当前的位置与尺寸（物理像素）。
    pub fn frame(&self) -> (i32, i32, i32, i32) {
        self.frame
    }

    /// 设输入处理函数，替换之前的。
    pub fn set_input_handler(&self, handler: impl FnMut(PanelInput) + 'static) {
        state_of(self.hwnd, |s| s.handler = Some(Box::new(handler)));
    }

    /// 设光标停在窗口上时的形状（边缘带上显示缩放箭头）。
    pub fn set_cursor(&self, shape: CursorShape) {
        state_of(self.hwnd, |s| s.cursor = shape);
    }

    /// 提交画面并放到 frame：bgra 是预乘 alpha 的 BGRA，自上而下，长度是宽 × 高 × 4。
    /// 位置、尺寸与画面一次提交，拖动缩放时不会先变尺寸后换画面而闪一下。
    /// 长度不对（宿主与窗口的尺寸不一致）时不提交，返回 E_INVALIDARG，免得越界读内存。
    pub fn present(&mut self, frame: (i32, i32, i32, i32), bgra: &[u8]) -> Result<()> {
        let (x, y, width, height) = frame;
        if width <= 0 || height <= 0 || bgra.len() != width as usize * height as usize * 4 {
            return Err(windows::core::Error::from_hresult(
                windows::Win32::Foundation::E_INVALIDARG,
            ));
        }
        commit(self.hwnd, frame, bgra)?;
        self.frame = (x, y, width, height);
        if !self.presented {
            self.presented = true;
            self.apply_shown();
        }
        Ok(())
    }

    /// 只移动，不换画面也不改尺寸（尺寸变了要重新画，走 present）。
    /// 分层窗口移动时系统直接挪已提交的位图，不需要重画，拖动移动因此很流畅。
    pub fn move_to(&mut self, x: i32, y: i32) {
        if (x, y) == (self.frame.0, self.frame.1) {
            return;
        }
        self.frame.0 = x;
        self.frame.1 = y;
        // SAFETY: 窗口属于本线程；不改尺寸与层级，不激活。
        let _ = unsafe {
            SetWindowPos(
                self.hwnd,
                None,
                x,
                y,
                0,
                0,
                SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER,
            )
        };
    }

    /// 显示或隐藏。还没提交过画面时只记下，提交后再显示。
    pub fn set_shown(&mut self, shown: bool) {
        if shown == self.shown {
            return;
        }
        self.shown = shown;
        if self.presented {
            self.apply_shown();
        }
    }

    /// 是否应显示。
    pub fn is_shown(&self) -> bool {
        self.shown
    }

    /// 置顶或取消置顶。盖在全屏客户端上时也是置顶，后来的置顶窗口在前，所以每次显示时由应用层重新设一次。
    pub fn set_topmost(&mut self, topmost: bool) {
        self.topmost = topmost;
        let after = if topmost { HWND_TOPMOST } else { HWND_NOTOPMOST };
        // SAFETY: 窗口属于本线程；只改层级，不移动、不改尺寸、不激活。
        let _ = unsafe {
            SetWindowPos(
                self.hwnd,
                Some(after),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            )
        };
    }

    /// 按 shown 显示或隐藏窗口。
    fn apply_shown(&self) {
        let command = if self.shown { SW_SHOWNOACTIVATE } else { SW_HIDE };
        // SAFETY: 窗口属于本线程。
        let _ = unsafe { ShowWindow(self.hwnd, command) };
    }
}

impl Drop for PanelWindow {
    fn drop(&mut self) {
        STATES.with(|s| s.borrow_mut().remove(&(self.hwnd.0 as usize)));
        // SAFETY: 窗口由 create 建立，只销毁一次。
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// 建 DIB、复制画面、提交给分层窗口，最后释放 GDI 对象。
///
/// DIB 每次现建现删：一个 570×390 的浮窗约 0.9 MB，画面只在内容、悬停或滚动变化时才提交，
/// 建一次的开销可以忽略，不缓存也就不必跟踪尺寸变化。UpdateLayeredWindow 会把位图复制给系统，返回后即可释放。
fn commit(hwnd: HWND, frame: (i32, i32, i32, i32), bgra: &[u8]) -> Result<()> {
    let (x, y, width, height) = frame;
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            // 负的高度表示从上到下的位图，与 Slint 缓冲区的行序一致。
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    // SAFETY: 设备上下文与位图在本块内创建，按相反的顺序释放；info 在调用期间有效。
    // DIB 的像素区由系统分配，大小正是宽 × 高 × 4 字节（32 位、无行尾填充），bgra 的长度已在调用前核对。
    unsafe {
        let screen = GetDC(None);
        let memory = CreateCompatibleDC(Some(screen));
        let mut bits = std::ptr::null_mut();
        let result = match CreateDIBSection(Some(memory), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(bitmap) if !bits.is_null() => {
                std::ptr::copy_nonoverlapping(bgra.as_ptr(), bits.cast::<u8>(), bgra.len());
                let previous = SelectObject(memory, bitmap.into());
                // 位图已经是预乘 alpha，按逐像素 alpha 合成，整体不透明度 255（背景的半透明已画在像素里）。
                let blend = BLENDFUNCTION {
                    BlendOp: AC_SRC_OVER as u8,
                    BlendFlags: 0,
                    SourceConstantAlpha: 255,
                    AlphaFormat: AC_SRC_ALPHA as u8,
                };
                let committed = UpdateLayeredWindow(
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
                );
                SelectObject(memory, previous);
                let _ = DeleteObject(bitmap.into());
                committed
            }
            Ok(bitmap) => {
                let _ = DeleteObject(bitmap.into());
                Err(windows::core::Error::from_thread())
            }
            Err(error) => Err(error),
        };
        let _ = DeleteDC(memory);
        ReleaseDC(None, screen);
        result
    }
}

/// 窗口过程：鼠标按下时不激活本窗口；按设定的形状设光标；鼠标消息换成 `PanelInput` 交给处理函数。
/// 其余交给默认处理。与缩略图的窗口过程相同，另加滚轮，松开时带上光标位置。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEACTIVATE => return LRESULT(MA_NOACTIVATE as isize),
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
                PanelInput::Press {
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
            dispatch(
                hwnd,
                PanelInput::Release {
                    button,
                    point: cursor_position(),
                },
            );
            // SAFETY: 放开本线程的捕获；没有捕获时无害。
            let _ = unsafe { ReleaseCapture() };
            return LRESULT(0);
        }
        WM_MOUSEMOVE => {
            if state_of(hwnd, |s| std::mem::replace(&mut s.tracking, true)) == Some(false) {
                track_leave(hwnd);
                dispatch(hwnd, PanelInput::Enter);
            }
            dispatch(
                hwnd,
                PanelInput::Move {
                    point: cursor_position(),
                    modifiers: modifiers(),
                },
            );
            return LRESULT(0);
        }
        // 浮窗从不获得焦点，滚轮能到这里靠的是 Windows 10 起默认打开的「悬停时滚动非活动窗口」。
        WM_MOUSEWHEEL => {
            // 高 16 位是有符号的滚动量；光标位置在 lParam 里，但用 GetCursorPos 与其他消息保持一致。
            let delta = i32::from((wparam.0 >> 16) as u16 as i16);
            dispatch(
                hwnd,
                PanelInput::Wheel {
                    delta,
                    point: cursor_position(),
                },
            );
            return LRESULT(0);
        }
        WM_MOUSELEAVE => {
            state_of(hwnd, |s| s.tracking = false);
            dispatch(hwnd, PanelInput::Leave);
            return LRESULT(0);
        }
        WM_CAPTURECHANGED if lparam.0 as usize != hwnd.0 as usize => {
            dispatch(hwnd, PanelInput::CaptureLost);
            return LRESULT(0);
        }
        _ => {}
    }
    // SAFETY: 参数原样转交。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// 在窗口状态上执行 `body`；窗口不在表里（建窗口期间、已销毁）时返回 `None`。
fn state_of<R>(hwnd: HWND, body: impl FnOnce(&mut PanelState) -> R) -> Option<R> {
    STATES.with(|s| s.try_borrow_mut().ok()?.get_mut(&(hwnd.0 as usize)).map(body))
}

/// 调用窗口的处理函数。调用期间先把它从表里取出，处理函数里再移动、销毁窗口或换处理函数都不会重复借用；
/// 调用结束后窗口还在、且没有换上新的处理函数时放回去。
fn dispatch(hwnd: HWND, input: PanelInput) {
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
