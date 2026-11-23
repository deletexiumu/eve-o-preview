// SPDX-License-Identifier: GPL-3.0-or-later
//
// 通知区域图标（托盘）与应用的主消息窗口（架构文档 4.8 节、4.10 节）。
// 一个隐藏的顶层窗口同时承担三件事：
// - Shell_NotifyIconW 的回调窗口：选中（左键单击或键盘回车）、上下文菜单（右键单击或键盘的菜单键）送给处理函数；
// - 资源管理器重启后广播的 TaskbarCreated 消息：重新添加图标，否则图标会消失；
// - 单实例的唤醒消息（`single_instance`）：第二个实例找到这个窗口，发消息让它打开设置。
// 它必须是顶层窗口（不能是 HWND_MESSAGE 的子窗口），否则收不到 TaskbarCreated 这样的广播。
//
// 回调用 NOTIFYICON_VERSION_4 的格式（NIN_SELECT、WM_CONTEXTMENU），不用旧版的原始鼠标消息。这是微软
// 推荐的格式，键盘操作托盘图标时也有反应。另一个原因：旧版回调下，图标在任务栏的溢出菜单里时，打开设置窗口后
// 溢出菜单一直留在屏幕上（真机测试发现）；新格式下系统知道图标被「选中」了，按它的习惯处理溢出菜单。

//! 托盘图标与主消息窗口。

use std::cell::RefCell;
use std::collections::HashMap;

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::HBRUSH;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY, NIM_SETVERSION, NIN_SELECT,
    NOTIFYICON_VERSION_4, NOTIFYICONDATAW, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetSystemMetrics, HICON, IDI_APPLICATION, IMAGE_ICON,
    LR_DEFAULTCOLOR, LoadIconW, LoadImageW, RegisterWindowMessageW, SM_CXSMICON, SM_CYSMICON,
    WINDOW_EX_STYLE, WM_APP, WM_CONTEXTMENU, WS_OVERLAPPED,
};
use windows::core::{PCWSTR, Result};

use crate::text::wide;
use crate::window_class;

/// 主消息窗口的类名。第二个实例按它找第一个实例（`single_instance::notify_primary`）。
pub const MAIN_WINDOW_CLASS: &str = "EVEOPreview.Main";
/// 单实例唤醒消息的名字（`RegisterWindowMessageW`）。
pub const ACTIVATE_MESSAGE_NAME: &str = "EVEOPreview.ActivateExisting";
/// exe 里应用图标的资源编号（eveo-app 的 app.rc）。
const APP_ICON_ID: u16 = 1;
/// 托盘图标的回调消息。
const WM_TRAY: u32 = WM_APP + 0x40;
/// 键盘选中图标（空格或回车）：NIN_SELECT 加上 NINF_KEY 标志。windows 包里没有单独的常量。
const NIN_KEYSELECT: u32 = NIN_SELECT | 0x1;

/// 主消息窗口收到的事件。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayEvent {
    /// 选中托盘图标：左键单击，或用键盘选中后按空格、回车。
    LeftClick,
    /// 要托盘图标的上下文菜单：右键单击，或用键盘选中后按菜单键、Shift+F10。
    RightClick,
    /// 另一个实例启动后请求本实例打开设置窗口。
    ActivateRequested,
}

/// 处理函数的类型。
type Handler = Box<dyn FnMut(TrayEvent)>;

thread_local! {
    /// 主消息窗口的处理函数，以窗口句柄的数值为键。
    static HANDLERS: RefCell<HashMap<usize, Handler>> = RefCell::new(HashMap::new());
    /// 每个主消息窗口当前的图标数据，资源管理器重启后用它重新添加。
    static ICONS: RefCell<HashMap<usize, NOTIFYICONDATAW>> = RefCell::new(HashMap::new());
}

/// 托盘图标与主消息窗口。丢弃时移除图标并销毁窗口。
pub struct TrayIcon {
    hwnd: HWND,
}

impl TrayIcon {
    /// 建主消息窗口并添加托盘图标。`tooltip` 是鼠标停在图标上时的提示（最多 127 个 UTF-16 单元）。
    pub fn create(tooltip: &str) -> Result<Self> {
        let class = window_class::ensure(MAIN_WINDOW_CLASS, Some(window_proc), HBRUSH::default())?;
        // SAFETY: 类名缓冲区在调用期间有效；窗口不显示。
        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                PCWSTR(class.as_ptr()),
                PCWSTR::null(),
                WS_OVERLAPPED,
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
        let mut data = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
            uCallbackMessage: WM_TRAY,
            hIcon: default_icon(),
            ..Default::default()
        };
        copy_tip(&mut data, tooltip);
        add_icon(&data);
        ICONS.with(|i| i.borrow_mut().insert(hwnd.0 as usize, data));
        Ok(Self { hwnd })
    }

    /// 设置处理函数。替换已有的处理函数。
    pub fn set_handler(&self, handler: impl FnMut(TrayEvent) + 'static) {
        HANDLERS.with(|h| h.borrow_mut().insert(self.hwnd.0 as usize, Box::new(handler)));
    }

    /// 改提示文字（例如显示客户端数）。
    pub fn set_tooltip(&self, tooltip: &str) {
        ICONS.with(|icons| {
            if let Some(data) = icons.borrow_mut().get_mut(&(self.hwnd.0 as usize)) {
                copy_tip(data, tooltip);
                // SAFETY: data 有效。
                let _ = unsafe { Shell_NotifyIconW(NIM_MODIFY, data) };
            }
        });
    }

    /// 主消息窗口的句柄，弹出托盘菜单时作为所有者。
    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }
}

