// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单栏菜单的更新部分（v1.1 设计 11.1 节）：
// - 顶部的提示项：「重新启动以更新到 <版本>」（`updateReady`）、「有可用更新：<版本>…」（`updateAvailable`）。
//   只在 `coordinator.attention` 里有对应的原因、且当前阶段带着发布信息时显示；版本号取自阶段。
// - 工具项：「检查更新…」，`capability` 是 `.unavailable` 时置灰。
// 菜单每次打开前重建（menuNeedsUpdate），这里每次按当时的状态返回新的菜单项。

import AppKit
import EVEOPreviewCore

extension StatusItemController {
    /// 菜单顶部的更新提示项，没有时返回空数组。
    func updateAttentionItems() -> [NSMenuItem] {
        guard let updates = coordinator.updates else { return [] }
        let attention = coordinator.attention
        var items: [NSMenuItem] = []
        // 已下载好、等用户退出或点这一项安装：点击后安装并重新启动（9.5 节）。
        if attention.contains(.updateReady), case .readyToInstall(let release) = updates.phase {
            items.append(ClosureMenuItem(L10n.updates.menuRestartToUpdate(release.version)) { [weak updates] in
                updates?.restartToInstall()
            })
        }
        // 有可用更新：点击后打开更新窗口，算用户发起，激活本应用。
        if attention.contains(.updateAvailable), let release = UpdateView.release(of: updates.phase) {
            items.append(ClosureMenuItem(L10n.updates.menuUpdateAvailable(release.version)) { [weak coordinator] in
                coordinator?.updateWindow?.show(userInitiated: true)
            })
        }
        return items
    }

    /// 「检查更新…」所在的工具项。更新功能整个停用（不是从 .app 运行）时置灰。
    func updateMenuItems() -> [NSMenuItem] {
        let isAvailable = coordinator.updates.map { $0.capability != .unavailable } ?? false
        return [ClosureMenuItem(L10n.updates.menuCheckForUpdates, isEnabled: isAvailable) { [weak coordinator] in
            coordinator?.updates?.checkNow(userInitiated: true)
        }]
    }
}
