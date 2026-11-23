// SPDX-License-Identifier: GPL-3.0-or-later
//
// 日志级别（v1.1 设计 5.1 节、5.3 节）。级别从低到高是 debug、info、notice、error、fault。
// 原始值是小写英文，同时用作配置文件 `general.logLevel` 的取值（3.1 节只接受 info 与 debug）。

import Foundation

/// 一条日志的级别。
///
/// 比较按声明顺序，不按原始值的字母顺序：按字母序 `error` 会排在 `info` 前面，
/// 那样设成 info 时 error 记录会被当成「低于下限」丢掉。
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    /// 排查问题时才看的细节。默认不写进文件。
    case debug
    /// 启动、退出、客户端增减、设置变化等。
    case info
    /// 不常见但不是错误的情况。
    case notice
    /// 操作失败，功能受影响。
    case error
    /// 程序自身的错误，如未捕获的异常。
    case fault

    /// 级别在 `allCases` 里的位置，越大越严重。
    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .error: return 3
        case .fault: return 4
        }
    }

    /// 按严重程度比较：`debug < info < notice < error < fault`。
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}
