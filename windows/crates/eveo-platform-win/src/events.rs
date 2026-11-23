// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口事件与前台跟踪（架构文档 4.1 节、4.5 节）：SetWinEventHook 以进程外方式监听前台变化、窗口出现与销毁、
// 改名、最小化与还原、移动。进程外回调由系统投递到注册钩子的线程，在该线程的消息循环里执行，
// 所以回调只把事件放进本线程的队列，由主线程在合适的时候取走。事件可能丢，调用方仍要兜底轮询。

//! WinEvent 钩子与前台窗口。

use std::cell::RefCell;

use eveo_core::model::WindowId;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook, UnhookWinEvent};
use windows::Win32::UI::WindowsAndMessaging::{
    EVENT_OBJECT_DESTROY, EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_SHOW,
    EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MINIMIZEEND, EVENT_SYSTEM_MINIMIZESTART, GetForegroundWindow,
    GetWindowThreadProcessId, OBJID_WINDOW, WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS,
};

use crate::window_id;

/// 一个窗口事件。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowEvent {
    /// 前台窗口变了。
    Foreground(WindowId),
    /// 窗口出现。
    Shown(WindowId),
    /// 窗口销毁。
    Destroyed(WindowId),
    /// 标题变了。
    Renamed(WindowId),
    /// 开始最小化。
    Minimized(WindowId),
    /// 从最小化还原。
    Restored(WindowId),
    /// 位置或大小变了。
    Moved(WindowId),
}

thread_local! {
    /// 本线程收到、还没取走的事件。
    static QUEUE: RefCell<Vec<WindowEvent>> = const { RefCell::new(Vec::new()) };
}

/// 当前的前台窗口；没有前台窗口（例如锁屏、切换桌面期间）时返回 `None`。
pub fn foreground_window() -> Option<WindowId> {
    // SAFETY: 只读。
    let hwnd = unsafe { GetForegroundWindow() };
    (!hwnd.is_invalid()).then(|| window_id(hwnd))
}

/// 窗口所属进程的 PID；窗口已不存在时返回 `None`。
pub fn window_pid(id: WindowId) -> Option<u32> {
    let mut pid = 0u32;
    // SAFETY: pid 是有效的输出位置；窗口无效时返回 0。
    let thread = unsafe { GetWindowThreadProcessId(crate::hwnd(id), Some(&mut pid)) };
    (thread != 0 && pid != 0).then_some(pid)
}

/// 本地时间，格式 `yyyyMMdd-HHmmss`，用于损坏配置文件的隔离文件名。
pub fn local_timestamp() -> String {
    // SAFETY: 只读系统时钟。
    let t = unsafe { GetLocalTime() };
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

/// 一组 WinEvent 钩子。丢弃时全部摘掉。必须在有消息循环的线程上创建，事件在该线程上取。
pub struct WindowEventHooks {
    hooks: Vec<HWINEVENTHOOK>,
}

impl WindowEventHooks {
    /// 注册钩子：前台、最小化与还原、出现与销毁、移动与改名。只收别的进程的事件。
    pub fn install() -> Self {
        let ranges = [
            (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
            (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND),
            (EVENT_OBJECT_DESTROY, EVENT_OBJECT_SHOW),
            (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_NAMECHANGE),
        ];
        let hooks = ranges
            .into_iter()
            .map(|(min, max)| {
                // SAFETY: 回调是本模块的 extern "system" 函数；进程外钩子不注入 DLL，hmod 传 None。
                unsafe {
                    SetWinEventHook(
                        min,
                        max,
                        None,
                        Some(on_event),
                        0,
                        0,
                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                    )
                }
            })
            .filter(|h| !h.is_invalid())
            .collect();
        Self { hooks }
    }

    /// 是否全部注册成功。
    pub fn is_complete(&self) -> bool {
        self.hooks.len() == 4
    }

    /// 取走本线程收到的事件，按到达的顺序。
    pub fn drain(&self) -> Vec<WindowEvent> {
        QUEUE.with(|q| std::mem::take(&mut *q.borrow_mut()))
    }
}

impl Drop for WindowEventHooks {
    fn drop(&mut self) {
        for hook in &self.hooks {
            // SAFETY: 钩子由 install 注册，只在这里摘一次。
            unsafe {
                let _ = UnhookWinEvent(*hook);
            }
        }
    }
}

/// WinEvent 的回调：只要顶层窗口本身（OBJID_WINDOW、子 id 为 0）的事件。
unsafe extern "system" fn on_event(
    _hook: HWINEVENTHOOK,
    event: u32,
    hwnd: HWND,
    id_object: i32,
    id_child: i32,
    _thread: u32,
    _time: u32,
) {
    if hwnd.is_invalid() || id_object != OBJID_WINDOW.0 || id_child != 0 {
        return;
    }
    let id = window_id(hwnd);
    let parsed = match event {
        EVENT_SYSTEM_FOREGROUND => WindowEvent::Foreground(id),
        EVENT_OBJECT_SHOW => WindowEvent::Shown(id),
        EVENT_OBJECT_DESTROY => WindowEvent::Destroyed(id),
        EVENT_OBJECT_NAMECHANGE => WindowEvent::Renamed(id),
        EVENT_SYSTEM_MINIMIZESTART => WindowEvent::Minimized(id),
        EVENT_SYSTEM_MINIMIZEEND => WindowEvent::Restored(id),
        EVENT_OBJECT_LOCATIONCHANGE => WindowEvent::Moved(id),
        _ => return,
    };
    QUEUE.with(|q| q.borrow_mut().push(parsed));
}
