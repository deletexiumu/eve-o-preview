// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告要的系统信息与本机名字，对应 macOS 的 SystemInfoReader.swift 与 SystemDiagnosticsService 的
// sensitiveNames（v1.1 设计 7.2、7.3 节）：
// - 系统版本：注册表 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion 的 ProductName、DisplayVersion、
//   CurrentBuildNumber 与 UBR。Windows 11 的 ProductName 仍写「Windows 10 …」，构建号 22000 起改成 11。
// - 处理器：HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 的 ProcessorNameString。
// - 内存 GlobalMemoryStatusEx；逻辑处理器个数取标准库的 available_parallelism。
// - 是否经仿真：IsWow64Process2 给出本机架构；x86_64 的进程跑在 ARM64 上就是仿真。
// - 区域与语言：GetUserDefaultLocaleName 与 GetUserPreferredUILanguages。
// - 显卡：DXGI 适配器的描述，跳过软件渲染器（Microsoft Basic Render Driver）与重复的名字。
// - 本机名字：用户名（环境变量 USERNAME）、用户目录（USERPROFILE）与计算机名的三种写法
//   （NetBIOS 名、DNS 主机名、带域的全名）。只交给脱敏器当词表，不写进报告。
// 读不到的项是空串或空表，报告照样生成。

//! 系统信息与本机名字。

use eveo_core::diagnostics::redactor::RedactionTerms;
use eveo_core::diagnostics::summary::SystemInfo;
use windows::Win32::Globalization::GetUserDefaultLocaleName;
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE, IDXGIFactory1};
use windows::Win32::System::Registry::{
    HKEY, HKEY_LOCAL_MACHINE, RRF_RT_REG_DWORD, RRF_RT_REG_SZ, RegGetValueW,
};
use windows::Win32::System::SystemInformation::{
    COMPUTER_NAME_FORMAT, ComputerNameDnsFullyQualified, ComputerNameDnsHostname,
    ComputerNamePhysicalNetBIOS, GetComputerNameExW, GlobalMemoryStatusEx, IMAGE_FILE_MACHINE,
    IMAGE_FILE_MACHINE_ARM64, MEMORYSTATUSEX,
};
use windows::Win32::System::Threading::{GetCurrentProcess, IsWow64Process2};
use windows::core::{HSTRING, PCWSTR, PWSTR};

use crate::appearance::preferred_ui_languages;

/// Windows NT 版本信息所在的注册表键。
const VERSION_KEY: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
/// 第一个处理器的信息所在的注册表键。
const CPU_KEY: &str = r"HARDWARE\DESCRIPTION\System\CentralProcessor\0";
/// Windows 11 的第一个构建号。
const WINDOWS_11_BUILD: u32 = 22_000;

/// 读系统信息。
pub fn system_info() -> SystemInfo {
    // 构建号决定 Windows 10 与 11 的区分；UBR 是累积更新的修订号，排查时很有用。
    let build: u32 = registry_string(HKEY_LOCAL_MACHINE, VERSION_KEY, "CurrentBuildNumber")
        .and_then(|text| text.trim().parse().ok())
        .unwrap_or(0);
    let os_build = match registry_dword(HKEY_LOCAL_MACHINE, VERSION_KEY, "UBR") {
        Some(revision) => format!("{build}.{revision}"),
        None => build.to_string(),
    };
    let product = registry_string(HKEY_LOCAL_MACHINE, VERSION_KEY, "ProductName").unwrap_or_default();
    SystemInfo {
        os_name: product_name(&product, build),
        os_display_version: registry_string(HKEY_LOCAL_MACHINE, VERSION_KEY, "DisplayVersion")
            .unwrap_or_default(),
        os_build,
        architecture: std::env::consts::ARCH.to_owned(),
        emulated: emulated_on_arm64(),
        cpu_brand: registry_string(HKEY_LOCAL_MACHINE, CPU_KEY, "ProcessorNameString")
            .map(|text| text.trim().to_owned())
            .unwrap_or_default(),
        physical_memory_bytes: physical_memory(),
        processor_count: std::thread::available_parallelism().map_or(0, usize::from),
        locale: locale_name(),
        preferred_languages: preferred_ui_languages(),
        gpus: gpu_names(),
    }
}

