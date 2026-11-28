// SPDX-License-Identifier: GPL-3.0-or-later
//
// 进程信息：映像名、是否以管理员权限运行、创建时间（架构文档 4.1 节）。
// 只用 PROCESS_QUERY_LIMITED_INFORMATION，这个权限对管理员权限的进程也能拿到。

//! 进程信息。

use std::path::Path;

use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
use windows::Win32::Security::{GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
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

/// 枚举当前系统的进程列表，检查是否存在指定映像名（不区分大小写）的进程。
///
/// 使用 ToolHelp 进程快照，无需打开目标进程句柄，管理员权限运行的客户端或尚未创建主窗口的启动中进程都能识别。
/// 空名单直接返回 `false`；若快照创建或首条枚举失败，说明系统调用受阻，保守返回 `true`（视作客户端可能正在运行，
/// 避免在未知状态下误触发静默更新重启，打断正在运行的 EVE 客户端）。
pub fn any_process_running(image_names: &[String]) -> bool {
    if image_names.is_empty() {
        return false;
    }
    // SAFETY: TH32CS_SNAPPROCESS 无需指定进程 ID，返回句柄由 OwnedHandle 负责关闭。
    let Ok(snapshot) = (unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }) else {
        return true;
    };
    let snapshot = OwnedHandle(snapshot);
    let mut entry = PROCESSENTRY32W {
        dwSize: size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    // SAFETY: entry.dwSize 已正确填写，snapshot 为有效的进程快照句柄。
    // 存活系统里快照至少包含本进程自身，Process32FirstW 失败说明枚举受阻，按保守策略返回 true 避免误重启。
    if unsafe { Process32FirstW(snapshot.0, &mut entry) }.is_err() {
        return true;
    }
    loop {
        // szExeFile 是以 NUL 结尾的固定长 UTF-16 缓冲区，只截到首个 NUL 之前。
        let len = entry
            .szExeFile
            .iter()
            .position(|&unit| unit == 0)
            .unwrap_or(entry.szExeFile.len());
        let name = from_wide(&entry.szExeFile, len);
        if image_names.iter().any(|target| name.eq_ignore_ascii_case(target)) {
            return true;
        }
        // SAFETY: entry 与 snapshot 均有效，继续枚举下一项直到失败（ERROR_NO_MORE_FILES）。
        if unsafe { Process32NextW(snapshot.0, &mut entry) }.is_err() {
            return false;
        }
    }
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
