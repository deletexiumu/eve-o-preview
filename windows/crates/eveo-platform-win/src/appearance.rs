// SPDX-License-Identifier: GPL-3.0-or-later
//
// 系统外观：应用是否该用暗色，让窗口的标题栏跟着变暗，以及用户的界面语言偏好。
// 暗色取自「设置 → 个性化 → 颜色 → 选择默认应用模式」，存在注册表
// HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize 的 AppsUseLightTheme（0 是暗色）。
// 读不到（Windows 10 早期版本、策略禁用）时按浅色处理。

//! 系统的明暗外观与界面语言偏好。

use windows::Win32::Foundation::HWND;
use windows::Win32::Globalization::{GetUserPreferredUILanguages, MUI_LANGUAGE_NAME};
use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::core::{PWSTR, w};

/// 应用是否该用暗色外观。
pub fn apps_use_dark_theme() -> bool {
    let mut value: u32 = 1;
    let mut size = size_of::<u32>() as u32;
    // SAFETY: 输出缓冲区是一个 u32，大小如实给出；键名与值名是静态的宽字符串。
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("AppsUseLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some((&raw mut value).cast()),
            Some(&mut size),
        )
    };
    status.is_ok() && value == 0
}

/// 让窗口的标题栏与边框用暗色（Windows 10 20H1 起支持；更早的系统忽略，返回错误也无妨）。
pub fn set_dark_title_bar(hwnd: HWND, dark: bool) {
    let value = windows::core::BOOL::from(dark);
    // SAFETY: 句柄来自调用方的活动窗口；value 在调用期间有效，大小如实给出。
    let _ = unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            (&raw const value).cast(),
            size_of_val(&value) as u32,
        )
    };
}

/// 用户的界面语言偏好，按优先顺序，如 `["zh-CN", "en-US"]`（「设置 → 时间和语言 → 语言和区域」里的顺序）。
/// 界面语言选「跟随系统」时用它求出实际语言（`LanguagePreference::resolved`）。读不到时返回空表，按英文处理。
pub fn preferred_ui_languages() -> Vec<String> {
    let (mut count, mut size) = (0u32, 0u32);
    // 第一次调用只取所需的缓冲区长度（以 u16 计，含结尾的两个 0）。
    // SAFETY: 两个输出参数指向本地变量；缓冲区传空，函数只写长度。
    if unsafe { GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &mut count, None, &mut size) }.is_err()
        || size == 0
    {
        return Vec::new();
    }
    let mut buffer = vec![0u16; size as usize];
    // SAFETY: 缓冲区的长度如实给出，函数最多写 size 个 u16。
    let filled = unsafe {
        GetUserPreferredUILanguages(
            MUI_LANGUAGE_NAME,
            &mut count,
            Some(PWSTR(buffer.as_mut_ptr())),
            &mut size,
        )
    };
    if filled.is_err() {
        return Vec::new();
    }
    // 结果是以 0 分隔、以两个 0 结尾的多个字符串。
    buffer
        .split(|&c| c == 0)
        .filter(|part| !part.is_empty())
        .map(String::from_utf16_lossy)
        .collect()
}
