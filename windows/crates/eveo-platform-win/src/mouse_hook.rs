// SPDX-License-Identifier: GPL-3.0-or-later
//
// 鼠标中键与侧键热键（架构文档 3.3 节、4.4 节）：WH_MOUSE_LL 装在专用线程，该线程只跑自己的消息循环。
// 低级鼠标钩子的回调在安装它的线程上、由该线程的消息循环调用，回调要在系统规定的时限内返回，
// 否则钩子会被系统悄悄摘掉。所以回调里只做三件事：读修饰键、查 Core 的 MouseHotkeyMatcher（锁保护）、
// 命中时 PostMessageW 到主线程的窗口。是否吞掉由匹配器决定，规则与 macOS 共用 shared/fixtures/hotkey 的用例。
// 每 30 秒重装一次（先装新的再摘旧的，中间不漏事件），对付被系统摘掉的情况。
// 匹配器由主线程（协调器）持有同一个 Arc，绑定表、前台、暂停与松开的截止时刻都在主线程更新。

//! 低级鼠标钩子线程。

use std::cell::RefCell;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use eveo_core::hotkeys::backend::mouse_hook_refresh;
use eveo_core::hotkeys::{HotkeyModifiers, MouseButtonEventKind, MouseHotkeyDecision, MouseHotkeyMatcher};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VIRTUAL_KEY, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetMessageW, HC_ACTION, HHOOK, KillTimer, MSG, MSLLHOOKSTRUCT, PM_NOREMOVE, PeekMessageW,
    PostMessageW, PostThreadMessageW, SetTimer, SetWindowsHookExW, UnhookWindowsHookEx, WH_MOUSE_LL, WM_APP,
    WM_MBUTTONDOWN, WM_MBUTTONUP, WM_QUIT, WM_TIMER, WM_XBUTTONDOWN, WM_XBUTTONUP, XBUTTON1, XBUTTON2,
};

use crate::window_class;

/// 鼠标热键触发时投递给主线程窗口的消息；wParam 是绑定编号。
pub const WM_MOUSE_HOTKEY: u32 = WM_APP + 0x31;

/// 让钩子线程立刻重装钩子的线程消息。
const WM_REINSTALL: u32 = WM_APP + 0x32;

/// 共享的匹配器。主线程更新绑定表与状态，钩子线程在回调里判断事件。
pub type SharedMatcher = Arc<Mutex<MouseHotkeyMatcher>>;

/// 钩子线程的状态：只在钩子线程上读写。
struct HookContext {
    matcher: SharedMatcher,
    /// 主线程上接收 `WM_MOUSE_HOTKEY` 的窗口（句柄的数值，句柄本身不能跨线程传）。
    notify: usize,
    hook: Option<HHOOK>,
}

thread_local! {
    /// 钩子线程的状态。回调没有上下文参数，只能放在线程局部变量里。
    static CONTEXT: RefCell<Option<HookContext>> = const { RefCell::new(None) };
}

/// 运行中的低级鼠标钩子。丢弃时停止线程、摘掉钩子，并告诉匹配器钩子已拆除。
pub struct MouseHook {
    thread_id: u32,
    join: Option<JoinHandle<()>>,
    matcher: SharedMatcher,
    installs: Arc<AtomicU32>,
}

impl MouseHook {
    /// 启动钩子线程并装上钩子。触发的绑定编号以 `WM_MOUSE_HOTKEY` 投递到 `notify`（应属于主线程）。
    ///
    /// 只应在 `matcher.should_listen()` 为真时启动：没有鼠标绑定时不装钩子，线程也不启动。
    pub fn start(matcher: SharedMatcher, notify: HWND) -> Result<Self, String> {
        let installs = Arc::new(AtomicU32::new(0));
        let (ready_tx, ready_rx) = mpsc::channel::<Result<u32, String>>();
        let thread_matcher = Arc::clone(&matcher);
        let thread_installs = Arc::clone(&installs);
        let notify = notify.0 as usize;
        let join = std::thread::Builder::new()
            .name("eveo-mouse-hook".into())
            .spawn(move || run(thread_matcher, notify, thread_installs, ready_tx))
            .map_err(|e| format!("启动钩子线程失败：{e}"))?;
        match ready_rx.recv() {
            Ok(Ok(thread_id)) => Ok(Self {
                thread_id,
                join: Some(join),
                matcher,
                installs,
            }),
            Ok(Err(message)) => {
                let _ = join.join();
                Err(message)
            }
            Err(_) => {
                let _ = join.join();
                Err("钩子线程意外退出".into())
            }
        }
    }

    /// 共享的匹配器。
    pub fn matcher(&self) -> &SharedMatcher {
        &self.matcher
    }

    /// 钩子已安装的次数：启动算一次，每次重装加一。
    pub fn install_count(&self) -> u32 {
        self.installs.load(Ordering::Relaxed)
    }

    /// 让钩子线程立刻重装一次钩子（先装新的再摘旧的）。
    pub fn reinstall(&self) {
        // SAFETY: 线程编号来自钩子线程自己，消息队列在报告就绪前已建立。
        let _ = unsafe { PostThreadMessageW(self.thread_id, WM_REINSTALL, WPARAM(0), LPARAM(0)) };
    }

    /// 一条消息是不是鼠标热键触发；是时返回绑定编号。
    pub fn fired_binding(msg: &MSG) -> Option<u32> {
        (msg.message == WM_MOUSE_HOTKEY).then_some(msg.wParam.0 as u32)
    }
}

impl Drop for MouseHook {
    fn drop(&mut self) {
        // SAFETY: 同 reinstall。线程收到 WM_QUIT 后摘掉钩子并退出。
        let _ = unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) };
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        self.matcher
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .hook_was_removed();
    }
}

