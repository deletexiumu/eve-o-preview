// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键录制（架构文档 4.4 节，对应 macOS 的 HotkeyRecorder）：设置窗口点了录制按钮后，
// 装低级键盘钩子与低级鼠标钩子，取下一个组合键或鼠标中键、侧键。
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
// 两个钩子装在专用线程上，该线程只跑自己的消息循环（同 mouse_hook）。低级钩子的回调由安装它的线程的
// 消息循环调用，系统要等回调返回才把按键交给下一个钩子和前台窗口；回调超过时限（LowLevelHooksTimeout）时，
// 这次按键会丢掉，钩子还可能被系统悄悄摘掉。早先钩子装在主线程上，主线程忙着刷新设置页、缩略图时
// 回调来不及返回，真机上约四成的组合键（Ctrl+Shift+J、Ctrl+J 等）整批消失，按钮一直停在「按下组合键…」。
// 专用线程的回调不受主线程影响。结果放进共享状态（锁保护），应用在定时器里取（50 毫秒以内）。
// 录制器丢弃时让线程退出，线程摘掉两个钩子。

//! 热键录制。

use std::cell::RefCell;
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;

use eveo_core::hotkeys::{Hotkey, HotkeyModifiers};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    VK_BACK, VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU,
    VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetMessageW, HC_ACTION, HHOOK, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, MSLLHOOKSTRUCT,
    PM_NOREMOVE, PeekMessageW, PostThreadMessageW, SetWindowsHookExW, UnhookWindowsHookEx, WH_KEYBOARD_LL,
    WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_QUIT, WM_SYSKEYDOWN, WM_SYSKEYUP,
    WM_XBUTTONDOWN, WM_XBUTTONUP, XBUTTON1, XBUTTON2,
};

use crate::{activation, mouse_hook, recorder_window, window_class};

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

/// 录制中的状态，钩子线程的回调与主线程的窗口子类过程写、主线程的定时器读，由锁保护。
#[derive(Default)]
pub(crate) struct State {
    /// 已有结果；之后的按键都放行（吞掉的那个键的松开除外）。
    outcome: Option<RecordOutcome>,
    /// 吞掉了按下的键盘键，它的松开也要吞掉，否则窗口会收到一个没有按下的松开。
    swallowed_key: Option<u32>,
    /// 吞掉了按下的鼠标按钮（按钮号），它的松开也要吞掉。
    swallowed_button: Option<u8>,
    /// 诊断：钩子回调收到的键盘事件数（含修饰键与松开），用来判断钩子是否真的在工作。
    keys_seen: u32,
    /// 诊断：设置窗口收到的键盘消息数（钩子没收到的键会出现在这里）。
    window_keys_seen: u32,
    /// 诊断：钩子回调收到的中键、侧键事件数。
    buttons_seen: u32,
    /// 诊断：最近几次键盘事件的简写（如 `↓A2 C`、`↓4A CS 吞`），录制结束时写进日志。
    trace: Vec<String>,
}

/// 诊断记录最多保留的键盘事件条数；更早的丢掉，日志一行放得下。
const TRACE_LIMIT: usize = 16;

impl State {
    /// 记一次键盘事件：计数，并把简写放进最近事件的记录里。
    pub(crate) fn note_key(
        &mut self,
        source: Source,
        down: bool,
        vk: u32,
        modifiers: HotkeyModifiers,
        action: KeyAction,
    ) {
        let counter = match source {
            Source::Hook => &mut self.keys_seen,
            Source::Window => &mut self.window_keys_seen,
        };
        *counter = counter.saturating_add(1);
        if self.trace.len() == TRACE_LIMIT {
            self.trace.remove(0);
        }
        // 窗口来源的事件前面加「窗」，钩子来源的不加。
        let origin = if source == Source::Window { "窗" } else { "" };
        let arrow = if down { '↓' } else { '↑' };
        let swallowed = if action == KeyAction::Swallow { " 吞" } else { "" };
        self.trace.push(format!(
            "{origin}{arrow}{vk:02X} {}{swallowed}",
            modifier_letters(modifiers)
        ));
    }
}

/// 修饰键的简写：C、A、S、W 依次表示 Ctrl、Alt、Shift、Win；没有修饰键时是 `-`。
fn modifier_letters(modifiers: HotkeyModifiers) -> String {
    let letters: String = [
        (HotkeyModifiers::CONTROL, 'C'),
        (HotkeyModifiers::ALT, 'A'),
        (HotkeyModifiers::SHIFT, 'S'),
        (HotkeyModifiers::WIN, 'W'),
    ]
    .into_iter()
    .filter(|(flag, _)| modifiers.contains(*flag))
    .map(|(_, letter)| letter)
    .collect();
    if letters.is_empty() { "-".into() } else { letters }
}

/// 两个线程共用的录制状态。
pub(crate) type SharedState = Arc<Mutex<State>>;

