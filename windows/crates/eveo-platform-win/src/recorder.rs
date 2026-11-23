// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键录制（架构文档 4.4 节，对应 macOS 的 HotkeyRecorder）：设置窗口点了录制按钮后，
// 在主线程装低级键盘钩子与低级鼠标钩子，取下一个组合键或鼠标中键、侧键。
// 用钩子而不是窗口的键盘消息：钩子给的是虚拟键码，分得清小键盘与主键盘的数字、F13～F24 这类键，
// 也能在 RegisterHotKey 之前拦下按键，录制时不会触发已注册的热键（应用同时暂停热键服务，双保险）。
//
// 规则与 macOS 相同：
// - 修饰键本身不结束录制，原样放行（系统的按键状态保持一致），等下一个非修饰键；
// - 单按 Esc 取消，单按 Backspace 或 Delete 清除这一行；
// - 其余按键连同此刻按着的修饰键成为结果，这次按下与对应的松开都吞掉，不会传给设置窗口；
// - 鼠标中键与两个侧键也录（连同修饰键），左右键照常放行。
// 按着 Win 时吞掉按键，松开 Win 会弹出开始菜单（系统认为 Win 是单独按的），所以先发一次未分配键打断它。
//
// 钩子回调里不调用应用：结果放进线程局部变量，应用在定时器里取（50 毫秒以内）。
// 这样回调很快返回，也不会在回调里摘掉自己。录制器丢弃时摘掉两个钩子。

//! 热键录制。

use std::cell::RefCell;

use eveo_core::hotkeys::{Hotkey, HotkeyModifiers};
use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    VK_BACK, VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU,
    VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, HC_ACTION, HHOOK, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSLLHOOKSTRUCT, SetWindowsHookExW,
    UnhookWindowsHookEx, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_MBUTTONDOWN, WM_MBUTTONUP,
    WM_SYSKEYDOWN, WM_SYSKEYUP, WM_XBUTTONDOWN, WM_XBUTTONUP, XBUTTON1, XBUTTON2,
};

use crate::{activation, mouse_hook, window_class};

/// 录制的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordOutcome {
    /// 录到一个组合（键盘组合，或鼠标按键加修饰键）。
    Recorded(Hotkey),
    /// 单按 Backspace 或 Delete：清除这一行。
    Cleared,
    /// 单按 Esc：取消。
    Cancelled,
}

/// 录制中的状态，钩子回调与录制器共用（都在主线程）。
#[derive(Default)]
struct State {
    /// 已有结果；之后的按键都放行（吞掉的那个键的松开除外）。
    outcome: Option<RecordOutcome>,
    /// 吞掉了按下的键盘键，它的松开也要吞掉，否则窗口会收到一个没有按下的松开。
    swallowed_key: Option<u32>,
    /// 吞掉了按下的鼠标按钮（按钮号），它的松开也要吞掉。
    swallowed_button: Option<u8>,
}

