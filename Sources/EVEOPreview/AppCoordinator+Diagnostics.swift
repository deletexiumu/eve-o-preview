// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的诊断部分（v1.1 设计 4.4 节、5.3 节）：配置变化时响应「详细日志」开关（`general.logLevel`），
// 改动立即生效（调 `LogBootstrap.apply(level:)`）。
//
// WP-0 只建骨架：方法不做事；WP-1 实现。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 配置变化时由 `configDidChange` 调用。`general.logLevel` 变了时应用新的文件日志级别。
    ///
    /// 骨架：不做事（WP-1 实现）。
    func diagnosticsSettingsDidChange(old: AppConfig, new: AppConfig) {}
}