/// 一次键盘事件从哪里来，诊断日志用。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Source {
    /// 低级键盘钩子。
    Hook,
    /// 设置窗口自己的键盘消息（见 recorder_window）。
    Window,
}

thread_local! {
    /// 钩子线程上的录制状态。回调没有上下文参数，只能放在线程局部变量里；只有钩子线程会设置它。
    static STATE: RefCell<Option<SharedState>> = const { RefCell::new(None) };
}

/// 正在进行的录制。丢弃时让钩子线程摘掉钩子并退出。
pub struct HotkeyRecorder {
    /// 钩子线程的编号，用来投递 WM_QUIT。
    thread_id: u32,
    /// 钩子线程；丢弃时等它退出，保证返回后钩子已经摘掉。
    join: Option<JoinHandle<()>>,
    /// 与钩子线程共用的状态。
    state: SharedState,
    /// 开始录制的时刻，诊断日志用。
    started: std::time::Instant,
    /// 钩子线程的编号，诊断日志用（与 thread_id 相同，单独留一份免得混淆用途）。
    hook_thread: u32,
    /// 下一次「录制中仍无结果」诊断日志的时刻（录制开始后的秒数），每 5 秒一次。
    next_report: std::cell::Cell<u64>,
    /// 装了子类过程的设置窗口；没有窗口或装不上时为 `None`，录制只靠钩子。
    window: Option<HWND>,
}

/// 「录制中仍无结果」诊断日志的间隔（秒）。
const REPORT_INTERVAL: u64 = 5;

impl HotkeyRecorder {
    /// 开始录制：启动钩子线程，两个钩子都装好后才返回；再在设置窗口上装子类过程作为第二个来源。
    /// `window` 是设置窗口（要在它所在的线程上调用）；传 `None` 时只靠钩子（探针用）。
    /// 已有录制器时先丢弃旧的再调用（同一时刻只有一个）。
    pub fn start(window: Option<HWND>) -> Result<Self, String> {
        let state = SharedState::default();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<u32, String>>();
        let thread_state = Arc::clone(&state);
        let join = std::thread::Builder::new()
            .name("eveo-hotkey-recorder".into())
            .spawn(move || run(thread_state, ready_tx))
            .map_err(|e| format!("启动录制线程失败：{e}"))?;
        // 等线程报告就绪：装钩子失败时线程已经退出，这里收回线程再返回错误。
        match ready_rx.recv() {
            Ok(Ok(thread_id)) => {
                // 子类过程装不上（极少见）时照样录，只是少了窗口这个来源。
                let window = window.filter(|&hwnd| recorder_window::install(hwnd, Arc::clone(&state)));
                Ok(Self {
                    thread_id,
                    join: Some(join),
                    state,
                    started: std::time::Instant::now(),
                    hook_thread: thread_id,
                    next_report: std::cell::Cell::new(REPORT_INTERVAL),
                    window,
                })
            }
            Ok(Err(message)) => {
                let _ = join.join();
                Err(message)
            }
            Err(_) => {
                let _ = join.join();
                Err("录制线程意外退出".into())
            }
        }
    }

    /// 取走结果；还没有结果时返回 `None`。取走后录制器仍在，吞掉的键的松开照样处理，由调用方丢弃它。
    /// 应用的定时器每 50 毫秒调一次；结果只交出一次。
    pub fn take_outcome(&self) -> Option<RecordOutcome> {
        lock(&self.state).outcome.take()
    }

    /// 已经录了多久。
    pub fn elapsed(&self) -> std::time::Duration {
        self.started.elapsed()
    }

    /// 到了该写「录制中仍无结果」诊断日志的时候返回真，每 5 秒只返回一次真。
    pub fn report_due(&self) -> bool {
        let due = self.started.elapsed().as_secs() >= self.next_report.get();
        if due {
            self.next_report.set(self.next_report.get() + REPORT_INTERVAL);
        }
        due
    }

    /// 诊断摘要：钩子线程、收到的事件数与最近的键盘事件，写进日志排查「按了没反应」。
    /// 例：`钩子线程 1234，键盘事件 6，鼠标按键 0，最近：↓A2 C ↓A0 CS ↓4A CS 吞 ↑4A CS 吞`。
    pub fn summary(&self) -> String {
        let state = lock(&self.state);
        format!(
            "钩子线程 {}，钩子键盘事件 {}，窗口键盘消息 {}（{}），鼠标按键 {}，最近：{}",
            self.hook_thread,
            state.keys_seen,
            state.window_keys_seen,
            if self.window.is_some() {
                "已接上"
            } else {
                "未接上"
            },
            state.buttons_seen,
            if state.trace.is_empty() {
                "（无）".into()
            } else {
                state.trace.join(" ")
            }
        )
    }
}

impl Drop for HotkeyRecorder {
    fn drop(&mut self) {
        // 先拆窗口的子类过程（主线程上），再停钩子线程。
        if let Some(window) = self.window {
            recorder_window::remove(window);
        }
        // SAFETY: 线程编号来自钩子线程自己，消息队列在报告就绪前已建立。线程收到 WM_QUIT 后摘掉钩子并退出。
        let _ = unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) };
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