thread_local! {
    /// 当前录制的状态；没有在录时为 `None`。同一时刻只有一个录制器。
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

/// 正在进行的录制。丢弃时摘掉钩子。
pub struct HotkeyRecorder {
    /// 低级键盘钩子。
    keyboard: HHOOK,
    /// 低级鼠标钩子。
    mouse: HHOOK,
}

impl HotkeyRecorder {
    /// 开始录制。已有录制器时先丢弃旧的再调用（同一时刻只有一个）。
    pub fn start() -> Result<Self, String> {
        // 低级钩子要一个模块句柄（本 exe），钩子本身装在调用线程上：回调由这个线程的消息循环调用。
        let module = window_class::instance().map_err(|e| e.message())?;
        // SAFETY: 回调是本模块的 extern "system" 函数；低级钩子不注入别的进程，模块句柄取本 exe 的。
        let keyboard = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), Some(module), 0) }
            .map_err(|e| format!("安装低级键盘钩子失败：{}", e.message()))?;
        // SAFETY: 同上。
        let mouse = match unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), Some(module), 0) } {
            Ok(hook) => hook,
            Err(error) => {
                // SAFETY: 刚装上的键盘钩子，只摘一次。
                let _ = unsafe { UnhookWindowsHookEx(keyboard) };
                return Err(format!("安装低级鼠标钩子失败：{}", error.message()));
            }
        };
        // 两个钩子都装好后才开始记状态；装失败时不留下半套状态。
        STATE.with(|s| *s.borrow_mut() = Some(State::default()));
        Ok(Self { keyboard, mouse })
    }

    /// 取走结果；还没有结果时返回 `None`。取走后录制器仍在，吞掉的键的松开照样处理，由调用方丢弃它。
    /// 应用的定时器每 50 毫秒调一次；结果只交出一次。
    pub fn take_outcome(&self) -> Option<RecordOutcome> {
        STATE.with(|s| s.borrow_mut().as_mut().and_then(|state| state.outcome.take()))
    }
}

impl Drop for HotkeyRecorder {
    fn drop(&mut self) {
        // SAFETY: 两个钩子都由本线程在 start 里安装，只摘一次。
        unsafe {
            let _ = UnhookWindowsHookEx(self.keyboard);
            let _ = UnhookWindowsHookEx(self.mouse);
        }
        STATE.with(|s| *s.borrow_mut() = None);
    }
}

/// 修饰键（左右两侧与不分侧的写法）。
// 右 Win（VK_RWIN）单独比较，数组里放不下第 11 个。
const MODIFIER_KEYS: [u16; 10] = [
    VK_SHIFT.0,
    VK_LSHIFT.0,
    VK_RSHIFT.0,
    VK_CONTROL.0,
    VK_LCONTROL.0,
    VK_RCONTROL.0,
    VK_MENU.0,
    VK_LMENU.0,
    VK_RMENU.0,
    VK_LWIN.0,
];

/// 一次按键的处理结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeyAction {
    /// 放行。
    Pass,
    /// 吞掉。
    Swallow,
}

/// 按下一个键：修饰键放行；还没有结果时按规则得出结果并吞掉这个键。纯逻辑，单元测试用。
fn on_key_down(state: &mut State, vk: u32, modifiers: HotkeyModifiers) -> KeyAction {
    // 修饰键本身、已有结果后的按键、吞掉的键还没松开时的按键，都原样放行。
    let is_modifier = MODIFIER_KEYS.contains(&(vk as u16)) || vk == u32::from(VK_RWIN.0);
    if is_modifier || state.outcome.is_some() || state.swallowed_key.is_some() {
        return KeyAction::Pass;
    }
    // Esc、Backspace、Delete 只有单按时才是控制键；带修饰键时是普通的组合（如 Alt+Delete）。
    let alone = modifiers == HotkeyModifiers::NONE;
    let outcome = match vk {
        _ if alone && vk == u32::from(VK_ESCAPE.0) => RecordOutcome::Cancelled,
        _ if alone && (vk == u32::from(VK_BACK.0) || vk == u32::from(VK_DELETE.0)) => RecordOutcome::Cleared,
        // 虚拟键码是 1～254，放得进 u8；超出时（不应出现）放行。
        _ => match u8::try_from(vk) {
            Ok(code) => RecordOutcome::Recorded(Hotkey::key(code, modifiers)),
            Err(_) => return KeyAction::Pass,
        },
    };
    // 记下结果与吞掉的键；之后这个键的松开也吞掉。
    state.outcome = Some(outcome);
    state.swallowed_key = Some(vk);
    KeyAction::Swallow
}

/// 松开一个键：是吞掉的那个键就也吞掉。
/// 只跟踪吞掉的那一个键；修饰键的松开一律放行，系统的按键状态保持一致。
fn on_key_up(state: &mut State, vk: u32) -> KeyAction {
    if state.swallowed_key == Some(vk) {
        state.swallowed_key = None;
        KeyAction::Swallow
    } else {
        KeyAction::Pass
    }
}

