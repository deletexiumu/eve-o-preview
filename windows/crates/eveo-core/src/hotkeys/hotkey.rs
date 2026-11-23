// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的值类型与字符串语法，对应 macOS 的 Hotkeys/Hotkey.swift（架构文档 4.4 节、5.5 节）。
// 语法两端相同：用 `+` 连接，不区分大小写；修饰键在前，最后一段是触发键。
// 修饰键：ctrl；alt（别名 opt）；shift；win（别名 cmd）。macOS 的 opt 与 cmd 在这里分别对应 Alt 与 Win，
// 所以 macOS 的配置可以直接读；规范写法输出本平台的叫法：`ctrl+alt+shift+win+触发键`。
// 触发键是键名、`Key<虚拟键码>` 或 `Mouse<序号>`（序号 3～32，与 macOS 相同：按钮号 = 序号 - 1）。
// Windows 只能检测中键（Mouse3）与两个侧键（Mouse4、Mouse5），更大的序号能解析，由规划拒绝。
// 作用范围后缀 `@global`、`@game` 不归本类型解析，见 HotkeySpec。

//! 热键：触发键加修饰键。

use std::fmt;
use std::ops::{BitOr, BitOrAssign};
use std::str::FromStr;

use super::key_code;
use crate::support::text;

/// 热键的修饰键集合（位集合）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct HotkeyModifiers(u8);

impl HotkeyModifiers {
    /// 空集合。
    pub const NONE: Self = Self(0);
    /// Win 键，字符串写作 `win`（macOS 配置里的 `cmd` 也读成它）。
    pub const WIN: Self = Self(1);
    /// Alt 键，字符串写作 `alt`（别名 `opt`）。
    pub const ALT: Self = Self(2);
    /// Ctrl 键，字符串写作 `ctrl`。
    pub const CONTROL: Self = Self(4);
    /// Shift 键，字符串写作 `shift`。
    pub const SHIFT: Self = Self(8);

    /// 是否包含 other 的全部位。
    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// 与 other 没有共同的位。
    pub fn is_disjoint(self, other: Self) -> bool {
        self.0 & other.0 == 0
    }

    /// 是否为空。
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// 转成 `RegisterHotKey` 的 fsModifiers 位（MOD_ALT = 1、MOD_CONTROL = 2、MOD_SHIFT = 4、MOD_WIN = 8），
    /// 不含 MOD_NOREPEAT，由平台层加上。
    pub fn win32_flags(self) -> u32 {
        let mut flags = 0;
        if self.contains(Self::ALT) {
            flags |= 1;
        }
        if self.contains(Self::CONTROL) {
            flags |= 2;
        }
        if self.contains(Self::SHIFT) {
            flags |= 4;
        }
        if self.contains(Self::WIN) {
            flags |= 8;
        }
        flags
    }

    /// 修饰键名（不区分大小写）到修饰键；macOS 的 `opt`、`cmd` 分别读成 Alt、Win。
    fn named(name: &str) -> Option<Self> {
        match name.to_lowercase().as_str() {
            "ctrl" => Some(Self::CONTROL),
            "alt" | "opt" => Some(Self::ALT),
            "shift" => Some(Self::SHIFT),
            "win" | "cmd" => Some(Self::WIN),
            _ => None,
        }
    }

    /// 按固定顺序（Ctrl、Alt、Shift、Win）列出包含的修饰键与它们的规范名、界面名。
    fn parts(self) -> impl Iterator<Item = (&'static str, &'static str)> {
        [
            (Self::CONTROL, "ctrl", "Ctrl"),
            (Self::ALT, "alt", "Alt"),
            (Self::SHIFT, "shift", "Shift"),
            (Self::WIN, "win", "Win"),
        ]
        .into_iter()
        .filter(move |(flag, _, _)| self.contains(*flag))
        .map(|(_, raw, display)| (raw, display))
    }
}

impl BitOr for HotkeyModifiers {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl BitOrAssign for HotkeyModifiers {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

/// 热键的触发键：一个键盘按键或一个鼠标按键。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HotkeyTrigger {
    /// 键盘按键，关联值是 Windows 虚拟键码（VK_*）。
    Key(u8),
    /// 鼠标按键，关联值是按钮号 2～31，编号与 macOS 相同：2 是中键，3、4 是两个侧键（XBUTTON1、XBUTTON2）。
    MouseButton(u8),
}

/// 一个热键：触发键加修饰键。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Hotkey {
    /// 触发键。
    pub trigger: HotkeyTrigger,
    /// 修饰键。
    pub modifiers: HotkeyModifiers,
}

