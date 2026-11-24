// SPDX-License-Identifier: GPL-3.0-or-later
//
// 未处理的结构化异常与快速退出（架构文档 4.10 节「诊断」的一部分）：
// - 真机测试发现：应用自己的收尾只用几十毫秒，但随后在进程拆除阶段（线程局部变量的析构、DLL 卸载）
//   KERNELBASE 抛出异常码 0x87A 的未处理异常，等 WER 收集完才放进程走，托盘「退出」因此要 5～10 秒。
//   这类异常不是 Rust 的 panic，panic 钩子看不到，所以另装一个顶层异常过滤器：记下异常码、
//   出事的模块名（只要文件名，不要路径）与模块内偏移，再交还给系统（照常进 WER）。
// - 退出时配置、state.json、人名缓存与日志都已写完，`terminate_now` 用 TerminateProcess 直接结束进程，
//   跳过进程拆除阶段，那里已经没有需要做的事了。内核照常关闭句柄（单实例的互斥量随之消失）。
// 过滤器里不分配大块内存、不等锁：回调由调用方提供，应只做不阻塞的记录。

//! 未处理异常的记录与快速退出。

use std::sync::OnceLock;

use windows::Win32::Foundation::HMODULE;
use windows::Win32::System::Diagnostics::Debug::{EXCEPTION_POINTERS, SetUnhandledExceptionFilter};
use windows::Win32::System::LibraryLoader::{
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, GetModuleFileNameW,
    GetModuleHandleExW,
};
use windows::Win32::System::Threading::{GetCurrentProcess, TerminateProcess};
use windows::core::PCWSTR;

/// 一次未处理异常的概要。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrashInfo {
    /// 异常码，如 0xC0000005（访问违例）。
    pub code: u32,
    /// 出事的模块的文件名（不含路径）；找不到时为空。
    pub module: String,
    /// 异常地址在模块里的偏移；找不到模块时是地址本身。
    pub offset: usize,
}

/// 记录未处理异常的回调。
pub type CrashReporter = fn(&CrashInfo);

/// 装上的回调。
static REPORTER: OnceLock<CrashReporter> = OnceLock::new();

/// 装上顶层异常过滤器：未处理的结构化异常先交给 reporter，再交还系统。只有第一次调用生效。
pub fn install_crash_filter(reporter: CrashReporter) {
    if REPORTER.set(reporter).is_err() {
        return;
    }
    // SAFETY: 过滤器是 'static 的函数，在任何线程上被调用都只读传入的异常信息。
    unsafe {
        SetUnhandledExceptionFilter(Some(filter));
    }
}

/// 顶层异常过滤器。返回 0（EXCEPTION_CONTINUE_SEARCH），让系统照常处理（WER）。
unsafe extern "system" fn filter(pointers: *const EXCEPTION_POINTERS) -> i32 {
    // SAFETY: 系统传入的指针在过滤器运行期间有效；空指针时什么也不读。
    let record = unsafe { pointers.as_ref().and_then(|p| p.ExceptionRecord.as_ref()) };
    if let (Some(record), Some(reporter)) = (record, REPORTER.get()) {
        let address = record.ExceptionAddress as usize;
        let (module, base) = module_of(address);
        reporter(&CrashInfo {
            // NTSTATUS 是 i32，异常码按无符号的十六进制写。
            code: record.ExceptionCode.0.cast_unsigned(),
            module,
            offset: address.wrapping_sub(base),
        });
    }
    0
}

/// 地址所在模块的文件名与基址；找不到时是（空串，0）。
fn module_of(address: usize) -> (String, usize) {
    let mut module = HMODULE::default();
    let flags = GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
    // SAFETY: FROM_ADDRESS 时第二个参数按地址解释，不会被当成字符串读；不增加引用计数，不需要释放。
    if unsafe { GetModuleHandleExW(flags, PCWSTR(address as *const u16), &mut module) }.is_err() {
        return (String::new(), 0);
    }
    let mut buffer = [0u16; 260];
    // SAFETY: 缓冲区在调用期间有效，长度如实给出。
    let length = unsafe { GetModuleFileNameW(Some(module), &mut buffer) } as usize;
    let path = String::from_utf16_lossy(&buffer[..length.min(buffer.len())]);
    // 只留文件名：路径里可能有 Windows 用户名。
    let name = path.rsplit(['\\', '/']).next().unwrap_or_default().to_owned();
    (name, module.0 as usize)
}

/// 立即结束本进程，不进入进程拆除阶段（不跑线程局部变量的析构、不调 DLL 的卸载通知）。
/// 只在应用自己的收尾都做完之后调用。
pub fn terminate_now(code: u32) -> ! {
    // SAFETY: 伪句柄 GetCurrentProcess 总是有效；成功时不返回。
    let _ = unsafe { TerminateProcess(GetCurrentProcess(), code) };
    // TerminateProcess 失败（几乎不会）时退回到普通的退出。
    std::process::exit(code.cast_signed())
}
