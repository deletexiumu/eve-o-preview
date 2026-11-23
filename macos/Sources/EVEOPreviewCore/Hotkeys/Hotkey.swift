// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的值类型与字符串语法（架构文档 5.5 节，反馈文档 6.1 节、6.2 节）。
// 语法：用 `+` 连接，不区分大小写；修饰键是 ctrl、opt（别名 alt）、shift、cmd，最后一段是触发键。
// 触发键是键名、`Key<键码>` 或 `Mouse<序号>`（序号 3～32，对应 CGEvent 的按钮号 2～31）。
// 作用范围后缀 `@global`、`@game` 不归本类型解析，见 HotkeySpec。

import Foundation

/// 热键的修饰键集合。
public struct HotkeyModifiers: OptionSet, Sendable, Hashable {
    /// 位集合的原始值。
    public let rawValue: UInt8

    /// 用原始值建一个修饰键集合。
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Command（⌘），字符串写作 `cmd`。
    public static let command = HotkeyModifiers(rawValue: 1)
    /// Option（⌥），字符串写作 `opt` 或 `alt`。
    public static let option = HotkeyModifiers(rawValue: 2)
    /// Control（⌃），字符串写作 `ctrl`。
    public static let control = HotkeyModifiers(rawValue: 4)
    /// Shift（⇧），字符串写作 `shift`。
    public static let shift = HotkeyModifiers(rawValue: 8)
}

/// 热键的触发键：一个键盘按键或一个鼠标按键。
public enum HotkeyTrigger: Sendable, Hashable {
    /// 键盘按键，关联值是 Carbon 虚拟键码（kVK_*），按键位而不按字符。
    case key(UInt16)
    /// 鼠标按键，关联值是 CGEvent 的按钮号，2～31（左键 0、右键 1 不能绑定）。
    case mouseButton(Int)
}

/// 一个热键：触发键加修饰键。
public struct Hotkey: Sendable, Hashable {
    /// 触发键。
    public var trigger: HotkeyTrigger
    /// 修饰键。
    public var modifiers: HotkeyModifiers

    /// 可以绑定的鼠标按钮号：2 是中键，3、4 通常是两个侧键，其余是附加按键。
    public static let mouseButtonRange: ClosedRange<Int> = 2...31

    /// 用触发键与修饰键建一个热键。不检查鼠标按钮号的范围，调用方应保证在 `mouseButtonRange` 内。
    public init(trigger: HotkeyTrigger, modifiers: HotkeyModifiers) {
        self.trigger = trigger
        self.modifiers = modifiers
    }