/// 低级键盘钩子的回调。
unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        // SAFETY: HC_ACTION 时 lparam 指向系统提供的 KBDLLHOOKSTRUCT，在回调期间有效。
        let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        // 只跳过本应用自己注入的未分配键（下面为打断开始菜单发的那个）。别的注入按键照常录制：
        // 键盘驱动软件的宏键、远程桌面与自动化工具都是注入的，真机测试里全部跳过时用它们录不进热键。
        let own_key =
            info.flags.0 & LLKHF_INJECTED.0 != 0 && info.vkCode == u32::from(activation::UNASSIGNED_VK);
        // 按下有 WM_KEYDOWN 与 WM_SYSKEYDOWN 两种（按着 Alt 时是后者），松开同理。
        let message = wparam.0 as u32;
        let action = STATE.with(|s| {
            let mut state = s.borrow_mut();
            let Some(state) = state.as_mut().filter(|_| !own_key) else {
                return KeyAction::Pass;
            };
            match message {
                WM_KEYDOWN | WM_SYSKEYDOWN => {
                    on_key_down(state, info.vkCode, mouse_hook::current_modifiers())
                }
                WM_KEYUP | WM_SYSKEYUP => on_key_up(state, info.vkCode),
                _ => KeyAction::Pass,
            }
        });
        if action == KeyAction::Swallow {
            // 按着 Win 时吞掉了按键：发一次未分配键，松开 Win 时不弹开始菜单。
            if message == WM_KEYDOWN || message == WM_SYSKEYDOWN {
                let modifiers = mouse_hook::current_modifiers();
                if modifiers.contains(HotkeyModifiers::WIN) {
                    activation::send_unassigned_key();
                }
            }
            return LRESULT(1);
        }
    }
    // SAFETY: 参数原样转交；低级钩子的第一个参数被忽略。
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// 鼠标按钮按下或松开：中键与侧键按下时录下（连同修饰键），松开时吞掉对应的松开。
fn on_mouse(state: &mut State, button: u8, down: bool, modifiers: HotkeyModifiers) -> KeyAction {
    if !down {
        if state.swallowed_button == Some(button) {
            state.swallowed_button = None;
            return KeyAction::Swallow;
        }
        return KeyAction::Pass;
    }
    if state.outcome.is_some() || state.swallowed_key.is_some() {
        return KeyAction::Pass;
    }
    // 按钮号在 2～31 之外不会出现（上面只给 2～4）；保险起见不在范围内时放行。
    match Hotkey::mouse(button, modifiers) {
        Some(hotkey) => {
            state.outcome = Some(RecordOutcome::Recorded(hotkey));
            state.swallowed_button = Some(button);
            KeyAction::Swallow
        }
        None => KeyAction::Pass,
    }
}

