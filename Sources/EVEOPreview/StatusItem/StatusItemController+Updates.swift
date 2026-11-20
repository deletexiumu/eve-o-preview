// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单栏菜单的更新部分（v1.1 设计 11.1 节）：
// - 顶部的提示项：「重新启动以更新到 <版本>」（`updateReady`）、「有可用更新：<版本>…」（`updateAvailable`）。
// - 工具项：「检查更新…」，`capability` 是 `.unavailable` 时置灰。
//
// WP-0 只建骨架：两个方法返回空数组；WP-4 实现。

import AppKit

extension StatusItemController {
    /// 菜单顶部的更新提示项，没有时返回空数组。
    ///
    /// 骨架：返回空数组（WP-4 实现）。
    func updateAttentionItems() -> [NSMenuItem] {
        []
    }

    /// 「检查更新…」所在的工具项。
    ///
    /// 骨架：返回空数组（WP-4 实现）。
    func updateMenuItems() -> [NSMenuItem] {
        []
    }
}
