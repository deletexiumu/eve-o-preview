// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置里一条热键字符串的解析结果（反馈文档 6.1 节、6.2 节）。
// 语法：热键字符串 = 热键 [ "@" 作用范围 ]，作用范围是 global 或 game，不区分大小写，`@` 两侧的空白去掉。
// 没有后缀表示跟随配置方案的 hotkeyDefaultScope。
// `@` 后面不是 global 或 game、有多个 `@`、`@` 前面为空，都解析失败。

import Foundation

/// 配置里一条热键字符串的解析结果。
public struct HotkeySpec: Sendable, Hashable {
    /// 热键（触发键加修饰键）。
    public var hotkey: Hotkey
    /// 作用范围；nil 表示跟随配置方案的默认值。
    public var scope: HotkeyScope?

    /// 用热键与作用范围建一条。
    public init(hotkey: Hotkey, scope: HotkeyScope? = nil) {
        self.hotkey = hotkey
        self.scope = scope
    }

    /// 解析一条热键字符串，如 `ctrl+Mouse4@game`、`F13`、`opt+F13 @ Global`。解析失败时返回 nil。
    public init?(string: String) {
        let parts = string.split(separator: "@", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let hotkey = Hotkey(string: string) else { return nil }
            self.init(hotkey: hotkey)
        case 2:
            // 后缀去掉空白后按小写匹配；前面的热键部分交给 Hotkey 解析（它自己去掉各段的空白）。
            let suffix = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard let scope = HotkeyScope(rawValue: suffix),
                  let hotkey = Hotkey(string: String(parts[0])) else { return nil }
            self.init(hotkey: hotkey, scope: scope)
        default:
            // 多个 `@`。
            return nil
        }
    }

    /// 规范写法：热键的规范写法，有作用范围时紧跟 `@global` 或 `@game`，如 `ctrl+Mouse4@game`。
    public func stringValue() -> String {
        guard let scope else { return hotkey.stringValue() }
        return hotkey.stringValue() + "@" + scope.rawValue
    }

    /// 已解析的作用范围：有后缀时取后缀，否则取配置方案的默认值。
    public func resolvedScope(profileDefault: HotkeyScope) -> HotkeyScope {
        scope ?? profileDefault
    }
}