/// 产品名：构建号表明是 Windows 11 而注册表写的是 Windows 10 时改正；读不到时写 `Windows`。
fn product_name(product: &str, build: u32) -> String {
    let product = product.trim();
    if product.is_empty() {
        return "Windows".to_owned();
    }
    if build >= WINDOWS_11_BUILD {
        return product.replacen("Windows 10", "Windows 11", 1);
    }
    product.to_owned()
}

/// x86_64 的进程是否跑在 ARM64 的系统上（经仿真）。
fn emulated_on_arm64() -> bool {
    if !cfg!(target_arch = "x86_64") {
        return false;
    }
    let mut process = IMAGE_FILE_MACHINE::default();
    let mut native = IMAGE_FILE_MACHINE::default();
    // SAFETY: GetCurrentProcess 返回伪句柄，不用关闭；两个输出参数指向本地变量。
    let result = unsafe { IsWow64Process2(GetCurrentProcess(), &mut process, Some(&mut native)) };
    result.is_ok() && native == IMAGE_FILE_MACHINE_ARM64
}

/// 物理内存的字节数；读不到时为 0。
fn physical_memory() -> u64 {
    // 结构的第一个字段要先填上自身的大小，系统据此判断版本。
    let mut status = MEMORYSTATUSEX {
        dwLength: size_of::<MEMORYSTATUSEX>() as u32,
        ..MEMORYSTATUSEX::default()
    };
    // SAFETY: status 是本地变量，dwLength 已按要求填好结构的大小。
    match unsafe { GlobalMemoryStatusEx(&mut status) } {
        Ok(()) => status.ullTotalPhys,
        Err(_) => 0,
    }
}

/// 用户的区域设置，如 `zh-CN`；读不到时为空串。
fn locale_name() -> String {
    // LOCALE_NAME_MAX_LENGTH 是 85。
    let mut buffer = [0u16; 85];
    // SAFETY: 缓冲区在调用期间有效，长度由切片给出。
    let length = unsafe { GetUserDefaultLocaleName(&mut buffer) };
    // 返回的长度含结尾的 0；失败时是 0。
    let length = usize::try_from(length).unwrap_or(0).saturating_sub(1);
    String::from_utf16_lossy(&buffer[..length.min(buffer.len())])
}

