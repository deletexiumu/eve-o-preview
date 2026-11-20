// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志的启动接入（v1.1 设计 4.4 节第 2、3 步，5.2、5.5 节）。
// `start` 在读配置之前调用，读配置的错误才能进文件：装上 `FileLogSink`、写一行会话头、装未捕获异常的处理函数。
// `apply(level:)` 在读完配置后与「详细日志」开关变化时调用，设置写进文件的最低级别。
//
// WP-0 只建骨架：两个方法都不做事，日志只写系统日志；WP-1 实现。
// 重复启动后自己退出的实例在 main.swift 里就已退出，不会走到这里。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 文件日志的启动与级别设置。
enum LogBootstrap {
    /// 装上文件日志（目录可由 `EVEO_LOG_DIR` 覆盖）、写会话头、装未捕获异常的处理函数。启动时调一次。
    ///
    /// 骨架：不做事（WP-1 实现）。
    static func start(environment: AppEnvironment, isFakeMode: Bool) {}

    /// 设置写进文件的最低级别（`general.logLevel`，只会是 info 或 debug）。系统日志不受影响。
    ///
    /// 骨架：不做事（WP-1 实现）。
    static func apply(level: LogLevel) {}
}
