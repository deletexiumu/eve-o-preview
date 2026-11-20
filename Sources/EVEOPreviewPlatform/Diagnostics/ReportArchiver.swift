// SPDX-License-Identifier: GPL-3.0-or-later
//
// 生成报告的压缩包，并在访达与浏览器里打开（v1.1 设计 7.2 节）。
// 做法：在 `~/Library/Application Support/EVE-O Preview/Reports/` 下建同名文件夹写入各文件，
// 用 `/usr/bin/ditto` 压缩（经 `ProcessRunner`），删掉文件夹，只保留最新的 3 个报告。
// WP-0 只建骨架：`writeArchive` 抛 `archiveFailed`，打开访达与浏览器不做事；WP-2 实现。

import AppKit
import EVEOPreviewCore

/// 报告压缩包的生成与打开。
struct ReportArchiver: Sendable {
    /// 存放报告的目录。
    let reportsDirectory: URL

    /// 默认目录：`~/Library/Application Support/EVE-O Preview/Reports`。
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EVE-O Preview/Reports", isDirectory: true)
    }

    /// 用存放目录建生成器，默认是 `defaultDirectory()`。
    init(reportsDirectory: URL = ReportArchiver.defaultDirectory()) {
        self.reportsDirectory = reportsDirectory
    }

    /// 把 files 写进以 name 命名的文件夹并压成 zip，返回 zip 的位置。
    ///
    /// 骨架：总是抛 `archiveFailed`（WP-2 实现）。
    func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL {
        throw .archiveFailed(reason: "尚未实现")
    }

    /// 在访达里显示并选中文件。
    ///
    /// 骨架：不做事（WP-2 实现）。
    @MainActor func revealInFinder(_ url: URL) {}

    /// 用默认浏览器打开地址。
    ///
    /// 骨架：不做事（WP-2 实现）。
    @MainActor func openInBrowser(_ url: URL) {}
}
