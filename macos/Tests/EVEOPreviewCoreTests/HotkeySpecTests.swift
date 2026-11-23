// SPDX-License-Identifier: GPL-3.0-or-later
//
// HotkeySpec 的用例（反馈文档 6.1 节、6.2 节、10.1 节）：作用范围后缀的解析、规范写法与已解析的作用范围。

import Testing
import EVEOPreviewCore

/// 热键字符串的作用范围后缀。
struct HotkeySpecTests {
    /// 没有后缀时 scope 为 nil，热键照常解析。
    @Test func noSuffix() throws {
        let spec = try #require(HotkeySpec(string: "ctrl+F13"))
        #expect(spec.scope == nil)
        #expect(spec.hotkey == Hotkey(string: "ctrl+F13"))
        #expect(spec.stringValue() == "ctrl+F13")
    }

    /// `@game`、`@global` 后缀；不区分大小写；`@` 两侧与各段的空白去掉。
    @Test func suffixes() {
        #expect(HotkeySpec(string: "ctrl+Mouse4@game")?.scope == .game)
        #expect(HotkeySpec(string: "F13@global")?.scope == .global)
        #expect(HotkeySpec(string: "F13@GAME")?.scope == .game)
        #expect(HotkeySpec(string: "F13@Global")?.scope == .global)
        let spaced = HotkeySpec(string: " ctrl + mouse4 @ Game ")
        #expect(spaced?.scope == .game)
        #expect(spaced?.hotkey == Hotkey(mouseButton: 3, modifiers: .control))
    }

    /// 非法写法：只有 `@`、后缀不认识、多个 `@`、`@` 前面为空或只有空白、后缀为空、热键部分不合法。
    @Test(arguments: ["@", "@foo", "F13@foo", "F13@game@global", "@game", " @global", "F13@", "F13@ ",
                      "Mouse1@game", "ctrl+@game", "F13@@game", ""])
    func invalid(text: String) {
        #expect(HotkeySpec(string: text) == nil)
    }

    /// 规范写法往返：修饰键顺序固定，触发键写成规范形式，作用范围紧跟在后。
    @Test(arguments: ["ctrl+Mouse4@game", "Mouse3", "F13@global", "ctrl+opt+shift+cmd+Mouse32@game",
                      "opt+Num1", "shift+Key110@global"])
    func roundTrip(text: String) throws {
        let spec = try #require(HotkeySpec(string: text))
        #expect(spec.stringValue() == text)
        #expect(HotkeySpec(string: spec.stringValue()) == spec)
    }

    /// 非规范的写法解析后输出规范写法。
    @Test func canonicalization() {
        #expect(HotkeySpec(string: "Shift+Ctrl+mouse5 @GAME")?.stringValue() == "ctrl+shift+Mouse5@game")
        #expect(HotkeySpec(string: "alt+f2")?.stringValue() == "opt+F2")
    }

    /// resolvedScope：有后缀时取后缀，没有时取配置方案的默认值。
    @Test func resolvedScope() {
        let hotkey = Hotkey(keyCode: 0x69, modifiers: [])
        #expect(HotkeySpec(hotkey: hotkey).resolvedScope(profileDefault: .game) == .game)
        #expect(HotkeySpec(hotkey: hotkey).resolvedScope(profileDefault: .global) == .global)
        #expect(HotkeySpec(hotkey: hotkey, scope: .global).resolvedScope(profileDefault: .game) == .global)
        #expect(HotkeySpec(hotkey: hotkey, scope: .game).resolvedScope(profileDefault: .global) == .game)
    }

    /// 只看热键时用 Hotkey(string:)：它不接受后缀。
    @Test func hotkeyRejectsSuffix() {
        #expect(Hotkey(string: "F13@game") == nil)
        #expect(HotkeySpec(string: "F13@game")?.hotkey == Hotkey(string: "F13"))
    }
}
