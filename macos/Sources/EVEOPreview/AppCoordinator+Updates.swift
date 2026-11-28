// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的更新部分（v1.1 设计 4.4 节、8.5 节）：配置变化时响应「自动检查更新」与「自动安装更新」开关。
// 开关变更后同步重算更新阶段；打开自动检查时按间隔判断是否立即检查，打开自动安装且已有可用更新时立即在后台下载。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 配置变化时由 `configDidChange` 调用。
    func updateSettingsDidChange(old: AppConfig, new: AppConfig) {
        guard let updates else { return }
        let checkChanged = old.general.checkForUpdates != new.general.checkForUpdates
        let autoInstallChanged = old.general.autoInstallUpdates != new.general.autoInstallUpdates
        if checkChanged || autoInstallChanged {
            updates.switchesDidChange(oldCheck: old.general.checkForUpdates,
                                      oldAutoInstall: old.general.autoInstallUpdates)
        }
    }
}
