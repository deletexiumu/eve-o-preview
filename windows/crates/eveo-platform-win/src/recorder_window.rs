// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键录制的第二个来源：设置窗口自己收到的键盘消息（窗口子类化）。
// 真机上（用户的 Windows，装有卡巴斯基的键盘过滤驱动与「安全键盘输入」、征信中心的 PassGuard 安全控件）
// 实体按键大多到不了低级键盘钩子：录制器的钩子 36 秒里一个键盘事件都没收到，外部诊断钩子也一样，
// 但按键照常送到前台窗口（打字、玩游戏都正常）。这类防键盘记录组件只拦全局钩子，不拦前台窗口的消息。
// 录制时设置窗口就在前台，所以在它的窗口过程前面插一层子类过程：钩子没收到的键，这里补上。
//
// 两个来源共用同一份录制状态与同一套规则（on_key_down / on_key_up），谁先看到谁记结果：
// - 钩子先看到并吞掉的键，窗口根本收不到，不会重复；
// - 钩子没看到的键，窗口收到 WM_KEYDOWN / WM_SYSKEYDOWN，记下结果并吞掉这次按下与对应的松开，
//   不交给 Slint（否则空格、回车会按下焦点所在的按钮）。
// 修饰键用 GetKeyState 读：它跟着窗口消息走，正好是这条消息发生时的状态。
// 输入法打开时字母键的消息是 VK_PROCESSKEY，用 ImmGetVirtualKey 取回真正的键。
// 子类过程与安装、拆除都在主线程（窗口所在的线程）上；录制状态放在主线程的线程局部变量里。

//! 设置窗口的键盘消息，作为热键录制的第二个来源。

use std::cell::RefCell;

use eveo_core::hotkeys::HotkeyModifiers;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Input::Ime::ImmGetVirtualKey;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, VIRTUAL_KEY, VK_CONTROL, VK_LWIN, VK_MENU, VK_PROCESSKEY, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::{WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP};

use crate::recorder::{KeyAction, SharedState, Source, lock, on_key_down, on_key_up};

/// 子类过程的编号；同一个窗口上只装这一个。
const SUBCLASS_ID: usize = 0x4556_4F52; // "EVOR"

thread_local! {
    /// 主线程上的录制状态；子类过程没有好用的上下文参数，状态放这里。同一时刻只有一个录制器。
    static STATE: RefCell<Option<SharedState>> = const { RefCell::new(None) };
}

/// 在设置窗口上装子类过程。要在窗口所在的线程（主线程）上调用；失败时返回 false，录制只靠钩子。
pub(crate) fn install(window: HWND, state: SharedState) -> bool {
    STATE.with(|s| *s.borrow_mut() = Some(state));
    // SAFETY: 窗口属于调用线程；子类过程是本模块的 extern "system" 函数，拆除前一直有效。
    let ok = unsafe { SetWindowSubclass(window, Some(subclass_proc), SUBCLASS_ID, 0) }.as_bool();
    if !ok {
        STATE.with(|s| *s.borrow_mut() = None);
    }
    ok
}

/// 拆掉子类过程并清掉状态。窗口已销毁时拆除只是失败，状态照样清掉。
pub(crate) fn remove(window: HWND) {
    // SAFETY: 与 install 同一窗口、同一过程与编号；在主线程上调用。
    let _ = unsafe { RemoveWindowSubclass(window, Some(subclass_proc), SUBCLASS_ID) };
    STATE.with(|s| *s.borrow_mut() = None);
}

/// 此刻（这条消息发生时）按着的修饰键。
fn message_modifiers() -> HotkeyModifiers {
    // SAFETY: 只读当前线程的按键状态；最高位为 1 表示按着。
    let down = |key: VIRTUAL_KEY| unsafe { GetKeyState(i32::from(key.0)) } < 0;
    let mut modifiers = HotkeyModifiers::NONE;
    if down(VK_CONTROL) {
        modifiers |= HotkeyModifiers::CONTROL;
    }
    if down(VK_MENU) {
        modifiers |= HotkeyModifiers::ALT;
    }
    if down(VK_SHIFT) {
        modifiers |= HotkeyModifiers::SHIFT;
    }
    if down(VK_LWIN) || down(VK_RWIN) {
        modifiers |= HotkeyModifiers::WIN;
    }
    modifiers
}

/// 消息里的虚拟键码；输入法吃掉的键（VK_PROCESSKEY）换回真正的键。
fn message_key(window: HWND, wparam: WPARAM) -> u32 {
    let vk = wparam.0 as u32;
    if vk == u32::from(VK_PROCESSKEY.0) {
        // SAFETY: 窗口属于调用线程；输入法没有处理这条消息时原样返回 VK_PROCESSKEY。
        unsafe { ImmGetVirtualKey(window) }
    } else {
        vk
    }
}

/// 子类过程：录制中的按键按规则处理，要吞的不交给原来的窗口过程；其余原样转交。
unsafe extern "system" fn subclass_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    let down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    let up = message == WM_KEYUP || message == WM_SYSKEYUP;
    if down || up {
        let vk = message_key(window, wparam);
        let modifiers = message_modifiers();
        let action = STATE.with(|s| {
            s.borrow().as_ref().map(|state| {
                let mut state = lock(state);
                let action = if down {
                    on_key_down(&mut state, vk, modifiers)
                } else {
                    on_key_up(&mut state, vk)
                };
                // 诊断：窗口来源的事件也记下，日志里用「窗」标出。
                state.note_key(Source::Window, down, vk, modifiers, action);
                action
            })
        });
        if action == Some(KeyAction::Swallow) {
            return LRESULT(0);
        }
    }
    // SAFETY: 参数原样转交给下一层窗口过程。
    unsafe { DefSubclassProc(window, message, wparam, lparam) }
}
