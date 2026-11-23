// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针与测试用的消息泵：在给定时长内取出并分发本线程的消息，把每条消息交给回调看一眼。
// 正式的应用由 Slint（winit）的事件循环分发消息，不用这里（架构文档 3.2 节）。

//! 限时的消息泵。

use std::time::{Duration, Instant};

use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, MsgWaitForMultipleObjects, PM_REMOVE, PeekMessageW, QS_ALLINPUT, TranslateMessage,
};

/// 分发本线程的消息，直到超时或回调返回 true；返回回调是否返回过 true。
///
/// 回调在分发之前看到每条消息（包括发给线程而不是窗口的消息，如 `WM_HOTKEY` 绑定到消息窗口时也会经过这里）。
pub fn pump_until(timeout: Duration, mut stop: impl FnMut(&MSG) -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        let mut msg = MSG::default();
        // SAFETY: msg 是有效的输出缓冲区；hwnd 传 None 表示取本线程的全部消息。
        while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
            if stop(&msg) {
                return true;
            }
            // SAFETY: msg 刚由 PeekMessageW 填好。
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        let wait = (deadline - now).as_millis().min(50) as u32;
        // SAFETY: 不传任何句柄，只等本线程的新消息或超时。
        unsafe {
            MsgWaitForMultipleObjects(None, false, wait, QS_ALLINPUT);
        }
    }
}

/// 分发本线程的消息一段时间。
pub fn pump_for(duration: Duration) {
    pump_until(duration, |_| false);
}
