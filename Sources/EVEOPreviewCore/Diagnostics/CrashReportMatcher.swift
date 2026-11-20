// SPDX-License-Identifier: GPL-3.0-or-later
//
// 崩溃报告的匹配（v1.1 设计 6.2 节）。WP-0 只建签名齐全的骨架：`select` 返回空数组，
// 应用因此不会提示崩溃；规则由 WP-1 实现。WP-2 的手动报告也调 `select`，所以这里先定下签名。

import Foundation

/// 崩溃报告第一行（JSON 对象）里与匹配有关的键。
public struct CrashReportHeader: Sendable, Equatable {
    /// `bundleID` 键。
    public var bundleID: String?
    /// `app_name` 键。
    public var appName: String?
    /// `app_version` 键。
    public var appVersion: String?

    /// 用各字段建文件头。
    public init(bundleID: String?, appName: String?, appVersion: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.appVersion = appVersion
    }
}

/// 从崩溃报告目录的候选文件里选出属于本应用的报告。
public enum CrashReportMatcher {
    /// 一次最多取几个报告。
    public static let maxReports = 3
    /// 每个报告最多读多少字节。
    public static let maxReportBytes = 1_048_576

    /// 文件名是否像本应用的崩溃报告：以 `<可执行文件名>-` 或 `<可执行文件名>_` 开头，扩展名是 `ips` 或 `crash`。
    ///
    /// 骨架：总是返回 false（WP-1 实现）。
    public static func isCandidateName(_ fileName: String, executableName: String) -> Bool {
        false
    }

    /// 把文件的第一行当作 JSON 对象解析，取 `bundleID`、`app_name`、`app_version`；解析失败返回 nil。
    ///
    /// 骨架：总是返回 nil（WP-1 实现）。
    public static func header(fromFirstLine line: String) -> CrashReportHeader? {
        nil
    }

    /// 选出属于本应用、修改时间落在 window 里的报告，最新的在前，最多 maxReports 个。
    ///
    /// 骨架：总是返回空数组（WP-1 实现）。
    public static func select(from candidates: [CrashReportCandidate], executableName: String, bundleID: String,
                              window: ClosedRange<Date>) -> [CrashReportCandidate] {
        []
    }
}
