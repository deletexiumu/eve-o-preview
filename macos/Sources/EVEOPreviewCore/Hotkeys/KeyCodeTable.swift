// SPDX-License-Identifier: GPL-3.0-or-later
//
// 键名与 Carbon 虚拟键码（kVK_*）的对照表（架构文档 5.5 节）。
// 键码按键位而不按字符，与键盘布局无关；数值取自 SDK 的 HIToolbox/Events.h。
// Core 不 import Carbon，所以这里手写数值，测试里再与 Carbon 常量逐个核对。

import Foundation

/// 热键字符串里的键名与 Carbon 虚拟键码的对照。
public enum KeyCodeTable {
    /// 规范键名与键码，按「字母、数字、功能键、小键盘、其他」排列。
    ///
    /// 名称是热键字符串的规范写法；解析时不区分大小写。
    public static let entries: [(name: String, keyCode: UInt16)] = letters + digits + functionKeys
        + keypad + others

    /// 键码对应的规范键名；表里没有时返回 nil（调用方写成 `Key<键码>`）。
    public static func name(for keyCode: UInt16) -> String? {
        nameByCode[keyCode]
    }

    /// 键名对应的键码，不区分大小写；只认表里的名称，不解析 `Key<键码>`。
    public static func keyCode(for name: String) -> UInt16? {
        codeByLowercasedName[name.lowercased()]
    }

    /// 是否为功能键 F1～F20。
    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains { $0.keyCode == keyCode }
    }

    /// 是否为小键盘数字键 Num0～Num9。
    public static func isKeypadDigit(_ keyCode: UInt16) -> Bool {
        keypad.contains { $0.keyCode == keyCode }
    }

    // MARK: - 对照数据

    /// A～Z（kVK_ANSI_A 等）。
    static let letters: [(name: String, keyCode: UInt16)] = [
        ("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E), ("F", 0x03), ("G", 0x05),
        ("H", 0x04), ("I", 0x22), ("J", 0x26), ("K", 0x28), ("L", 0x25), ("M", 0x2E), ("N", 0x2D),
        ("O", 0x1F), ("P", 0x23), ("Q", 0x0C), ("R", 0x0F), ("S", 0x01), ("T", 0x11), ("U", 0x20),
        ("V", 0x09), ("W", 0x0D), ("X", 0x07), ("Y", 0x10), ("Z", 0x06),
    ]

    /// 主键盘的 0～9（kVK_ANSI_0 等）。
    static let digits: [(name: String, keyCode: UInt16)] = [
        ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
        ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
    ]

    /// F1～F20（kVK_F1 等）。
    static let functionKeys: [(name: String, keyCode: UInt16)] = [
        ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76), ("F5", 0x60),
        ("F6", 0x61), ("F7", 0x62), ("F8", 0x64), ("F9", 0x65), ("F10", 0x6D),
        ("F11", 0x67), ("F12", 0x6F), ("F13", 0x69), ("F14", 0x6B), ("F15", 0x71),
        ("F16", 0x6A), ("F17", 0x40), ("F18", 0x4F), ("F19", 0x50), ("F20", 0x5A),
    ]

    /// 小键盘的 0～9（kVK_ANSI_Keypad0 等）。
    static let keypad: [(name: String, keyCode: UInt16)] = [
        ("Num0", 0x52), ("Num1", 0x53), ("Num2", 0x54), ("Num3", 0x55), ("Num4", 0x56),
        ("Num5", 0x57), ("Num6", 0x58), ("Num7", 0x59), ("Num8", 0x5B), ("Num9", 0x5C),
    ]

    /// 其余有名字的键：编辑、方向、导航与符号键。
    static let others: [(name: String, keyCode: UInt16)] = [
        ("Tab", 0x30), ("Space", 0x31), ("Return", 0x24), ("Escape", 0x35), ("Delete", 0x33),
        ("Left", 0x7B), ("Right", 0x7C), ("Up", 0x7E), ("Down", 0x7D),
        ("Home", 0x73), ("End", 0x77), ("PageUp", 0x74), ("PageDown", 0x79),
        ("Grave", 0x32), ("Minus", 0x1B), ("Equal", 0x18), ("LeftBracket", 0x21), ("RightBracket", 0x1E),
        ("Backslash", 0x2A), ("Semicolon", 0x29), ("Quote", 0x27), ("Comma", 0x2B), ("Period", 0x2F),
        ("Slash", 0x2C),
    ]

    /// 键码 → 规范名称。
    private static let nameByCode: [UInt16: String] = Dictionary(
        entries.map { ($0.keyCode, $0.name) }, uniquingKeysWith: { first, _ in first })

    /// 小写名称 → 键码。
    private static let codeByLowercasedName: [String: UInt16] = Dictionary(
        entries.map { ($0.name.lowercased(), $0.keyCode) }, uniquingKeysWith: { first, _ in first })
}