    /// 用键码与修饰键建一个键盘热键。
    public init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.init(trigger: .key(keyCode), modifiers: modifiers)
    }

    /// 用按钮号与修饰键建一个鼠标热键。按钮号不在 2～31 时返回 nil。
    public init?(mouseButton: Int, modifiers: HotkeyModifiers) {
        guard Hotkey.mouseButtonRange.contains(mouseButton) else { return nil }
        self.init(trigger: .mouseButton(mouseButton), modifiers: modifiers)
    }

    /// 解析热键字符串，如 `ctrl+shift+F13`、`Opt+Num1`、`cmd+Key110`、`ctrl+Mouse4`。
    ///
    /// - 各段去掉首尾空白，不区分大小写；最后一段是触发键，前面各段都应是修饰键。
    /// - 键名取自 `KeyCodeTable`；表外的键写成 `Key<键码>`（十进制，0～65535）。
    /// - 鼠标按键写成 `Mouse<序号>`，序号 3～32；`Mouse1`、`Mouse2`（左右键）与范围外的序号返回 nil。
    /// - 只有修饰键、没有触发键，出现空段或未知的段时返回 nil。重复的修饰键按一个处理。
    /// - 不接受作用范围后缀：带 `@` 的字符串返回 nil，应改用 `HotkeySpec(string:)`。
    public init?(string: String) {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let triggerPart = parts.last, !parts.contains(where: \.isEmpty) else { return nil }
        var modifiers: HotkeyModifiers = []
        for part in parts.dropLast() {
            guard let modifier = Hotkey.modifier(named: part) else { return nil }
            modifiers.insert(modifier)
        }
        guard let trigger = Hotkey.trigger(named: triggerPart) else { return nil }
        self.init(trigger: trigger, modifiers: modifiers)
    }

    /// 键盘触发键的键码；鼠标触发键返回 nil。
    public var keyCode: UInt16? {
        if case .key(let code) = trigger { return code }
        return nil
    }

    /// 鼠标触发键的按钮号；键盘触发键返回 nil。
    public var mouseButton: Int? {
        if case .mouseButton(let button) = trigger { return button }
        return nil
    }

    /// 触发键是不是鼠标按键。
    public var isMouse: Bool {
        mouseButton != nil
    }

    /// 规范写法，顺序固定为 `ctrl+opt+shift+cmd+触发键`，如 `ctrl+shift+F13`、`ctrl+Mouse4`。
    ///
    /// 表外的键写成 `Key<键码>`。`Hotkey(string:)` 能把结果解析回同一个热键。
    public func stringValue() -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(triggerName)
        return parts.joined(separator: "+")
    }

    /// 界面写法，修饰键用 macOS 的符号，顺序同菜单：`⌃⌥⇧⌘`，如 `⌃⇧F13`、`⌃Mouse4`。
    ///
    /// 方向键与常用编辑键用符号（`←`、`↩`、`⇥`、`⎋`、`⌫` 等），其余键与鼠标按键用规范写法。
    public func displayString() -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Hotkey.displaySymbols[triggerName] ?? triggerName)
    }

    // MARK: - 私有

    /// 触发键的规范写法：表内的键为键名，表外的键为 `Key<键码>`，鼠标按键为 `Mouse<按钮号 + 1>`。
    private var triggerName: String {
        switch trigger {
        case .key(let code): return KeyCodeTable.name(for: code) ?? "Key\(code)"
        case .mouseButton(let button): return "Mouse\(button + 1)"
        }
    }

    /// 修饰键名（不区分大小写）到修饰键的映射。
    private static func modifier(named name: String) -> HotkeyModifiers? {
        switch name.lowercased() {
        case "ctrl": return .control
        case "opt", "alt": return .option
        case "shift": return .shift
        case "cmd": return .command
        default: return nil
        }
    }

    /// 触发键的写法到触发键：先查键名表，再按 `Key<键码>`、`Mouse<序号>` 解析。
    private static func trigger(named name: String) -> HotkeyTrigger? {
        if let code = KeyCodeTable.keyCode(for: name) { return .key(code) }
        let lower = name.lowercased()
        if let digits = decimalSuffix(of: lower, prefix: "key") {
            return UInt16(digits).map { .key($0) }
        }
        if let digits = decimalSuffix(of: lower, prefix: "mouse") {
            // 序号 = 按钮号 + 1；Int 解析失败（位数过多）或按钮号越界都返回 nil。
            guard let ordinal = Int(digits), mouseButtonRange.contains(ordinal - 1) else { return nil }
            return .mouseButton(ordinal - 1)
        }
        return nil
    }

    /// 以 prefix 开头、后面全是十进制数字时返回数字部分，否则返回 nil。
    /// 只接受纯 ASCII 数字，排除 `Key+5`、`Key-1`、`Mouse4x` 与全角数字一类写法。
    private static func decimalSuffix(of text: String, prefix: String) -> Substring? {
        guard text.hasPrefix(prefix) else { return nil }
        let digits = text.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return digits
    }

    /// 界面上用符号显示的键。
    private static let displaySymbols: [String: String] = [
        "Left": "←", "Right": "→", "Up": "↑", "Down": "↓",
        "Return": "↩", "Tab": "⇥", "Escape": "⎋", "Delete": "⌫", "Space": "Space",
        "Home": "↖", "End": "↘", "PageUp": "⇞", "PageDown": "⇟",
        "Grave": "`", "Minus": "-", "Equal": "=", "LeftBracket": "[", "RightBracket": "]",
        "Backslash": "\\", "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/",
    ]
}
