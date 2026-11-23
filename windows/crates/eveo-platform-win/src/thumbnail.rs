// SPDX-License-Identifier: GPL-3.0-or-later
//
// DWM 缩略图窗口（架构文档 4.2 节）：一个不抢焦点、不进任务栏与 Alt+Tab 的弹出窗口，
// 用 DwmRegisterThumbnail 让系统把客户端窗口的画面直接合成到它上面。只取客户区（去掉标题栏与边框）。
// 目标矩形向内缩进边框的粗细，露出的窗口底色就是边框。标题等浮层在 M4 加入（另一个分层窗口）。

//! DWM 缩略图窗口。

use std::sync::OnceLock;

use eveo_core::geometry::ScreenRect;
use eveo_core::model::WindowId;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWM_THUMBNAIL_PROPERTIES, DWM_TNP_OPACITY, DWM_TNP_RECTDESTINATION, DWM_TNP_SOURCECLIENTAREAONLY,
    DWM_TNP_VISIBLE, DwmQueryThumbnailSourceSize, DwmRegisterThumbnail, DwmUnregisterThumbnail,
    DwmUpdateThumbnailProperties,
};
use windows::Win32::Graphics::Gdi::{CreateSolidBrush, HBRUSH};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, HWND_NOTOPMOST, HWND_TOPMOST, MA_NOACTIVATE,
    SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SetWindowPos, ShowWindow, WM_MOUSEACTIVATE, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};
use windows::core::{PCWSTR, Result};

use crate::{hwnd, text::wide, window_class};

/// 缩略图窗口的底色（边框露出的颜色）：深灰。M4 起按设置里的边框颜色重画。
const BACKGROUND: COLORREF = COLORREF(0x0020_2020);

/// 窗口类的底色画刷，进程内只建一次。
fn background_brush() -> HBRUSH {
    /// 画刷句柄的数值；HBRUSH 本身不是 Sync，存成整数。
    static BRUSH: OnceLock<isize> = OnceLock::new();
    // SAFETY: 建一个纯色画刷，作为窗口类的底色一直用到进程退出。
    let value = *BRUSH.get_or_init(|| unsafe { CreateSolidBrush(BACKGROUND) }.0 as isize);
    HBRUSH(value as *mut core::ffi::c_void)
}

/// 一个缩略图窗口与它的 DWM 缩略图。丢弃时注销缩略图并销毁窗口。
pub struct ThumbnailWindow {
    hwnd: HWND,
    thumbnail: Option<isize>,
    frame: ScreenRect,
    inset: i32,
}

impl ThumbnailWindow {
    /// 在本线程上建一个缩略图窗口并显示（不激活）。frame 是物理像素的全局坐标。
    pub fn create(frame: ScreenRect, topmost: bool) -> Result<Self> {
        let class = window_class::ensure("EVEOPreview.Thumbnail", Some(window_proc), background_brush())?;
        let title = wide("EVE-O Preview thumbnail");
        let mut ex_style = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
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
        // SAFETY: 窗口刚建好，属于本线程。
        let _ = unsafe { ShowWindow(hwnd, SW_SHOWNOACTIVATE) };
        Ok(Self {
            hwnd,
            thumbnail: None,
            frame,
            inset: 0,
        })
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
        self.apply(true, 255)
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

    /// 设置目标矩形的缩进（边框粗细，物理像素）、可见性与不透明度（0～255）。
    pub fn set_appearance(&mut self, inset: i32, visible: bool, opacity: u8) -> Result<()> {
        self.inset = inset.max(0);
        self.apply(visible, opacity)
    }

    /// 移动并缩放窗口，目标矩形跟着改。
    pub fn set_frame(&mut self, frame: ScreenRect, topmost: bool) -> Result<()> {
        let (x, y, w, h) = round(frame);
        let after = if topmost { HWND_TOPMOST } else { HWND_NOTOPMOST };
        // SAFETY: 窗口属于本线程；不激活。
        unsafe { SetWindowPos(self.hwnd, Some(after), x, y, w, h, SWP_NOACTIVATE)? };
        self.frame = frame;
        self.apply(true, 255)
    }

    /// 把属性写给 DWM。
    fn apply(&self, visible: bool, opacity: u8) -> Result<()> {
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
            opacity,
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
        self.unregister();
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

/// 窗口过程：鼠标按下时不激活本窗口（点击缩略图不抢焦点），其余交给默认处理。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_MOUSEACTIVATE {
        return LRESULT(MA_NOACTIVATE as isize);
    }
    // SAFETY: 参数原样转交。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}
