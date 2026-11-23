// SPDX-License-Identifier: GPL-3.0-or-later
//
// 注册窗口类的小工具。每个类只注册一次；类名在本进程内唯一即可。

//! 窗口类注册。

use std::collections::HashSet;
use std::sync::Mutex;

use windows::Win32::Foundation::HINSTANCE;
use windows::Win32::Graphics::Gdi::HBRUSH;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CS_HREDRAW, CS_VREDRAW, IDC_ARROW, LoadCursorW, RegisterClassExW, WNDCLASSEXW, WNDPROC,
};
use windows::core::{PCWSTR, Result};

use crate::text::wide;

/// 已注册的类名。
static REGISTERED: Mutex<Option<HashSet<String>>> = Mutex::new(None);

/// 本模块（exe）的实例句柄。
pub(crate) fn instance() -> Result<HINSTANCE> {
    // SAFETY: 传 None 取当前 exe 的模块句柄，不涉及指针参数。
    let module = unsafe { GetModuleHandleW(None)? };
    Ok(module.into())
}

/// 注册窗口类（已注册过时直接返回），返回类名的 UTF-16，调用方创建窗口时要用它。
pub(crate) fn ensure(name: &str, proc_: WNDPROC, background: HBRUSH) -> Result<Vec<u16>> {
    let class_name = wide(name);
    let mut guard = REGISTERED.lock().unwrap_or_else(|e| e.into_inner());
    let set = guard.get_or_insert_with(HashSet::new);
    if set.contains(name) {
        return Ok(class_name);
    }
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: proc_,
        hInstance: instance()?,
        // SAFETY: 加载系统预置的箭头光标，实例传 None。
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW)? },
        hbrBackground: background,
        lpszClassName: PCWSTR(class_name.as_ptr()),
        ..Default::default()
    };
    // SAFETY: class 里的字符串指针指向 class_name，它活到函数返回之后；RegisterClassExW 会复制类名。
    let atom = unsafe { RegisterClassExW(&class) };
    if atom == 0 {
        return Err(windows::core::Error::from_thread());
    }
    set.insert(name.to_owned());
    Ok(class_name)
}