/// 低级鼠标钩子的回调。只看中键与侧键，其余（移动、左右键、滚轮）原样放行。
unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        // SAFETY: HC_ACTION 时 lparam 指向系统提供的 MSLLHOOKSTRUCT，在回调期间有效。
        let info = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
        // 侧键的编号在 mouseData 的高 16 位：XBUTTON1 是后退键（Mouse4），XBUTTON2 是前进键（Mouse5）。
        let x_button = || match (info.mouseData >> 16) as u16 {
            XBUTTON1 => Some(3),
            XBUTTON2 => Some(4),
            _ => None,
        };
        // 只关心中键与侧键的按下、松开；左右键要留给设置窗口本身（点按钮、取消录制）。
        let event = match wparam.0 as u32 {
            WM_MBUTTONDOWN => Some((2, true)),
            WM_MBUTTONUP => Some((2, false)),
            WM_XBUTTONDOWN => x_button().map(|b| (b, true)),
            WM_XBUTTONUP => x_button().map(|b| (b, false)),
            _ => None,
        };
        if let Some((button, down)) = event {
            let action = STATE.with(|s| match s.borrow_mut().as_mut() {
                Some(state) => on_mouse(state, button, down, mouse_hook::current_modifiers()),
                None => KeyAction::Pass,
            });
            if action == KeyAction::Swallow {
                return LRESULT(1);
            }
        }
    }
    // SAFETY: 参数原样转交。
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::UI::Input::KeyboardAndMouse::{VK_F13, VK_NUMPAD1};

    /// 修饰键放行；第一个非修饰键成为结果并吞掉，它的松开也吞掉；之后的按键放行。
    #[test]
    fn records_first_non_modifier_key() {
        let mut state = State::default();
        // 按住左 Ctrl（修饰键本身放行），再按小键盘 1：录成 Ctrl+Num1。
        let ctrl = HotkeyModifiers::CONTROL;
        assert_eq!(
            on_key_down(&mut state, u32::from(VK_LCONTROL.0), ctrl),
            KeyAction::Pass
        );
        assert_eq!(
            on_key_down(&mut state, u32::from(VK_NUMPAD1.0), ctrl),
            KeyAction::Swallow
        );
        assert_eq!(
            state.outcome,
            Some(RecordOutcome::Recorded(Hotkey::key(VK_NUMPAD1.0 as u8, ctrl)))
        );
        assert_eq!(
            on_key_down(&mut state, u32::from(VK_F13.0), ctrl),
            KeyAction::Pass
        );
        assert_eq!(on_key_up(&mut state, u32::from(VK_NUMPAD1.0)), KeyAction::Swallow);
        assert_eq!(on_key_up(&mut state, u32::from(VK_NUMPAD1.0)), KeyAction::Pass);
    }

    /// 单按 Esc 取消、单按 Backspace 清除；带修饰键时它们是普通的组合。
    #[test]
    fn escape_cancels_and_backspace_clears_only_alone() {
        let mut state = State::default();
        // 每种情况用新的状态：一次录制只有一个结果。
        on_key_down(&mut state, u32::from(VK_ESCAPE.0), HotkeyModifiers::NONE);
        assert_eq!(state.outcome, Some(RecordOutcome::Cancelled));
        let mut state = State::default();
        on_key_down(&mut state, u32::from(VK_BACK.0), HotkeyModifiers::NONE);
        assert_eq!(state.outcome, Some(RecordOutcome::Cleared));
        let mut state = State::default();
        // Alt+Delete 是普通组合，不是清除。
        on_key_down(&mut state, u32::from(VK_DELETE.0), HotkeyModifiers::ALT);
        assert_eq!(
            state.outcome,
            Some(RecordOutcome::Recorded(Hotkey::key(
                VK_DELETE.0 as u8,
                HotkeyModifiers::ALT
            )))
        );
    }

    /// 侧键连同修饰键录下，按下与松开都吞掉；有结果后其他按钮放行。
    #[test]
    fn records_mouse_side_button() {
        let mut state = State::default();
        // Shift 加第一个侧键（按钮号 3，写作 Mouse4）。
        let shift = HotkeyModifiers::SHIFT;
        assert_eq!(on_mouse(&mut state, 3, true, shift), KeyAction::Swallow);
        assert_eq!(
            state.outcome,
            Some(RecordOutcome::Recorded(Hotkey::mouse(3, shift).unwrap()))
        );
        // 已有结果：之后按中键不再录，原样放行。
        assert_eq!(on_mouse(&mut state, 2, true, shift), KeyAction::Pass);
        // 侧键的松开吞掉一次；第二次（没有对应的按下）放行。
        assert_eq!(on_mouse(&mut state, 3, false, shift), KeyAction::Swallow);
        assert_eq!(on_mouse(&mut state, 3, false, shift), KeyAction::Pass);
    }
}
