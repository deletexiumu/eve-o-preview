// SPDX-License-Identifier: GPL-3.0-or-later
//
// 列出与读取系统的崩溃报告（v1.1 设计 6.2 节）。目录是 `~/Library/Logs/DiagnosticReports/` 及其 `Retired/` 子目录。
// WP-0 只建骨架：列出返回空数组，读取返回 nil；WP-1 实现。

import Foundation
import EVEOPreviewCore

/// 崩溃报告目录的读取。
struct CrashReportLocator: Sendable {
    /// 要查找的目录，按顺序。
    let directories: [URL]

    /// 默认目录：`~/Library/Logs/DiagnosticReports` 与它的 `Retired` 子目录。
    static func defaultDirectories() -> [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let reports = library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// 用目录列表建读取器，默认是系统的崩溃报告目录。
    init(directories: [URL] = CrashReportLocator.defaultDirectories()) {
        self.directories = directories
    }

    /// 文件名以 executableName 开头的报告，带修改时间、大小与第一行。
    ///
    /// 骨架：返回空数组（WP-1 实现）。
    func candidates(executableName: String) -> [CrashReportCandidate] {
        []
    }

    /// 读一个报告，最多 maxBytes 字节；找不到或读不了时返回 nil。
    ///
    /// 骨架：返回 nil（WP-1 实现）。
    func read(named fileName: String, maxBytes: Int) -> Data? {
        nil
    }
}
