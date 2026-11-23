// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hotkey 与 KeyCodeTable 的用例（架构文档 5.5 节、10.2 节，反馈文档 6.1 节、10.1 节）。
// 键码表与 SDK 里 Carbon 的 kVK_* 常量逐个核对，避免手写数值出错；Core 本身不 import Carbon。

import Carbon.HIToolbox
import Testing
import EVEOPreviewCore

/// 热键字符串：往返、别名、大小写、Key<键码>、非法输入、规范顺序、界面写法。
struct HotkeyTests {
    /// 规范字符串解析后再输出，结果不变。
    @Test(arguments: ["ctrl+shift+F13", "opt+F13", "F1", "cmd+A", "ctrl+opt+shift+cmd+Num5", "shift+Key110",
                      "ctrl+PageDown", "opt+Grave", "ctrl+0"])
    func roundTrip(text: String) throws {
        let hotkey = try #require(Hotkey(string: text))
        #expect(hotkey.stringValue() == text)
        #expect(Hotkey(string: hotkey.stringValue()) == hotkey)
    }

    /// 修饰键与键名的解析结果。
    @Test func parsedValues() throws {
        let hotkey = try #require(Hotkey(string: "ctrl+shift+F13"))
        #expect(hotkey.keyCode == 0x69)
        #expect(hotkey.modifiers == [.control, .shift])
    }

    /// `alt` 是 `opt` 的别名，规范写法输出 `opt`。
    @Test func altAlias() throws {
        let hotkey = try #require(Hotkey(string: "alt+F2"))
        #expect(hotkey.modifiers == .option)
        #expect(hotkey.stringValue() == "opt+F2")
    }

    /// 不区分大小写，允许段两侧的空白；重复的修饰键按一个处理。
    @Test func caseAndWhitespaceInsensitive() {
        #expect(Hotkey(string: "CTRL+Shift+f13") == Hotkey(string: "ctrl+shift+F13"))
        #expect(Hotkey(string: " ctrl + pageup ")?.stringValue() == "ctrl+PageUp")
        #expect(Hotkey(string: "ctrl+ctrl+A")?.stringValue() == "ctrl+A")
    }

    /// 表外的键写成 Key<键码>；表内的键码写成 Key<键码> 也能解析，输出规范键名。
    @Test func keyCodeSyntax() {
        #expect(Hotkey(string: "Key110") == Hotkey(keyCode: 110, modifiers: []))
        #expect(Hotkey(keyCode: 110, modifiers: [.command]).stringValue() == "cmd+Key110")
        // 105 是 kVK_F13，在表内：解析后输出 F13。
        #expect(Hotkey(string: "ctrl+Key105")?.stringValue() == "ctrl+F13")
    }

    /// 非法输入返回 nil。
    @Test(arguments: ["", "ctrl", "ctrl+", "+A", "ctrl++A", "hyper+A", "ctrl+NoSuchKey", "Key", "Key-1",
                      "Key70000", "ctrl+A+B", "Key1a"])
    func invalid(text: String) {
        #expect(Hotkey(string: text) == nil)
    }

    /// 规范顺序固定为 ctrl、opt、shift、cmd。
    @Test func canonicalOrder() {
        #expect(Hotkey(string: "cmd+shift+opt+ctrl+Z")?.stringValue() == "ctrl+opt+shift+cmd+Z")
    }

    /// 界面写法：修饰键符号按 ⌃⌥⇧⌘ 排列，常用键用符号。
    @Test func displayString() {
        #expect(Hotkey(string: "ctrl+shift+F13")?.displayString() == "⌃⇧F13")
        #expect(Hotkey(string: "cmd+opt+ctrl+shift+Left")?.displayString() == "⌃⌥⇧⌘←")
        #expect(Hotkey(string: "opt+Return")?.displayString() == "⌥↩")
        #expect(Hotkey(string: "Key110")?.displayString() == "Key110")
    }

