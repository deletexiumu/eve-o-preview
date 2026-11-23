// SPDX-License-Identifier: GPL-3.0-or-later
//
// 单实例（架构文档 4.10 节）：启动时建命名互斥量 `Local\EVE-O-Preview-<固定 GUID>`。
// 已存在时说明本会话里已有一个实例在运行：用 FindWindowW 按类名找到它的主消息窗口（`tray`），
// 发一条注册过的消息让它打开设置窗口，然后本实例退出。`Local\` 前缀让互斥量只在当前登录会话内可见，
// 同一台机器上不同用户各自运行互不影响。

//! 单实例检查。

use windows::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::{FindWindowW, PostMessageW, RegisterWindowMessageW};
use windows::core::PCWSTR;

use crate::text::wide;
use crate::tray::{ACTIVATE_MESSAGE_NAME, MAIN_WINDOW_CLASS};

/// 互斥量的名字。GUID 固定不变，换了会让新旧版本能同时运行。
pub const MUTEX_NAME: &str = "Local\\EVE-O-Preview-6F1B2C1E-5A7D-4C2B-9E3A-8D4F0B7C2A91";

/// 本实例持有的互斥量。丢弃（进程退出）时释放，下一个实例就能启动。
pub struct InstanceGuard {
    handle: HANDLE,
}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        // SAFETY: 句柄由 acquire 建立，只关闭一次。
        let _ = unsafe { CloseHandle(self.handle) };
    }
}

/// 尝试成为唯一的实例。成功时返回守卫，要一直持有到进程退出；已有实例在运行时返回 `None`。
/// 建互斥量本身失败（极少见）时按「是第一个实例」处理：返回 `None` 会让应用无法启动。
pub fn acquire() -> Option<InstanceGuard> {
    let name = wide(MUTEX_NAME);
    // SAFETY: 名字缓冲区在调用期间有效；不要求初始所有权，只用它的存在与否判断。
    let created = unsafe { CreateMutexW(None, false, PCWSTR(name.as_ptr())) };
    // SAFETY: 紧接在 CreateMutexW 之后读本线程的错误码。
    let already_exists = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    match created {
        Ok(handle) if already_exists => {
            // SAFETY: 句柄有效；我们不是第一个实例，不持有它。
            let _ = unsafe { CloseHandle(handle) };
            None
        }
        Ok(handle) => Some(InstanceGuard { handle }),
        Err(_) => Some(InstanceGuard {
            handle: HANDLE::default(),
        }),
    }
}

/// 通知已在运行的实例打开设置窗口。找不到它的主消息窗口（还在启动）时返回 `false`。
pub fn notify_primary() -> bool {
    let class = wide(MAIN_WINDOW_CLASS);
    let message = wide(ACTIVATE_MESSAGE_NAME);
    // SAFETY: 两个缓冲区在调用期间有效；只按类名找顶层窗口。
    unsafe {
        let Ok(hwnd) = FindWindowW(PCWSTR(class.as_ptr()), PCWSTR::null()) else {
            return false;
        };
        let id = RegisterWindowMessageW(PCWSTR(message.as_ptr()));
        PostMessageW(Some(hwnd), id, Default::default(), Default::default()).is_ok()
    }
}
