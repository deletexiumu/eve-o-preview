// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的更新部分（v1.1 设计 4.4 节、8.5 节）：配置变化时响应「自动检查更新」与「自动安装更新」开关。
// `general.checkForUpdates` 从假变真时立即按非启动时的间隔判断一次。
//
// WP-0 只建骨架：方法不做事；WP-3 实现。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 配置变化时由 `configDidChange` 调用。
    ///
    /// 骨架：不做事（WP-3 实现）。
    func updateSettingsDidChange(old: AppConfig, new: AppConfig) {}
}
