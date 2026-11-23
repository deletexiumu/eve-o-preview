// SPDX-License-Identifier: GPL-3.0-or-later
//
// 键盘热键（架构文档 4.4 节）：RegisterHotKey 绑定到本线程的一个消息窗口，带 MOD_NOREPEAT。
// 编号用 Core 的 hotkey_id 编码（含代数），热键消息里的编号交回 Core 解码。不装键盘钩子。
// 应用里主循环是 Slint（winit）的，消息由它分发，我们看不到分发前的消息，所以热键与鼠标热键的消息
// 在窗口过程里交给 `set_handler` 设的处理函数。探针自己跑消息泵时也可以在分发前用 `hotkey_id` 取。

//! 键盘热键的注册与注销。

use std::cell::RefCell;
use std::collections::HashMap;

use eveo_core::hotkeys::HotkeyModifiers;
use windows::Win32::Foundation::{ERROR_HOTKEY_ALREADY_REGISTERED, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::HBRUSH;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    HOT_KEY_MODIFIERS, MOD_NOREPEAT, RegisterHotKey, UnregisterHotKey,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, HWND_MESSAGE, MSG, WINDOW_EX_STYLE, WINDOW_STYLE,
    WM_HOTKEY,
};
use windows::core::{PCWSTR, Result};

use crate::mouse_hook::WM_MOUSE_HOTKEY;
use crate::window_class;

/// 热键窗口收到的一条触发。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyMessage {
    /// 键盘热键，附注册时的编号。
    Keyboard(i32),
    /// 鼠标热键，附绑定编号（见 `mouse_hook`）。
    Mouse(u32),
}

/// 处理函数的类型。
type Handler = Box<dyn FnMut(HotkeyMessage)>;

thread_local! {
    /// 各热键窗口的处理函数，以窗口句柄的数值为键。窗口与处理函数都在主线程上。
    static HANDLERS: RefCell<HashMap<usize, Handler>> = RefCell::new(HashMap::new());
}

/// 注册失败的原因。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegisterError {
    /// 组合已被别的程序（或系统）注册，设置页在该热键旁标出冲突。
    AlreadyRegistered,
    /// 其他错误，附系统的错误信息。
    Other(String),
}

/// 接收热键消息的隐藏窗口。丢弃时注销全部热键并销毁窗口。
pub struct HotkeyWindow {
    hwnd: HWND,
    registered: Vec<i32>,
}

impl HotkeyWindow {
    /// 在本线程上建一个只收消息的窗口（不可见、不进 Z 序）。
    pub fn create() -> Result<Self> {
        let class = window_class::ensure("EVEOPreview.HotkeySink", Some(window_proc), HBRUSH::default())?;
        // SAFETY: 类名缓冲区在调用期间有效；父窗口 HWND_MESSAGE 表示只收消息的窗口。
        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                PCWSTR(class.as_ptr()),
                PCWSTR::null(),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                Some(window_class::instance()?),
                None,
            )?
        };
        Ok(Self {
            hwnd,
            registered: Vec::new(),
        })
    }

    /// 注册一个热键。id 用 `eveo_core::hotkeys::backend::hotkey_id::encode` 得到。
    pub fn register(
        &mut self,
        id: i32,
        modifiers: HotkeyModifiers,
        key_code: u8,
    ) -> std::result::Result<(), RegisterError> {
        let flags = HOT_KEY_MODIFIERS(modifiers.win32_flags()) | MOD_NOREPEAT;
        // SAFETY: 窗口属于本线程，由 create 建立。
        match unsafe { RegisterHotKey(Some(self.hwnd), id, flags, u32::from(key_code)) } {
            Ok(()) => {
                self.registered.push(id);
                Ok(())
            }
            Err(error) if error.code() == ERROR_HOTKEY_ALREADY_REGISTERED.to_hresult() => {
                Err(RegisterError::AlreadyRegistered)
            }
            Err(error) => Err(RegisterError::Other(error.message())),
        }
    }

    /// 注销一个热键；没注册过时什么也不做。
    pub fn unregister(&mut self, id: i32) {
        if let Some(index) = self.registered.iter().position(|&r| r == id) {
            self.registered.swap_remove(index);
            // SAFETY: 窗口与编号都由本对象注册。
            let _ = unsafe { UnregisterHotKey(Some(self.hwnd), id) };
        }
    }

    /// 注销全部热键。
    pub fn unregister_all(&mut self) {
        for id in std::mem::take(&mut self.registered) {
            // SAFETY: 同上。
            let _ = unsafe { UnregisterHotKey(Some(self.hwnd), id) };
        }
    }

    /// 设置处理函数：窗口过程收到键盘热键或鼠标热键的消息时调用。替换已有的处理函数。
    pub fn set_handler(&self, handler: impl FnMut(HotkeyMessage) + 'static) {
        HANDLERS.with(|h| h.borrow_mut().insert(self.hwnd.0 as usize, Box::new(handler)));
    }

    /// 窗口句柄。鼠标热键（`mouse_hook`）也把触发消息投递到这里。
    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }

    /// 一条消息是不是发给本窗口的热键消息；是时返回热键编号。
    pub fn hotkey_id(&self, msg: &MSG) -> Option<i32> {
        (msg.hwnd == self.hwnd && msg.message == WM_HOTKEY).then_some(msg.wParam.0 as i32)
    }
}

impl Drop for HotkeyWindow {
    fn drop(&mut self) {
        self.unregister_all();
        HANDLERS.with(|h| h.borrow_mut().remove(&(self.hwnd.0 as usize)));
        // SAFETY: 窗口由 create 建立，属于本线程，只销毁一次。
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// 窗口过程：热键与鼠标热键的消息交给处理函数，其余交给默认处理。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let message = match msg {
        WM_HOTKEY => Some(HotkeyMessage::Keyboard(wparam.0 as i32)),
        WM_MOUSE_HOTKEY => Some(HotkeyMessage::Mouse(wparam.0 as u32)),
        _ => None,
    };
    if let Some(message) = message {
        dispatch(hwnd, message);
        return LRESULT(0);
    }
    // SAFETY: 参数原样转交。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// 调用窗口的处理函数。调用期间先把它从表里取出，处理函数里再设或删处理函数也不会重复借用。
fn dispatch(hwnd: HWND, message: HotkeyMessage) {
    let key = hwnd.0 as usize;
    let Some(mut handler) = HANDLERS.with(|h| h.borrow_mut().remove(&key)) else {
        return;
    };
    handler(message);
    HANDLERS.with(|h| {
        h.borrow_mut().entry(key).or_insert(handler);
    });
}