/// 钩子线程：建消息队列、装钩子、报告就绪，然后跑消息循环直到 WM_QUIT。
fn run(
    matcher: SharedMatcher,
    notify: usize,
    installs: Arc<AtomicU32>,
    ready: mpsc::Sender<Result<u32, String>>,
) {
    let mut msg = MSG::default();
    // SAFETY: msg 是本函数的局部变量；PM_NOREMOVE 只为让系统给本线程建消息队列。
    let _ = unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE) };
    CONTEXT.with(|c| {
        *c.borrow_mut() = Some(HookContext {
            matcher,
            notify,
            hook: None,
        })
    });
    if let Err(message) = install() {
        let _ = ready.send(Err(message));
        return;
    }
    installs.fetch_add(1, Ordering::Relaxed);
    let interval_ms = (mouse_hook_refresh::INTERVAL * 1000.0) as u32;
    // SAFETY: 不绑窗口的线程定时器，WM_TIMER 投递到本线程的队列。
    let timer = unsafe { SetTimer(None, 0, interval_ms, None) };
    // SAFETY: 只读当前线程的编号。
    let _ = ready.send(Ok(unsafe { GetCurrentThreadId() }));
    loop {
        // SAFETY: msg 是局部变量；GetMessageW 在 WM_QUIT 时返回 0，出错时返回 -1。
        let result = unsafe { GetMessageW(&mut msg, None, 0, 0) };
        if result.0 <= 0 {
            break;
        }
        if msg.message == WM_TIMER || msg.message == WM_REINSTALL {
            // 装不上新的时保留旧的，下次再试。
            if install().is_ok() {
                installs.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    if timer != 0 {
        // SAFETY: 定时器由本线程创建。
        let _ = unsafe { KillTimer(None, timer) };
    }
    CONTEXT.with(|c| {
        if let Some(hook) = c.borrow_mut().take().and_then(|context| context.hook) {
            // SAFETY: 钩子由本线程安装，只摘一次。
            let _ = unsafe { UnhookWindowsHookEx(hook) };
        }
    });
}

/// 装一个新钩子，成功后摘掉旧的。先装后摘，中间不漏事件。
fn install() -> Result<(), String> {
    let module = window_class::instance().map_err(|e| e.message())?;
    // SAFETY: 回调是本模块的 extern "system" 函数；低级钩子不注入别的进程，模块句柄取本 exe 的。
    let hook = unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(hook_proc), Some(module), 0) }
        .map_err(|e| format!("安装低级鼠标钩子失败：{}", e.message()))?;
    let old = CONTEXT.with(|c| {
        c.borrow_mut()
            .as_mut()
            .and_then(|context| context.hook.replace(hook))
    });
    if let Some(old) = old {
        // SAFETY: 旧钩子由本线程安装，已被新钩子取代，只摘一次。
        let _ = unsafe { UnhookWindowsHookEx(old) };
    }
    Ok(())
}

/// 低级鼠标钩子的回调。只处理中键与侧键的按下与松开，其余原样交给下一个钩子。
unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        // SAFETY: HC_ACTION 时 lparam 指向系统提供的 MSLLHOOKSTRUCT，在回调期间有效。
        let info = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
        if let Some((kind, button)) = classify(wparam.0 as u32, info.mouseData) {
            let swallow = CONTEXT.with(|c| match c.borrow().as_ref() {
                Some(context) => decide(context, kind, button),
                None => false,
            });
            if swallow {
                return LRESULT(1);
            }
        }
    }
    // SAFETY: 参数原样转交；低级钩子的第一个参数被忽略。
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// 鼠标消息 → 事件种类与按钮号（与 `Hotkey` 相同：2 是中键，3、4 是两个侧键）。
fn classify(message: u32, mouse_data: u32) -> Option<(MouseButtonEventKind, u8)> {
    let x_button = || match (mouse_data >> 16) as u16 {
        XBUTTON1 => Some(3),
        XBUTTON2 => Some(4),
        _ => None,
    };
    match message {
        WM_MBUTTONDOWN => Some((MouseButtonEventKind::Down, 2)),
        WM_MBUTTONUP => Some((MouseButtonEventKind::Up, 2)),
        WM_XBUTTONDOWN => x_button().map(|b| (MouseButtonEventKind::Down, b)),
        WM_XBUTTONUP => x_button().map(|b| (MouseButtonEventKind::Up, b)),
        _ => None,
    }
}

/// 交给匹配器判断；触发时通知主线程。返回是否吞掉。
fn decide(context: &HookContext, kind: MouseButtonEventKind, button: u8) -> bool {
    let decision =
        context
            .matcher
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .handle(kind, button, current_modifiers());
    match decision {
        MouseHotkeyDecision::Pass => false,
        MouseHotkeyDecision::Swallow => true,
        MouseHotkeyDecision::Fire(id) => {
            let notify = HWND(context.notify as *mut core::ffi::c_void);
            // SAFETY: 句柄属于主线程的窗口；投递失败（窗口已销毁）时这次触发作废，事件照样吞掉。
            let _ = unsafe { PostMessageW(Some(notify), WM_MOUSE_HOTKEY, WPARAM(id as usize), LPARAM(0)) };
            true
        }
    }
}

/// 此刻按着的修饰键。
fn current_modifiers() -> HotkeyModifiers {
    // SAFETY: 只读按键状态；最高位为 1 表示按着。
    let down = |key: VIRTUAL_KEY| unsafe { GetAsyncKeyState(i32::from(key.0)) } < 0;
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
