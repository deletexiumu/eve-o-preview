// SPDX-License-Identifier: GPL-3.0-or-later
//
// 键名与 Windows 虚拟键码（VK_*）的对照表，对应 macOS 的 Hotkeys/KeyCodeTable.swift（架构文档 4.4 节）。
// 键名两端相同，配置可以互相导入；键码各用本平台的：macOS 是 Carbon 的 kVK_*，这里是 VK_*。
// 虚拟键码按键位与键盘布局给出的字符对应；字母与数字键的 VK 与布局无关，符号键（VK_OEM_*）随布局变化，
// 这与 RegisterHotKey 的行为一致。数值取自 SDK 的 WinUser.h。

//! 热键字符串里的键名与 Windows 虚拟键码的对照。

/// 一条对照：规范键名与虚拟键码。
pub type KeyEntry = (&'static str, u8);

/// A～Z（VK 与 ASCII 大写字母相同）。
const LETTERS: [KeyEntry; 26] = [
    ("A", 0x41),
    ("B", 0x42),
    ("C", 0x43),
    ("D", 0x44),
    ("E", 0x45),
    ("F", 0x46),
    ("G", 0x47),
    ("H", 0x48),
    ("I", 0x49),
    ("J", 0x4A),
    ("K", 0x4B),
    ("L", 0x4C),
    ("M", 0x4D),
    ("N", 0x4E),
    ("O", 0x4F),
    ("P", 0x50),
    ("Q", 0x51),
    ("R", 0x52),
    ("S", 0x53),
    ("T", 0x54),
    ("U", 0x55),
    ("V", 0x56),
    ("W", 0x57),
    ("X", 0x58),
    ("Y", 0x59),
    ("Z", 0x5A),
];

/// 主键盘的 0～9（VK 与 ASCII 数字相同）。
const DIGITS: [KeyEntry; 10] = [
    ("0", 0x30),
    ("1", 0x31),
    ("2", 0x32),
    ("3", 0x33),
    ("4", 0x34),
    ("5", 0x35),
    ("6", 0x36),
    ("7", 0x37),
    ("8", 0x38),
    ("9", 0x39),
];

/// F1～F20（VK_F1 = 0x70 起连续）。Windows 还有 F21～F24，macOS 没有，为了配置能互相导入不收录。
const FUNCTION_KEYS: [KeyEntry; 20] = [
    ("F1", 0x70),
    ("F2", 0x71),
    ("F3", 0x72),
    ("F4", 0x73),
    ("F5", 0x74),
    ("F6", 0x75),
    ("F7", 0x76),
    ("F8", 0x77),
    ("F9", 0x78),
    ("F10", 0x79),
    ("F11", 0x7A),
    ("F12", 0x7B),
    ("F13", 0x7C),
    ("F14", 0x7D),
    ("F15", 0x7E),
    ("F16", 0x7F),
    ("F17", 0x80),
    ("F18", 0x81),
    ("F19", 0x82),
    ("F20", 0x83),
];

/// 小键盘的 0～9（VK_NUMPAD0 = 0x60 起连续）。
const KEYPAD: [KeyEntry; 10] = [
    ("Num0", 0x60),
    ("Num1", 0x61),
    ("Num2", 0x62),
    ("Num3", 0x63),
    ("Num4", 0x64),
    ("Num5", 0x65),
    ("Num6", 0x66),
    ("Num7", 0x67),
    ("Num8", 0x68),
    ("Num9", 0x69),
];

/// 其余有名字的键。`Delete` 沿用 macOS 的叫法，指退格键（VK_BACK），不是向前删除。
const OTHERS: [KeyEntry; 24] = [
    ("Tab", 0x09),
    ("Space", 0x20),
    ("Return", 0x0D),
    ("Escape", 0x1B),
    ("Delete", 0x08),
    ("Left", 0x25),
    ("Right", 0x27),
    ("Up", 0x26),
    ("Down", 0x28),
    ("Home", 0x24),
    ("End", 0x23),
    ("PageUp", 0x21),
    ("PageDown", 0x22),
    ("Grave", 0xC0),
    ("Minus", 0xBD),
    ("Equal", 0xBB),
    ("LeftBracket", 0xDB),
    ("RightBracket", 0xDD),
    ("Backslash", 0xDC),
    ("Semicolon", 0xBA),
    ("Quote", 0xDE),
    ("Comma", 0xBC),
    ("Period", 0xBE),
    ("Slash", 0xBF),
];

/// 全部对照，按「字母、数字、功能键、小键盘、其他」排列；名称是热键字符串的规范写法。
pub fn entries() -> impl Iterator<Item = KeyEntry> {
    LETTERS
        .iter()
        .chain(&DIGITS)
        .chain(&FUNCTION_KEYS)
        .chain(&KEYPAD)
        .chain(&OTHERS)
        .copied()
}

/// 键码对应的规范键名；表里没有时返回 `None`（调用方写成 `Key<键码>`）。
pub fn name(key_code: u8) -> Option<&'static str> {
    entries()
        .find(|&(_, code)| code == key_code)
        .map(|(name, _)| name)
}

/// 键名对应的键码，不区分大小写；只认表里的名称，不解析 `Key<键码>`。
pub fn key_code(name: &str) -> Option<u8> {
    let lower = name.to_lowercase();
    entries()
        .find(|(entry, _)| entry.to_lowercase() == lower)
        .map(|(_, code)| code)
}

/// 是否为功能键 F1～F20。
pub fn is_function_key(key_code: u8) -> bool {
    FUNCTION_KEYS.iter().any(|&(_, code)| code == key_code)
}

/// 是否为小键盘数字键 Num0～Num9。
pub fn is_keypad_digit(key_code: u8) -> bool {
    KEYPAD.iter().any(|&(_, code)| code == key_code)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// 名称与键码各自不重复，表里共 90 项。
    #[test]
    fn names_and_codes_are_unique() {
        let all: Vec<_> = entries().collect();
        assert_eq!(all.len(), 90);
        let names: HashSet<_> = all.iter().map(|(n, _)| n.to_lowercase()).collect();
        let codes: HashSet<_> = all.iter().map(|(_, c)| *c).collect();
        assert_eq!(names.len(), all.len());
        assert_eq!(codes.len(), all.len());
    }

    /// 查找不区分大小写，往返一致。
    #[test]
    fn lookup_round_trips() {
        assert_eq!(key_code("f13"), Some(0x7C));
        assert_eq!(key_code("NUM1"), Some(0x61));
        assert_eq!(name(0x7C), Some("F13"));
        assert_eq!(name(0x6E), None);
        assert!(is_function_key(0x83) && !is_function_key(0x84));
        assert!(is_keypad_digit(0x69) && !is_keypad_digit(0x6A));
    }
}
