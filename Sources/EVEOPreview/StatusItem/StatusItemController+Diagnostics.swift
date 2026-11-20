// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单栏菜单的诊断部分（v1.1 设计 11.1 节）：
// - 顶部的提示项：「EVE-O Preview 上次意外退出 — 报告…」（`crashPending`）。
// - 工具项：「报告问题…」。
//
// WP-0 只建骨架：两个方法返回空数组；WP-2 实现。

import AppKit

extension StatusItemController {
    /// 菜单顶部的诊断提示项，没有时返回空数组。
    ///
    /// 骨架：返回空数组（WP-2 实现）。
    func diagnosticsAttentionItems() -> [NSMenuItem] {
        []
    }

    /// 「报告问题…」所在的工具项。
    ///
    /// 骨架：返回空数组（WP-2 实现）。
    func diagnosticsMenuItems() -> [NSMenuItem] {
        []
    }
}
