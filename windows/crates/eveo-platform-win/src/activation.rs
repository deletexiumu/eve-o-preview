// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口激活（架构文档 4.3 节）。系统只允许满足条件的进程把别的窗口设为前台，否则 SetForegroundWindow
// 只会让任务栏按钮闪烁。这里按升级步骤逐步尝试，每步之后核对前台窗口，并报告走到了第几步。
// 全部调用都不等待对方进程：还原用 ShowWindowAsync，前台窗口卡死时跳过挂接输入队列。

//! 把客户端窗口切到前台。

use std::time::Duration;

use eveo_core::model::WindowId;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT, KEYEVENTF_KEYUP, SendInput, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsHungAppWindow, IsIconic,
    IsWindowVisible, SW_MINIMIZE, SW_RESTORE, SetForegroundWindow, ShowWindowAsync,
};

use crate::hwnd;
use crate::message_loop::pump_for;

/// 激活走到的步骤。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivationStep {
    /// 目标本来就在前台。
    AlreadyForeground,
    /// 第 2 步：直接 SetForegroundWindow 成功。
    Direct,
    /// 第 3 步：先发一次无效果的按键，再 SetForegroundWindow 成功。
    AfterSyntheticInput,
    /// 第 4 步：挂接前台线程的输入队列后成功。
    AttachedInput,
    /// 都失败了。
    Failed,
}

/// 一次激活的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActivationOutcome {
    /// 走到的步骤。
    pub step: ActivationStep,
    /// 是否先还原了最小化的窗口。
    pub restored: bool,
}

impl ActivationOutcome {
    /// 是否成功。
    pub fn succeeded(&self) -> bool {
        self.step != ActivationStep::Failed
    }
}

/// 未分配的虚拟键码，用于第 3 步：按下并抬起它不会对任何应用产生效果。不用 Alt，Alt 会让游戏进入菜单状态。
pub(crate) const UNASSIGNED_VK: u16 = 0xE8;

/// 每步之后等前台切换生效的时间。SetForegroundWindow 通常同步生效，留一点余量给系统处理。
const SETTLE: Duration = Duration::from_millis(30);

/// 把窗口切到前台，按 4.3 节的步骤升级。
pub fn activate(target: WindowId) -> ActivationOutcome {
    let window = hwnd(target);
    let mut restored = false;
    // SAFETY: 只读窗口状态。
    if unsafe { IsIconic(window) }.as_bool() {
        // SAFETY: 异步还原，不等待对方进程。
        let _ = unsafe { ShowWindowAsync(window, SW_RESTORE) };
        restored = true;
    }
    if is_foreground(window) && !restored {
        return ActivationOutcome {
            step: ActivationStep::AlreadyForeground,
            restored,
        };
    }
    let steps: [(ActivationStep, fn(HWND)); 3] = [
        (ActivationStep::Direct, set_foreground),
        (ActivationStep::AfterSyntheticInput, |w| {
            send_unassigned_key();
            set_foreground(w);
        }),
        (ActivationStep::AttachedInput, attach_and_set_foreground),
    ];
    for (step, run) in steps {
        run(window);
        pump_for(SETTLE);
        if is_foreground(window) {
            return ActivationOutcome { step, restored };
        }
    }
    ActivationOutcome {
        step: ActivationStep::Failed,
        restored,
    }
}

/// 把本进程自己的窗口切到前台，不分发消息：只做还原、直接设前台与挂接输入队列，不等待。
/// 返回之后是否在前台。
///
/// 给在 Slint（winit）事件回调里调用的场合用，例如定时器。[`activate`] 每步之后要分发消息等切换生效，
/// 在 winit 的回调里分发消息是重入：winit 只把事件攒着，新窗口的第一帧画不出来，关闭也没有反应。
pub fn bring_forward(target: WindowId) -> bool {
    let window = hwnd(target);
    // SAFETY: 只读窗口状态。
    if unsafe { IsIconic(window) }.as_bool() {
        // SAFETY: 异步还原，不等待。
        let _ = unsafe { ShowWindowAsync(window, SW_RESTORE) };
    } else if is_foreground(window) {
        return true;
    }
    set_foreground(window);
    if is_foreground(window) {
        return true;
    }
    // 直接设前台被系统拒绝：挂接前台线程的输入队列再试。这一步同步生效，不需要等。
    attach_and_set_foreground(window);
    is_foreground(window)
}

/// 窗口是否已经显示（IsWindowVisible；最小化的窗口也算显示）。句柄失效时返回假。
pub fn is_visible(target: WindowId) -> bool {
    // SAFETY: 只读窗口状态。
    unsafe { IsWindowVisible(hwnd(target)) }.as_bool()
}

/// 最小化窗口，不等待对方进程。
pub fn minimize(target: WindowId) {
    // SAFETY: 异步最小化。
    let _ = unsafe { ShowWindowAsync(hwnd(target), SW_MINIMIZE) };
}

/// 窗口是否在前台。
fn is_foreground(window: HWND) -> bool {
    // SAFETY: 只读。
    let foreground = unsafe { GetForegroundWindow() };
    foreground == window
}

/// 调一次 SetForegroundWindow。
fn set_foreground(window: HWND) {
    // SAFETY: 句柄失效时调用只是失败。
    let _ = unsafe { SetForegroundWindow(window) };
}

/// 发一次未分配键的按下与抬起，让系统认为本进程刚收到输入。
pub(crate) fn send_unassigned_key() {
    send_key_tap(VIRTUAL_KEY(UNASSIGNED_VK));
}

/// 合成一次按键（按下与抬起），送给当前的前台窗口。
pub(crate) fn send_key_tap(vk: VIRTUAL_KEY) {
    let key = |flags: KEYBD_EVENT_FLAGS| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                dwFlags: flags,
                ..Default::default()
            },
        },
    };
    let inputs = [key(KEYBD_EVENT_FLAGS(0)), key(KEYEVENTF_KEYUP)];
    // SAFETY: inputs 在调用期间有效，结构大小如实给出。
    unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
}

/// 第 4 步：把本线程挂到前台窗口的线程上，置顶并设前台，再解除。前台窗口卡死时跳过。
fn attach_and_set_foreground(window: HWND) {
    // SAFETY: 只读。
    let foreground = unsafe { GetForegroundWindow() };
    // SAFETY: 只读；对卡死的窗口挂接输入队列会把我们也拖住。
    if foreground.is_invalid() || unsafe { IsHungAppWindow(foreground) }.as_bool() {
        return;
    }
    // SAFETY: 只读。
    let foreground_thread = unsafe { GetWindowThreadProcessId(foreground, None) };
    // SAFETY: 只读。
    let current_thread = unsafe { GetCurrentThreadId() };
    if foreground_thread == 0 || foreground_thread == current_thread {
        set_foreground(window);
        return;
    }
    // SAFETY: 挂接与解除成对出现，中间的调用都不阻塞。
    unsafe {
        let attached = AttachThreadInput(current_thread, foreground_thread, true).as_bool();
        let _ = BringWindowToTop(window);
        let _ = SetForegroundWindow(window);
        if attached {
            let _ = AttachThreadInput(current_thread, foreground_thread, false);
        }
    }
}
