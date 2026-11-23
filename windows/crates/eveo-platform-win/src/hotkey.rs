// SPDX-License-Identifier: GPL-3.0-or-later
//
// 键盘热键（架构文档 4.4 节）：RegisterHotKey 绑定到本线程的一个消息窗口，带 MOD_NOREPEAT。
// 编号用 Core 的 hotkey_id 编码（含代数），热键消息里的编号交回 Core 解码。不装键盘钩子。

//! 键盘热键的注册与注销。

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

use crate::window_class;

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
        // SAFETY: 窗口由 create 建立，属于本线程，只销毁一次。
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// 窗口过程：热键消息由消息泵在分发前取走，这里全部交给默认处理。
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    // SAFETY: 参数原样转交。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}
