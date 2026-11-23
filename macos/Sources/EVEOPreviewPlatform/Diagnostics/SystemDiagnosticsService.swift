// SPDX-License-Identifier: GPL-3.0-or-later
//
// `DiagnosticsService` 的真实实现（v1.1 设计 7.2 节、第 12 节）。只把各方法转给三个类型：
// `SystemInfoReader`（系统信息与本机名字）、`CrashReportLocator`（崩溃报告）、`ReportArchiver`（压缩包、访达与浏览器）。
// 压缩包的存放目录可以另指：演示模式用 `Reports-fake/`，不与正式运行的报告混在一起（同 `*-fake.json` 的做法）。

import Foundation
import EVEOPreviewCore

/// 问题报告的平台服务。
public struct SystemDiagnosticsService: DiagnosticsService {
    /// 系统信息与本机名字。
    private let infoReader = SystemInfoReader()
    /// 崩溃报告目录。
    private let locator = CrashReportLocator()
    /// 压缩包与打开。
    private let archiver: ReportArchiver

    /// 报告的默认存放目录：`~/Library/Application Support/EVE-O Preview/Reports`；
    /// fake 为真（演示模式）时是同一级的 `Reports-fake`。
    public static func defaultReportsDirectory(fake: Bool = false) -> URL {
        let standard = ReportArchiver.defaultDirectory()
        guard fake else { return standard }
        return standard.deletingLastPathComponent().appendingPathComponent("Reports-fake", isDirectory: true)
    }

    /// 建服务。reportsDirectory 是压缩包的存放目录，默认是 `defaultReportsDirectory()`。
    public init(reportsDirectory: URL = SystemDiagnosticsService.defaultReportsDirectory()) {
        archiver = ReportArchiver(reportsDirectory: reportsDirectory)
    }

    public func systemInfo() -> SystemInfo {
        infoReader.systemInfo()
    }

    public func sensitiveNames() -> SensitiveNames {
        infoReader.sensitiveNames()
    }

    public func crashReportCandidates(executableName: String) -> [CrashReportCandidate] {
        locator.candidates(executableName: executableName)
    }

    public func readCrashReport(named fileName: String, maxBytes: Int) -> Data? {
        locator.read(named: fileName, maxBytes: maxBytes)
    }

    public func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL {
        try archiver.writeArchive(named: name, files: files)
    }

    @MainActor public func revealInFinder(_ url: URL) {
        archiver.revealInFinder(url)
    }

    @MainActor public func openInBrowser(_ url: URL) {
        archiver.openInBrowser(url)
    }
}
