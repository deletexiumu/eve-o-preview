// SPDX-License-Identifier: GPL-3.0-or-later
//
// 进程信息：映像名、是否以管理员权限运行、创建时间（架构文档 4.1 节）。
// 只用 PROCESS_QUERY_LIMITED_INFORMATION，这个权限对管理员权限的进程也能拿到。

//! 进程信息。

use std::path::Path;

use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
use windows::Win32::Security::{GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation};
use windows::Win32::System::Threading::{
    GetCurrentProcess, GetProcessTimes, OpenProcess, OpenProcessToken, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::core::PWSTR;

use crate::text::from_wide;

/// 一个进程的信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessInfo {
    /// 映像的完整路径。
    pub path: String,
    /// 映像的文件名，如 `exefile.exe`。
    pub image_name: String,
    /// 是否以管理员权限（提升后的令牌）运行；读不到令牌时为 `None`。
    pub elevated: Option<bool>,
    /// 创建时间（FILETIME 的 100 纳秒计数）。与 PID 一起区分被复用的句柄。
    pub created_at: Option<u64>,
}

/// 关闭句柄的守卫。
struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        // SAFETY: 句柄由 OpenProcess 或 OpenProcessToken 得到，只在这里关闭一次。
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

/// 读一个进程的信息；进程不存在或没有权限时返回 `None`。
pub fn process_info(pid: u32) -> Option<ProcessInfo> {
    // SAFETY: 只请求查询权限，失败时返回错误。
    let handle = OwnedHandle(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?);
    let path = image_path(handle.0)?;
    let image_name = Path::new(&path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    Some(ProcessInfo {
        path,
        image_name,
        elevated: token_elevated(handle.0),
        created_at: creation_time(handle.0),
    })
}

/// 本进程是否以管理员权限运行。
pub fn current_process_elevated() -> Option<bool> {
    // SAFETY: GetCurrentProcess 返回伪句柄，不需要关闭。
    token_elevated(unsafe { GetCurrentProcess() })
}

/// 映像的完整路径。
fn image_path(handle: HANDLE) -> Option<String> {
    let mut buffer = [0u16; 1024];
    let mut len = buffer.len() as u32;
    // SAFETY: buffer 在调用期间有效，len 如实给出容量，调用后是写入的长度。
    unsafe { QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut len) }
        .ok()?;
    Some(from_wide(&buffer, len as usize))
}

/// 令牌是否提升。
fn token_elevated(process: HANDLE) -> Option<bool> {
    let mut token = HANDLE::default();
    // SAFETY: token 是有效的输出位置；只请求查询权限。
    unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) }.ok()?;
    let token = OwnedHandle(token);
    let mut elevation = TOKEN_ELEVATION::default();
    let mut returned = 0u32;
    // SAFETY: 输出缓冲区是 elevation，大小如实给出。
    unsafe {
        GetTokenInformation(
            token.0,
            TokenElevation,
            Some((&raw mut elevation).cast()),
            size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        )
    }
    .ok()?;
    Some(elevation.TokenIsElevated != 0)
}

/// 进程的创建时间。
fn creation_time(handle: HANDLE) -> Option<u64> {
    let (mut created, mut exited, mut kernel, mut user) = (
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
    );
    // SAFETY: 四个输出位置都有效。
    unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) }.ok()?;
    Some((u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime))
}