/// 能解析的鼠标按钮号：与 macOS 相同的 2～31。
pub const MOUSE_BUTTON_RANGE: std::ops::RangeInclusive<u8> = 2..=31;

/// Windows 能检测的鼠标按钮号：中键与两个侧键。
pub const WINDOWS_MOUSE_BUTTONS: std::ops::RangeInclusive<u8> = 2..=4;

impl Hotkey {
    /// 用键码与修饰键建一个键盘热键。
    pub fn key(key_code: u8, modifiers: HotkeyModifiers) -> Self {
        Self {
            trigger: HotkeyTrigger::Key(key_code),
            modifiers,
        }
    }

    /// 用按钮号与修饰键建一个鼠标热键；按钮号不在 2～31 时返回 `None`。
    pub fn mouse(button: u8, modifiers: HotkeyModifiers) -> Option<Self> {
        MOUSE_BUTTON_RANGE.contains(&button).then_some(Self {
            trigger: HotkeyTrigger::MouseButton(button),
            modifiers,
        })
    }

    /// 解析热键字符串，如 `ctrl+shift+F13`、`Alt+Num1`、`win+Key110`、`ctrl+Mouse4`。
    ///
    /// - 各段去掉首尾的空格与制表符（不去换行，同 Foundation 的 `.whitespaces`），不区分大小写；
    ///   最后一段是触发键，前面各段都应是修饰键。
    /// - 键名取自 `key_code`；表外的键写成 `Key<虚拟键码>`（十进制，1～254）。
    /// - 鼠标按键写成 `Mouse<序号>`，序号 3～32；`Mouse1`、`Mouse2`（左右键）与范围外的序号返回 `None`。
    /// - 只有修饰键、出现空段或未知的段时返回 `None`。重复的修饰键按一个处理。
    /// - 不接受作用范围后缀：带 `@` 的字符串返回 `None`，应改用 `HotkeySpec::parse`。
    pub fn parse(string: &str) -> Option<Self> {
        let parts: Vec<&str> = string.split('+').map(text::trim_whitespace).collect();
        let (trigger_part, modifier_parts) = parts.split_last()?;
        if parts.iter().any(|part| part.is_empty()) {
            return None;
        }
        let mut modifiers = HotkeyModifiers::NONE;
        for part in modifier_parts {
            modifiers |= HotkeyModifiers::named(part)?;
        }
        Some(Self {
            trigger: parse_trigger(trigger_part)?,
            modifiers,
        })
    }

    /// 键盘触发键的键码；鼠标触发键返回 `None`。
    pub fn key_code(&self) -> Option<u8> {
        match self.trigger {
            HotkeyTrigger::Key(code) => Some(code),
            HotkeyTrigger::MouseButton(_) => None,
        }
    }

    /// 鼠标触发键的按钮号；键盘触发键返回 `None`。
    pub fn mouse_button(&self) -> Option<u8> {
        match self.trigger {
            HotkeyTrigger::MouseButton(button) => Some(button),
            HotkeyTrigger::Key(_) => None,
        }
    }

    /// 触发键是不是鼠标按键。
    pub fn is_mouse(&self) -> bool {
        self.mouse_button().is_some()
    }

    /// 界面写法，Windows 的习惯：`Ctrl+Alt+Shift+Win+触发键`，如 `Ctrl+Shift+F13`、`Ctrl+Mouse4`。
    ///
    /// 几个键换成 Windows 键盘上的叫法（`Return` → `Enter`、`Delete` → `Backspace` 等），符号键显示符号。
    pub fn display_string(&self) -> String {
        let name = self.trigger_name();
        let key = display_name(&name).map_or(name.clone(), str::to_owned);
        let mut parts: Vec<String> = self.modifiers.parts().map(|(_, d)| d.to_owned()).collect();
        parts.push(key);
        parts.join("+")
    }

