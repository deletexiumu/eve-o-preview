// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的更新部分（v1.1 设计 4.4 节、8.5 节）：配置变化时响应「自动检查更新」与「自动安装更新」开关。
// `general.checkForUpdates` 从假变真时立即按非启动时的间隔判断一次。
// 「自动安装更新」的开关不在这里处理：后台下载在下一次自动检查发现新版本时开始，
// 退出时是否安装由 `installOnQuitIfReady` 在退出那一刻读开关。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 配置变化时由 `configDidChange` 调用。
    func updateSettingsDidChange(old: AppConfig, new: AppConfig) {
        guard let updates else { return }
        if !old.general.checkForUpdates && new.general.checkForUpdates {
            updates.checkForUpdatesWasEnabled()
        }
    }
}