impl Drop for TrayIcon {
    fn drop(&mut self) {
        let key = self.hwnd.0 as usize;
        if let Some(data) = ICONS.with(|i| i.borrow_mut().remove(&key)) {
            // SAFETY: data 是添加时用的那份。
            let _ = unsafe { Shell_NotifyIconW(NIM_DELETE, &data) };
        }
        HANDLERS.with(|h| h.borrow_mut().remove(&key));
        // SAFETY: 窗口由 create 建立，只销毁一次。
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// 应用图标：exe 里嵌入的图标，取小图标的尺寸（托盘按它显示，随系统缩放）。
/// 没有嵌入图标资源时（探针等其他可执行文件）用系统的通用应用图标。
fn default_icon() -> HICON {
    // SAFETY: 取本进程 exe 的模块句柄；资源编号按 MAKEINTRESOURCE 的约定放进指针。
    // ico 里有多个尺寸，LoadImageW 挑最接近的一张；图标随进程存在，不需要释放。
    let embedded = unsafe {
        let module = GetModuleHandleW(None).ok();
        module.and_then(|module| {
            LoadImageW(
                Some(module.into()),
                PCWSTR(APP_ICON_ID as usize as *const u16),
                IMAGE_ICON,
                GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON),
                LR_DEFAULTCOLOR,
            )
            .ok()
        })
    };
    if let Some(handle) = embedded {
        return HICON(handle.0);
    }
    // SAFETY: 加载系统预置的图标，实例传 None；失败时不显示图标但不影响功能。
    unsafe { LoadIconW(None, IDI_APPLICATION) }.unwrap_or_default()
}

/// 添加图标并声明用 NOTIFYICON_VERSION_4 的回调格式。版本不随图标保存：资源管理器重启后重新添加时也要再设。
fn add_icon(data: &NOTIFYICONDATAW) {
    // SAFETY: data 的大小与字段已填好；添加失败（例如资源管理器还没起来）时等 TaskbarCreated 再加。
    if !unsafe { Shell_NotifyIconW(NIM_ADD, data) }.as_bool() {
        return;
    }
    // 版本放在与超时共用的联合体里；只设这一项，其余字段沿用添加时的值。
    let mut versioned = *data;
    versioned.Anonymous.uVersion = NOTIFYICON_VERSION_4;
    // SAFETY: 同上。设版本失败时回调仍是旧格式，左键与右键收不到；这种情况在 Vista 之后的系统上不会发生。
    let _ = unsafe { Shell_NotifyIconW(NIM_SETVERSION, &versioned) };
}

/// 把提示文字复制进定长缓冲区，超长时截断，末尾补 0。
fn copy_tip(data: &mut NOTIFYICONDATAW, tooltip: &str) {
    let units: Vec<u16> = tooltip.encode_utf16().take(data.szTip.len() - 1).collect();
    data.szTip = [0; 128];
    data.szTip[..units.len()].copy_from_slice(&units);
}

/// 注册过的窗口消息的编号；同名消息在整个系统里编号相同。
fn registered_message(name: &str) -> u32 {
    let name = wide(name);
    // SAFETY: 名字缓冲区在调用期间有效。
    unsafe { RegisterWindowMessageW(PCWSTR(name.as_ptr())) }
}

/// 窗口过程：托盘回调与唤醒消息交给处理函数；资源管理器重启时重新添加图标。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let event = if msg == WM_TRAY {
        // NOTIFYICON_VERSION_4：lparam 的低 16 位是事件，高 16 位是图标编号；wparam 是锚点坐标（不用，
        // 托盘菜单按光标位置弹出）。鼠标移动、按下等其他事件不处理。
        match (lparam.0 as u32) & 0xFFFF {
            NIN_SELECT | NIN_KEYSELECT => Some(TrayEvent::LeftClick),
            WM_CONTEXTMENU => Some(TrayEvent::RightClick),
            _ => None,
        }
    } else if msg == registered_message(ACTIVATE_MESSAGE_NAME) {
        Some(TrayEvent::ActivateRequested)
    } else if msg == registered_message("TaskbarCreated") {
        ICONS.with(|icons| {
            if let Some(data) = icons.borrow().get(&(hwnd.0 as usize)) {
                add_icon(data);
            }
        });
        None
    } else {
        None
    };
    if let Some(event) = event {
        dispatch(hwnd, event);
        return LRESULT(0);
    }
    // SAFETY: 参数原样转交。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// 调用处理函数。调用期间先从表里取出，处理函数里弹菜单（模态循环）再收到托盘消息时不会重复借用。
fn dispatch(hwnd: HWND, event: TrayEvent) {
    let key = hwnd.0 as usize;
    let Some(mut handler) = HANDLERS.with(|h| h.borrow_mut().remove(&key)) else {
        return;
    };
    handler(event);
    HANDLERS.with(|h| {
        h.borrow_mut().entry(key).or_insert(handler);
    });
}
