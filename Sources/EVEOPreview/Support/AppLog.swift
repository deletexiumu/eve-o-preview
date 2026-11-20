// SPDX-License-Identifier: GPL-3.0-or-later
//
// App 的日志入口（架构文档第 8 节约定）：subsystem 取 bundle id，category 取模块名。
// 用 `swift run` 直接运行可执行文件时没有 bundle id，退回到固定的 bundle id 字符串。

import Foundation
import os

/// App 层的日志工厂。
enum AppLog {
    /// 发布包的 bundle id，与 `packaging/Info.plist` 一致。
    static let bundleID = "io.github.deletexiumu.eveopreview-macos"

    /// 日志的 subsystem：优先取运行时的 bundle id，没有时（`swift run`）取 `bundleID`。
    static let subsystem: String = Bundle.main.bundleIdentifier ?? bundleID

    /// 按模块名建一个 Logger。
    ///
    /// - Parameter category: 模块名，如 `Coordinator`、`Thumbnails`。
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
