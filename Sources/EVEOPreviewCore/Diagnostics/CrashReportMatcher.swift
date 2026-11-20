// SPDX-License-Identifier: GPL-3.0-or-later
//
// 崩溃报告的匹配（v1.1 设计 6.2 节）。只在系统的崩溃报告目录里找到对应的报告，才认为上一次运行崩溃了。
//
// 规则：
// - 文件名以 `<可执行文件名>-` 或 `<可执行文件名>_` 开头，扩展名是 `ips` 或 `crash`。
// - 修改时间落在给定的时间窗口里。异常退出检测用 `window(startedAt:scannedAt:)`：
//   不早于上一次运行开始前 5 秒，不晚于扫描时刻后 5 秒。
// - 文件头（第一行的 JSON）解析成功、带 `bundleID` 且不等于本应用的 bundle id 时排除；
//   解析失败时仍按文件名与时间参与匹配。
// - 按修改时间从新到旧排序，取前 3 个。
//
// 2026-11-21 在 macOS 27.0.1 上用临时程序制造崩溃核对过（V17）：
// - 文件名是 `<进程名>-YYYY-MM-DD-HHMMSS.ips`（本地时间），同一秒的第二份是 `<进程名>-…-HHMMSS.000.ips`。
//   进程名就是可执行文件名，不是 `CFBundleName`。文件名里没有主机名。
// - 第一行是单行 JSON，键有 `app_name`、`app_version`、`bundleID`、`name`、`bug_type` 等；
//   `app_name` 与 `name` 也是可执行文件名。不在 .app 里运行的程序没有 `bundleID` 键，`app_version` 是空串。
// - 第二行起是多行 JSON，路径里的 `/` 写成 `\/`。

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
    /// 异常退出检测的时间窗口在两端各放宽的秒数：文件时间与进程时间可能差一点，系统写报告也要时间。
    public static let windowSlack: TimeInterval = 5
    /// 报告文件的扩展名，比较时不分大小写。
    private static let extensions: Set<String> = ["ips", "crash"]

    /// 文件名是否像本应用的崩溃报告：以 `<可执行文件名>-` 或 `<可执行文件名>_` 开头，扩展名是 `ips` 或 `crash`。
    ///
    /// 前缀之后到扩展名之前至少要有一个字符。`EVEOPreviewHelper-…` 这类前缀相同但更长的名字不算。
    public static func isCandidateName(_ fileName: String, executableName: String) -> Bool {
        guard !executableName.isEmpty, !fileName.contains("/") else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { return false }
        let minimumLength = executableName.count + 1 + 1 + ext.count + 1   // 名字、分隔符、至少一个字符、点、扩展名
        guard fileName.count >= minimumLength else { return false }
        return fileName.hasPrefix(executableName + "-") || fileName.hasPrefix(executableName + "_")
    }

    /// 把文件的第一行当作 JSON 对象解析，取 `bundleID`、`app_name`、`app_version`；解析失败返回 nil。
    ///
    /// 键不存在或不是字符串时对应的字段是 nil。`bundleID` 是空串时也当作没有。
    public static func header(fromFirstLine line: String) -> CrashReportHeader? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let dictionary = object as? [String: Any] else { return nil }
        let bundleID = (dictionary["bundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CrashReportHeader(bundleID: bundleID, appName: dictionary["app_name"] as? String,
                                 appVersion: dictionary["app_version"] as? String)
    }

    /// 异常退出检测用的时间窗口：`startedAt` 前 5 秒到 `scannedAt` 后 5 秒。
    ///
    /// 时钟被调回、`startedAt` 晚于 `scannedAt` 时，窗口取以 `scannedAt` 为中心的 10 秒，不会构造出非法区间。
    public static func window(startedAt: Date, scannedAt: Date) -> ClosedRange<Date> {
        let upper = scannedAt.addingTimeInterval(windowSlack)
        let lower = min(startedAt.addingTimeInterval(-windowSlack), scannedAt.addingTimeInterval(-windowSlack))
        return lower...upper
    }

    /// 选出属于本应用、修改时间落在 window 里的报告，最新的在前，最多 maxReports 个。
    ///
    /// 修改时间相同时按文件名从大到小排，结果与输入顺序无关。
    public static func select(from candidates: [CrashReportCandidate], executableName: String, bundleID: String,
                              window: ClosedRange<Date>) -> [CrashReportCandidate] {
        let matched = candidates.filter { candidate in
            guard isCandidateName(candidate.fileName, executableName: executableName),
                  window.contains(candidate.modifiedAt) else { return false }
            // 文件头说明是别的应用时排除；读不到或解析不了文件头时只看文件名与时间。
            if let line = candidate.firstLine, let reported = header(fromFirstLine: line)?.bundleID,
               reported != bundleID {
                return false
            }
            return true
        }
        let sorted = matched.sorted { lhs, rhs in
            lhs.modifiedAt != rhs.modifiedAt ? lhs.modifiedAt > rhs.modifiedAt : lhs.fileName > rhs.fileName
        }
        return Array(sorted.prefix(maxReports))
    }
}
