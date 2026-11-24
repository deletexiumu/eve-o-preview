// SPDX-License-Identifier: GPL-3.0-or-later
//
// 开机启动的注册表读写（规则在 eveo_core::autostart，设计见 docs/windows/architecture.md 4.10 节）：
// - 读：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下的字符串值，以及
//   `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run` 下同名的二进制值
//   （任务管理器的启用与禁用标记）。
// - 写：打开时写 Run 下的值，并删掉 StartupApproved 下同名的值（用户在本应用里明确要开机启动，
//   等于在任务管理器里重新启用）；关闭时两处都删。
// 只碰 HKCU 下以本应用命名的值，不需要管理员权限，也不动别的启动项。
// 失败时返回系统错误码，调用方记日志并在设置页恢复开关的实际状态。

//! 开机启动。

use eveo_core::autostart::{self, AutostartState};
use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, WIN32_ERROR};
use windows::Win32::System::Registry::{
    HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_BINARY, RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW,
};
use windows::core::{HSTRING, PCWSTR};

use crate::system_info::registry_string;

/// 启动项所在的键。
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
/// 任务管理器记启用与禁用的键。
const APPROVED_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

/// 本构建用的值名：调试构建另用一个，测试时不改掉正式版的启动项。
pub fn value_name() -> &'static str {
    if cfg!(debug_assertions) {
        autostart::DEBUG_VALUE_NAME
    } else {
        autostart::VALUE_NAME
    }
}

/// Run 下登记的命令行；没有登记时为 None。
pub fn registered_command() -> Option<String> {
    registry_string(HKEY_CURRENT_USER, RUN_KEY, value_name())
}

/// 当前状态。
pub fn state() -> AutostartState {
    let approval = registry_binary(APPROVED_KEY, value_name());
    autostart::state(registered_command().as_deref(), approval.as_deref())
}

/// 打开开机启动：写 Run 下的值（带引号的 exe 路径加 `--background`），删掉任务管理器的禁用标记。
pub fn enable(exe: &str) -> Result<(), u32> {
    let command = autostart::command_line(exe);
    // REG_SZ 的数据是以 0 结尾的 UTF-16，长度按字节算（含结尾的 0）。
    let data: Vec<u16> = command.encode_utf16().chain(std::iter::once(0)).collect();
    let (key, name) = (HSTRING::from(RUN_KEY), HSTRING::from(value_name()));
    // SAFETY: 键名与值名是以 0 结尾的宽字符串；数据缓冲区在调用期间有效，字节数如实给出。
    let result = unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            REG_SZ.0,
            Some(data.as_ptr().cast()),
            u32::try_from(data.len() * 2).unwrap_or(u32::MAX),
        )
    };
    check(result)?;
    // 禁用标记删不掉（例如不存在）不影响结果：没有标记就等于启用。
    let _ = delete(APPROVED_KEY, value_name());
    Ok(())
}

/// 关闭开机启动：删掉 Run 下的值与任务管理器的标记。本来就没有时也算成功。
pub fn disable() -> Result<(), u32> {
    let _ = delete(APPROVED_KEY, value_name());
    delete(RUN_KEY, value_name())
}

/// 删一个值；不存在时算成功。
fn delete(key: &str, value: &str) -> Result<(), u32> {
    let (key, value) = (HSTRING::from(key), HSTRING::from(value));
    // SAFETY: 键名与值名是以 0 结尾的宽字符串。
    let result =
        unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), PCWSTR(value.as_ptr())) };
    if result == ERROR_FILE_NOT_FOUND {
        return Ok(());
    }
    check(result)
}

/// 系统错误码换成结果。
fn check(result: WIN32_ERROR) -> Result<(), u32> {
    if result.is_ok() { Ok(()) } else { Err(result.0) }
}

/// 读 HKCU 下的二进制值；不存在或类型不对时为 None。
fn registry_binary(key: &str, value: &str) -> Option<Vec<u8>> {
    let (key, value) = (HSTRING::from(key), HSTRING::from(value));
    let mut size = 0u32;
    // 第一次调用只取字节数。
    // SAFETY: 键名与值名是有效的宽字符串；输出缓冲区传空，函数只写 size。
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(value.as_ptr()),
            RRF_RT_REG_BINARY,
            None,
            None,
            Some(&mut size),
        )
    }
    .ok()
    .ok()?;
    let mut buffer = vec![0u8; size as usize];
    // SAFETY: 缓冲区的字节数如实给出；函数写入数据并把 size 更新为实际字节数。
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(value.as_ptr()),
            RRF_RT_REG_BINARY,
            None,
            Some(buffer.as_mut_ptr().cast()),
            Some(&mut size),
        )
    }
    .ok()
    .ok()?;
    buffer.truncate(size as usize);
    Some(buffer)
}