/// 加锁；另一个线程拿着锁时崩溃（不应出现）也照常取出状态，录制不因此卡住。
pub(crate) fn lock(state: &SharedState) -> std::sync::MutexGuard<'_, State> {
    state.lock().unwrap_or_else(|e| e.into_inner())
}

/// 钩子线程：建消息队列、装两个钩子、报告就绪，然后跑消息循环直到 WM_QUIT，最后摘掉钩子。
fn run(state: SharedState, ready: mpsc::Sender<Result<u32, String>>) {
    let mut msg = MSG::default();
    // SAFETY: msg 是本函数的局部变量；PM_NOREMOVE 只为让系统给本线程建消息队列，WM_QUIT 才投递得进来。
    let _ = unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE) };
    STATE.with(|s| *s.borrow_mut() = Some(state));
    let hooks = match install_hooks() {
        Ok(hooks) => hooks,
        Err(message) => {
            let _ = ready.send(Err(message));
            return;
        }
    };
    // SAFETY: 只读当前线程的编号。
    let _ = ready.send(Ok(unsafe { GetCurrentThreadId() }));
    // 回调在 GetMessageW 里被调用；这个线程不做别的事，回调总能及时返回。
    // SAFETY: msg 是局部变量；GetMessageW 在 WM_QUIT 时返回 0，出错时返回 -1。
    while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {}
    // SAFETY: 两个钩子都由本线程安装，只摘一次。
    unsafe {
        let _ = UnhookWindowsHookEx(hooks.0);
        let _ = UnhookWindowsHookEx(hooks.1);
    }
    STATE.with(|s| *s.borrow_mut() = None);
}

/// 在当前线程装低级键盘钩子与低级鼠标钩子；鼠标钩子装不上时摘掉已装的键盘钩子，不留下半套。
fn install_hooks() -> Result<(HHOOK, HHOOK), String> {
    // 低级钩子要一个模块句柄（本 exe），钩子本身装在调用线程上：回调由这个线程的消息循环调用。
    let module = window_class::instance().map_err(|e| e.message())?;
    // SAFETY: 回调是本模块的 extern "system" 函数；低级钩子不注入别的进程，模块句柄取本 exe 的。
    let keyboard = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), Some(module), 0) }
        .map_err(|e| format!("安装低级键盘钩子失败：{}", e.message()))?;
    // SAFETY: 同上。
    match unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), Some(module), 0) } {
        Ok(mouse) => Ok((keyboard, mouse)),
        Err(error) => {
            // SAFETY: 刚装上的键盘钩子，只摘一次。
            let _ = unsafe { UnhookWindowsHookEx(keyboard) };
            Err(format!("安装低级鼠标钩子失败：{}", error.message()))
        }
    }
}

/// 在钩子线程上对录制状态做一件事；不在录制线程上（状态为空）时返回 `None`。
fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> Option<R> {
    STATE.with(|s| s.borrow().as_ref().map(|state| f(&mut lock(state))))
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
pub(crate) enum KeyAction {
    /// 放行。
    Pass,
    /// 吞掉。
    Swallow,
}

/// 按下一个键：修饰键放行；还没有结果时按规则得出结果并吞掉这个键。纯逻辑，单元测试用。
pub(crate) fn on_key_down(state: &mut State, vk: u32, modifiers: HotkeyModifiers) -> KeyAction {
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
pub(crate) fn on_key_up(state: &mut State, vk: u32) -> KeyAction {
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
        // 修饰键在加锁前读好，锁里只做纯逻辑。
        let modifiers = mouse_hook::current_modifiers();
        let action = if own_key {
            KeyAction::Pass
        } else {
            with_state(|state| {
                let down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                let action = match message {
                    WM_KEYDOWN | WM_SYSKEYDOWN => on_key_down(state, info.vkCode, modifiers),
                    WM_KEYUP | WM_SYSKEYUP => on_key_up(state, info.vkCode),
                    _ => KeyAction::Pass,
                };
                // 诊断：每个事件都记下，录制结束时由应用写进日志。
                state.note_key(Source::Hook, down, info.vkCode, modifiers, action);
                action
            })
            .unwrap_or(KeyAction::Pass)
        };
        if action == KeyAction::Swallow {
            // 按着 Win 时吞掉了按键：发一次未分配键，松开 Win 时不弹开始菜单。
            if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) && modifiers.contains(HotkeyModifiers::WIN)
            {
                activation::send_unassigned_key();
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
            let modifiers = mouse_hook::current_modifiers();
            let action = with_state(|state| {
                // 诊断：只数中键与侧键，移动与左右键不计。
                state.buttons_seen = state.buttons_seen.saturating_add(1);
                on_mouse(state, button, down, modifiers)
            })
            .unwrap_or(KeyAction::Pass);
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