/// 显卡的名字，按 DXGI 的枚举顺序（主显卡在前），去掉软件渲染器与重复的名字。
fn gpu_names() -> Vec<String> {
    // SAFETY: 只取一个工厂接口，失败时返回错误。
    let Ok(factory) = (unsafe { CreateDXGIFactory1::<IDXGIFactory1>() }) else {
        return Vec::new();
    };
    // 同一块显卡在多显示器、混合显卡的机器上可能出现多次，按名字去重。
    let mut names: Vec<String> = Vec::new();
    // 枚举到 DXGI_ERROR_NOT_FOUND 为止；上限防止异常的驱动让循环停不下来。
    for index in 0..16 {
        // SAFETY: factory 是有效的接口；越界时返回错误，循环结束。
        let Ok(adapter) = (unsafe { factory.EnumAdapters1(index) }) else {
            break;
        };
        // SAFETY: adapter 是刚取到的有效接口。
        let Ok(desc) = (unsafe { adapter.GetDesc1() }) else {
            continue;
        };
        if desc.Flags & (DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32) != 0 {
            continue;
        }
        let end = desc
            .Description
            .iter()
            .position(|&c| c == 0)
            .unwrap_or(desc.Description.len());
        let name = String::from_utf16_lossy(&desc.Description[..end])
            .trim()
            .to_owned();
        if !name.is_empty() && !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

/// 本机名字的词表（不含角色名）：用户名、计算机名与用户目录。
pub fn sensitive_names() -> RedactionTerms {
    // 用户名取环境变量：与用户目录的最后一段多半相同，但微软账户登录时两者可能不同，所以两样都给。
    let user_names: Vec<String> = std::env::var("USERNAME").ok().into_iter().collect();
    // 计算机名的几种写法可能只有大小写不同，不区分大小写地去重（脱敏本来就不区分大小写）。
    let mut host_names: Vec<String> = Vec::new();
    for format in [
        ComputerNameDnsFullyQualified,
        ComputerNameDnsHostname,
        ComputerNamePhysicalNetBIOS,
    ] {
        if let Some(name) = computer_name(format)
            && !host_names.iter().any(|known| known.eq_ignore_ascii_case(&name))
        {
            host_names.push(name);
        }
    }
    RedactionTerms {
        user_names,
        host_names,
        character_names: Vec::new(),
        home_directory: std::env::var("USERPROFILE").ok(),
    }
}

/// 一种写法的计算机名；读不到或是空串时为 None。
fn computer_name(format: COMPUTER_NAME_FORMAT) -> Option<String> {
    let mut size = 0u32;
    // 第一次调用只取所需的长度（含结尾的 0），函数按约定返回 ERROR_MORE_DATA。
    // SAFETY: 缓冲区传空，函数只写 size。
    let _ = unsafe { GetComputerNameExW(format, None, &mut size) };
    if size == 0 {
        return None;
    }
    let mut buffer = vec![0u16; size as usize];
    // SAFETY: 缓冲区的长度如实给出（以 u16 计）；成功时 size 是不含结尾 0 的长度。
    unsafe { GetComputerNameExW(format, Some(PWSTR(buffer.as_mut_ptr())), &mut size) }.ok()?;
    let name = String::from_utf16_lossy(&buffer[..(size as usize).min(buffer.len())]);
    (!name.trim().is_empty()).then(|| name.trim().to_owned())
}

/// 读注册表里的字符串值；不存在或类型不对时为 None。
pub(crate) fn registry_string(root: HKEY, key: &str, value: &str) -> Option<String> {
    // HSTRING 以 0 结尾，可以直接当 PCWSTR 用。
    let (key, value) = (HSTRING::from(key), HSTRING::from(value));
    let mut size = 0u32;
    // 第一次调用只取字节数（含结尾的 0）。
    // SAFETY: 键名与值名是有效的宽字符串；输出缓冲区传空，函数只写 size。
    unsafe {
        RegGetValueW(
            root,
            PCWSTR(key.as_ptr()),
            PCWSTR(value.as_ptr()),
            RRF_RT_REG_SZ,
            None,
            None,
            Some(&mut size),
        )
    }
    .ok()
    .ok()?;
    // size 是字节数，换成 u16 的个数（向上取整）。
    let mut buffer = vec![0u16; (size as usize).div_ceil(2)];
    // SAFETY: 缓冲区的字节数如实给出；函数写入以 0 结尾的字符串并更新 size。
    unsafe {
        RegGetValueW(
            root,
            PCWSTR(key.as_ptr()),
            PCWSTR(value.as_ptr()),
            RRF_RT_REG_SZ,
            None,
            Some(buffer.as_mut_ptr().cast()),
            Some(&mut size),
        )
    }
    .ok()
    .ok()?;
    let end = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
    Some(String::from_utf16_lossy(&buffer[..end]))
}

/// 读注册表里的 DWORD 值；不存在或类型不对时为 None。
fn registry_dword(root: HKEY, key: &str, value: &str) -> Option<u32> {
    let (key, value) = (HSTRING::from(key), HSTRING::from(value));
    let mut data = 0u32;
    let mut size = size_of::<u32>() as u32;
    // SAFETY: 输出缓冲区是一个 u32，大小如实给出；键名与值名是有效的宽字符串。
    unsafe {
        RegGetValueW(
            root,
            PCWSTR(key.as_ptr()),
            PCWSTR(value.as_ptr()),
            RRF_RT_REG_DWORD,
            None,
            Some((&raw mut data).cast()),
            Some(&mut size),
        )
    }
    .ok()
    .ok()?;
    Some(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 产品名：Windows 11 的构建号把「Windows 10」改正；空串写 Windows。
    #[test]
    fn product_names() {
        assert_eq!(product_name("Windows 10 Pro", 26_100), "Windows 11 Pro");
        assert_eq!(product_name("Windows 10 Pro", 19_045), "Windows 10 Pro");
        assert_eq!(product_name(" ", 26_100), "Windows");
    }
}