    /// 键码表与 Carbon 常量一致。
    @Test func keyCodeTableMatchesCarbon() {
        let expected: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
            "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
            "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7,
            "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12, "F13": kVK_F13,
            "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16, "F17": kVK_F17, "F18": kVK_F18, "F19": kVK_F19,
            "F20": kVK_F20,
            "Num0": kVK_ANSI_Keypad0, "Num1": kVK_ANSI_Keypad1, "Num2": kVK_ANSI_Keypad2, "Num3": kVK_ANSI_Keypad3,
            "Num4": kVK_ANSI_Keypad4, "Num5": kVK_ANSI_Keypad5, "Num6": kVK_ANSI_Keypad6, "Num7": kVK_ANSI_Keypad7,
            "Num8": kVK_ANSI_Keypad8, "Num9": kVK_ANSI_Keypad9,
            "Tab": kVK_Tab, "Space": kVK_Space, "Return": kVK_Return, "Escape": kVK_Escape, "Delete": kVK_Delete,
            "Left": kVK_LeftArrow, "Right": kVK_RightArrow, "Up": kVK_UpArrow, "Down": kVK_DownArrow,
            "Home": kVK_Home, "End": kVK_End, "PageUp": kVK_PageUp, "PageDown": kVK_PageDown,
            "Grave": kVK_ANSI_Grave, "Minus": kVK_ANSI_Minus, "Equal": kVK_ANSI_Equal,
            "LeftBracket": kVK_ANSI_LeftBracket, "RightBracket": kVK_ANSI_RightBracket,
            "Backslash": kVK_ANSI_Backslash, "Semicolon": kVK_ANSI_Semicolon, "Quote": kVK_ANSI_Quote,
            "Comma": kVK_ANSI_Comma, "Period": kVK_ANSI_Period, "Slash": kVK_ANSI_Slash,
        ]
        // 表的条目数与 5.5 节列出的键名一致：26 + 10 + 20 + 10 + 24。
        #expect(KeyCodeTable.entries.count == expected.count)
        for (name, code) in expected {
            #expect(KeyCodeTable.keyCode(for: name) == UInt16(code), "键名 \(name)")
            #expect(KeyCodeTable.name(for: UInt16(code)) == name, "键码 \(code)")
        }
        #expect(KeyCodeTable.name(for: UInt16(kVK_ContextualMenu)) == nil)
    }

    /// 键名查询不区分大小写；未知键名返回 nil。
    @Test func keyCodeLookup() {
        #expect(KeyCodeTable.keyCode(for: "pagedown") == UInt16(kVK_PageDown))
        #expect(KeyCodeTable.keyCode(for: "Key110") == nil)
        #expect(KeyCodeTable.isFunctionKey(UInt16(kVK_F20)) && !KeyCodeTable.isFunctionKey(UInt16(kVK_ANSI_A)))
        #expect(KeyCodeTable.isKeypadDigit(UInt16(kVK_ANSI_Keypad0)))
    }

    // MARK: - 鼠标触发键（反馈文档 6.1 节）

    /// Mouse3～Mouse32 全部往返，按钮号等于序号减 1。
    @Test(arguments: 3...32)
    func mouseRoundTrip(ordinal: Int) throws {
        let hotkey = try #require(Hotkey(string: "Mouse\(ordinal)"))
        #expect(hotkey.mouseButton == ordinal - 1)
        #expect(hotkey.keyCode == nil)
        #expect(hotkey.isMouse)
        #expect(hotkey.stringValue() == "Mouse\(ordinal)")
        #expect(Hotkey(string: hotkey.stringValue()) == hotkey)
    }

    /// 鼠标触发键不区分大小写，可以带修饰键，规范写法的修饰键顺序不变。
    @Test func mouseCaseAndModifiers() throws {
        #expect(Hotkey(string: "mouse4") == Hotkey(mouseButton: 3, modifiers: []))
        #expect(Hotkey(string: "MOUSE4") == Hotkey(mouseButton: 3, modifiers: []))
        let ctrl = try #require(Hotkey(string: "ctrl+Mouse4"))
        #expect(ctrl.modifiers == .control && ctrl.mouseButton == 3)
        let shift = try #require(Hotkey(string: " Shift + mouse5 "))
        #expect(shift.stringValue() == "shift+Mouse5")
        #expect(Hotkey(string: "cmd+shift+opt+ctrl+Mouse3")?.stringValue() == "ctrl+opt+shift+cmd+Mouse3")
    }

    /// 左键、右键、越界的序号与格式不对的写法解析失败。
    @Test(arguments: ["Mouse0", "Mouse1", "Mouse2", "Mouse33", "Mouse", "Mouse4x", "Mouse-4", "ctrl+Mouse",
                      "Mouse99999999999999999999", "Mouse４", "Mouse4+ctrl", "Mouse4@game"])
    func mouseInvalid(text: String) {
        #expect(Hotkey(string: text) == nil)
    }

    /// 鼠标热键的界面写法：修饰键符号加规范写法。
    @Test func mouseDisplayString() {
        #expect(Hotkey(string: "Mouse4")?.displayString() == "Mouse4")
        #expect(Hotkey(string: "ctrl+Mouse4")?.displayString() == "⌃Mouse4")
        #expect(Hotkey(string: "opt+shift+Mouse3")?.displayString() == "⌥⇧Mouse3")
    }

    /// 键盘热键的 keyCode 有值、isMouse 为假、mouseButton 为 nil。
    @Test func keyboardAccessors() {
        let hotkey = Hotkey(keyCode: 0x69, modifiers: [.control])
        #expect(hotkey.keyCode == 0x69)
        #expect(hotkey.mouseButton == nil)
        #expect(!hotkey.isMouse)
        #expect(hotkey.trigger == .key(0x69))
    }

    /// Hotkey(mouseButton:) 只接受 2～31。
    @Test func mouseButtonRange() {
        #expect(Hotkey(mouseButton: 0, modifiers: []) == nil)
        #expect(Hotkey(mouseButton: 1, modifiers: []) == nil)
        #expect(Hotkey(mouseButton: 32, modifiers: []) == nil)
        #expect(Hotkey(mouseButton: 2, modifiers: [])?.trigger == .mouseButton(2))
        #expect(Hotkey(mouseButton: 31, modifiers: [.shift])?.stringValue() == "shift+Mouse32")
        #expect(Hotkey.mouseButtonRange == 2...31)
    }

    /// 键盘热键与鼠标热键互不相等，即使数字相同。
    @Test func keyboardAndMouseDiffer() {
        #expect(Hotkey(trigger: .key(3), modifiers: []) != Hotkey(trigger: .mouseButton(3), modifiers: []))
    }
}
