// SPDX-License-Identifier: GPL-3.0-or-later
//
// `DiagnosticsService` 的真实实现（v1.1 设计 7.2 节、第 12 节）。只把各方法转给三个类型：
// `SystemInfoReader`（系统信息与本机名字）、`CrashReportLocator`（崩溃报告）、`ReportArchiver`（压缩包、访达与浏览器）。

import Foundation
import EVEOPreviewCore

/// 问题报告的平台服务。
public struct SystemDiagnosticsService: DiagnosticsService {
    /// 系统信息与本机名字。
    private let infoReader = SystemInfoReader()
    /// 崩溃报告目录。
    private let locator = CrashReportLocator()
    /// 压缩包与打开。
    private let archiver = ReportArchiver()

    /// 用默认目录建服务。
    public init() {}

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
