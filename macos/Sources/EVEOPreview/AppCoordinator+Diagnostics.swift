// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的诊断部分（v1.1 设计 4.4 节、5.3 节）：配置变化时响应「详细日志」开关（`general.logLevel`），
// 改动立即生效（调 `LogBootstrap.apply(level:)`）。级别没变时什么也不做：`configDidChange` 每次改配置都会调到这里。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 配置变化时由 `configDidChange` 调用。`general.logLevel` 变了时应用新的文件日志级别。
    func diagnosticsSettingsDidChange(old: AppConfig, new: AppConfig) {
        guard old.general.logLevel != new.general.logLevel else { return }
        LogBootstrap.apply(level: new.general.logLevel)
    }
}