    /// 触发键的规范写法：表内的键为键名，表外的键为 `Key<键码>`，鼠标按键为 `Mouse<按钮号 + 1>`。
    fn trigger_name(&self) -> String {
        match self.trigger {
            HotkeyTrigger::Key(code) => {
                key_code::name(code).map_or_else(|| format!("Key{code}"), str::to_owned)
            }
            HotkeyTrigger::MouseButton(button) => format!("Mouse{}", u16::from(button) + 1),
        }
    }
}

/// 规范写法，顺序固定为 `ctrl+alt+shift+win+触发键`，如 `ctrl+shift+F13`、`ctrl+Mouse4`。
/// `Hotkey::parse` 能把结果解析回同一个热键。
impl fmt::Display for Hotkey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (raw, _) in self.modifiers.parts() {
            write!(f, "{raw}+")?;
        }
        f.write_str(&self.trigger_name())
    }
}

impl FromStr for Hotkey {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, ()> {
        Self::parse(s).ok_or(())
    }
}

/// 触发键的写法到触发键：先查键名表，再按 `Key<键码>`、`Mouse<序号>` 解析。
fn parse_trigger(name: &str) -> Option<HotkeyTrigger> {
    if let Some(code) = key_code::key_code(name) {
        return Some(HotkeyTrigger::Key(code));
    }
    let lower = name.to_lowercase();
    if let Some(digits) = decimal_suffix(&lower, "key") {
        // 虚拟键码是 1～254；0 与 255 不是有效的键。位数过多时解析失败。
        let code: u8 = digits.parse().ok()?;
        return (1..=254).contains(&code).then_some(HotkeyTrigger::Key(code));
    }
    if let Some(digits) = decimal_suffix(&lower, "mouse") {
        // 序号 = 按钮号 + 1；按 64 位整数解析，同 Swift 的 Int，位数过多或越界都返回 None。
        let ordinal: i64 = digits.parse().ok()?;
        let button = u8::try_from(ordinal - 1).ok()?;
        return MOUSE_BUTTON_RANGE
            .contains(&button)
            .then_some(HotkeyTrigger::MouseButton(button));
    }
    None
}

/// 以 prefix 开头、后面全是 ASCII 十进制数字时返回数字部分，否则返回 `None`。
/// 排除 `Key+5`、`Key-1`、`Mouse4x` 与全角数字一类写法。
fn decimal_suffix<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let digits = text.strip_prefix(prefix)?;
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then_some(digits)
}

/// 界面上换一种写法显示的键。
fn display_name(name: &str) -> Option<&'static str> {
    Some(match name {
        "Return" => "Enter",
        "Escape" => "Esc",
        "Delete" => "Backspace",
        "PageUp" => "PgUp",
        "PageDown" => "PgDn",
        "Grave" => "`",
        "Minus" => "-",
        "Equal" => "=",
        "LeftBracket" => "[",
        "RightBracket" => "]",
        "Backslash" => "\\",
        "Semicolon" => ";",
        "Quote" => "'",
        "Comma" => ",",
        "Period" => ".",
        "Slash" => "/",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// macOS 的写法能读，输出本平台的规范写法与界面写法。
    #[test]
    fn reads_macos_modifiers() {
        let hotkey = Hotkey::parse(" cmd + Opt + shift+ctrl+h ").expect("能解析");
        assert_eq!(hotkey.to_string(), "ctrl+alt+shift+win+H");
        assert_eq!(hotkey.display_string(), "Ctrl+Alt+Shift+Win+H");
        assert_eq!(hotkey.modifiers.win32_flags(), 0b1111);
    }

    /// 键码与鼠标按键的边界。
    #[test]
    fn trigger_bounds() {
        assert_eq!(Hotkey::parse("Key254").map(|h| h.key_code()), Some(Some(254)));
        assert!(Hotkey::parse("Key0").is_none());
        assert!(Hotkey::parse("Key255").is_none());
        assert!(Hotkey::parse("Mouse2").is_none());
        assert_eq!(Hotkey::parse("mouse32").and_then(|h| h.mouse_button()), Some(31));
        assert!(Hotkey::parse("Mouse33").is_none());
        assert!(Hotkey::parse("Mouse99999999999999999999").is_none());
        assert_eq!(
            Hotkey::parse("Return").map(|h| h.display_string()),
            Some("Enter".into())
        );
    }
}
