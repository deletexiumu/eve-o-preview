// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的作用范围（反馈文档 6.1 节～6.3 节）。配置方案有默认值 hotkeyDefaultScope，
// 每条热键字符串可用后缀 @global、@game 单独指定（后缀的解析由 HotkeySpec 负责）。

import Foundation

/// 热键在什么情况下生效。
public enum HotkeyScope: String, Sendable, Codable, CaseIterable {
    /// 对所有应用生效。
    case global
    /// 只在前台是 EVE 客户端时生效；前台是本应用的设置窗口或其他应用时都不生效。
    case game
}
