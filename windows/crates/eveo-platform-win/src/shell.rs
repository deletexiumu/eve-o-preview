// SPDX-License-Identifier: GPL-3.0-or-later
//
// 剪贴板与用默认浏览器打开链接，给浮窗右键菜单的「复制这一条」「在浏览器中打开」用
// （docs/macos/design-intel-translate.md 8.7 节，对应 macOS 的 NSPasteboard 与 NSWorkspace.open）。
// - copy_text：把文字以 CF_UNICODETEXT 放进剪贴板。内存块交给剪贴板后归系统所有，不能再释放；
//   交接失败时由这里释放。
// - open_url：只打开 https 地址（调用方已检查），交给 ShellExecuteW 的 open 动作，由系统选默认浏览器。
//   浏览器会到前台，这是用户点菜单的结果。
// 文字与地址不写进任何日志：复制的是聊天正文，地址里有人名。

//! 剪贴板与打开链接。

use std::ffi::c_void;

use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{PCWSTR, Result, w};

use crate::text::wide;

/// 剪贴板格式 CF_UNICODETEXT（UTF-16，以 0 结尾）。写成数字是为了不为一个常量引入整个 OLE 模块。
const CF_UNICODETEXT: u32 = 13;

/// 把文字放进剪贴板，替换原有内容。owner 是本线程的一个窗口，成为剪贴板的所有者。
pub fn copy_text(owner: HWND, text: &str) -> Result<()> {
    let units = wide(text);
    let bytes = units.len() * std::mem::size_of::<u16>();
    // SAFETY: owner 是本线程建的窗口；打开后无论成败都在下面关闭，不会让剪贴板一直被占着。
    unsafe { OpenClipboard(Some(owner))? };
    let result = put_unicode_text(&units, bytes);
    // SAFETY: 上面已成功打开剪贴板，这里配对关闭；关闭失败也没有别的补救办法，忽略。
    let _ = unsafe { CloseClipboard() };
    result
}

/// 在已打开的剪贴板里放一块 UTF-16 文字。
fn put_unicode_text(units: &[u16], bytes: usize) -> Result<()> {
    // SAFETY: 剪贴板已由调用方打开。
    unsafe { EmptyClipboard()? };
    // SAFETY: 申请一块可移动的全局内存，大小是文字（含结尾的 0）的字节数。
    let memory: HGLOBAL = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes)? };
    // SAFETY: memory 是刚申请的块；锁定后得到至少 bytes 字节的可写指针，复制完立即解锁。
    let pointer: *mut c_void = unsafe { GlobalLock(memory) };
    if pointer.is_null() {
        // SAFETY: 块还归我们所有，释放它。
        let _ = unsafe { GlobalFree(Some(memory)) };
        return Err(windows::core::Error::from_thread());
    }
    // SAFETY: pointer 指向至少 bytes 字节、与 u16 对齐的内存（全局内存块按 8 字节对齐），源与目标不重叠。
    unsafe {
        std::ptr::copy_nonoverlapping(units.as_ptr(), pointer.cast::<u16>(), units.len());
    }
    // SAFETY: 与上面的 GlobalLock 配对；解锁后计数为 0 时返回「错误」但错误码是成功，忽略结果。
    let _ = unsafe { GlobalUnlock(memory) };
    // SAFETY: 交给剪贴板；成功后块归系统所有，不能再释放。
    match unsafe { SetClipboardData(CF_UNICODETEXT, Some(HANDLE(memory.0))) } {
        Ok(_) => Ok(()),
        Err(error) => {
            // SAFETY: 交接失败，块仍归我们所有，释放它。
            let _ = unsafe { GlobalFree(Some(memory)) };
            Err(error)
        }
    }
}

/// 用默认浏览器打开一个地址。调用方只传 https 地址。成功时返回真。
pub fn open_url(url: &str) -> bool {
    let url = wide(url);
    // SAFETY: 动作与地址都是以 0 结尾的 UTF-16，调用期间保持有效；不传参数与工作目录。
    let instance = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(url.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    // ShellExecuteW 的返回值大于 32 表示成功（历史约定，值本身不是真正的句柄）。
    instance.0 as usize > 32
}
