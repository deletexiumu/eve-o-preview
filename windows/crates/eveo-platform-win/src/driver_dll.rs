// SPDX-License-Identifier: GPL-3.0-or-later
//
// 加载显卡驱动随附的 DLL（amdadlx64.dll、ControlLib.dll）并取导出函数，AMD 与 Intel 两个模块共用。
// 只在 System32 里找，避免加载到当前目录里同名的 DLL。加载后不卸载：这些调用都在短命的子进程里，进程结束时一起释放。

//! 显卡驱动 DLL 的加载。

use std::ffi::c_void;

use windows::Win32::Foundation::HMODULE;
use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
use windows::core::{PCSTR, PCWSTR};

/// 从 System32 加载 DLL；没有时为 `None`。
pub(crate) fn load(name: PCWSTR) -> Option<HMODULE> {
    // SAFETY: name 是常量字符串；只在 System32 里找，避免加载到当前目录里同名的 DLL。
    unsafe { LoadLibraryExW(name, None, LOAD_LIBRARY_SEARCH_SYSTEM32) }.ok()
}

/// 取导出函数；没有时为 `None`。
///
/// # Safety
/// `F` 必须是这个导出函数的函数指针类型。
pub(crate) unsafe fn export<F: Copy>(module: HMODULE, name: PCSTR) -> Option<F> {
    const { assert!(size_of::<F>() == size_of::<*const c_void>()) };
    // SAFETY: module 是已加载的模块，name 是常量字符串。
    let address = unsafe { GetProcAddress(module, name) }?;
    // SAFETY: 同大小的函数指针，调用方保证签名相符。
    Some(unsafe { std::mem::transmute_copy(&address) })
}
