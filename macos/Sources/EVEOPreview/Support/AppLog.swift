// SPDX-License-Identifier: GPL-3.0-or-later
//
// App 的日志入口（架构文档第 8 节约定，v1.1 设计 5.1 节）：category 取模块名。
// v1.1 起返回 Platform 的 `LogChannel`：方法名与 `os.Logger` 相同，调用处的写法不变，
// 日志同时交给系统日志与 `PlatformLog.install` 装上的输出目标（文件日志）。
// subsystem 固定为 bundle id（`PlatformLog.subsystem`），`swift run` 时也一样。

import Foundation
import EVEOPreviewPlatform

/// App 层的日志工厂。
enum AppLog {
    /// 发布包的 bundle id，与 `packaging/Info.plist` 一致。
    static let bundleID = PlatformLog.subsystem

    /// 按模块名建一个日志入口。
    ///
    /// - Parameter category: 模块名，如 `Coordinator`、`Thumbnails`。
    static func logger(_ category: String) -> LogChannel {
        PlatformLog.logger(category)
    }
}
