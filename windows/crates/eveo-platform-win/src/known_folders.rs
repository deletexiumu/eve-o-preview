// SPDX-License-Identifier: GPL-3.0-or-later
//
// 系统的已知文件夹（SHGetKnownFolderPath）。EVE 把日志写在「文档\EVE\logs」，而「文档」可能被移到别的盘，
// 或被 OneDrive 接管（%USERPROFILE%\OneDrive\Documents），拼 %USERPROFILE%\Documents 会找错地方。

//! 已知文件夹的位置。

use std::path::PathBuf;

use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::UI::Shell::{FOLDERID_Documents, KF_FLAG_DEFAULT, SHGetKnownFolderPath};

/// 当前用户「文档」文件夹的实际位置；取不到时返回 `None`。
pub fn documents() -> Option<PathBuf> {
    // SAFETY: FOLDERID_Documents 是静态的 GUID，令牌传空表示当前用户；成功时返回的字符串由系统分配，
    // 读完后用 CoTaskMemFree 释放，且只释放这一次。
    unsafe {
        let raw = SHGetKnownFolderPath(&FOLDERID_Documents, KF_FLAG_DEFAULT, Some(HANDLE::default())).ok()?;
        let path = raw.to_string().ok();
        CoTaskMemFree(Some(raw.0 as *const _));
        path.map(PathBuf::from)
    }
}
