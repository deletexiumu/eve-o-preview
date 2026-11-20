// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式（`EVEO_FAKE=1`）的问题报告服务（v1.1 设计第 12 节）。不读真实的系统信息与崩溃报告，
// 让报告窗口在任何机器上都能演示。
//
// WP-0 只建骨架：返回空的值，`writeArchive` 抛 `archiveFailed`，打开访达与浏览器不做事；WP-2 实现
// （包括为 `SessionTracker.sampleCrash` 的两个报告文件名返回假内容）。

import Foundation
import EVEOPreviewCore

/// 演示模式的问题报告服务。
struct FakeDiagnosticsService: DiagnosticsService {
    /// 骨架：返回各字段为空的系统信息（WP-2 实现）。
    func systemInfo() -> SystemInfo {
        SystemInfo(osVersion: "", osBuild: "", architecture: "", isTranslated: false, hardwareModel: "",
                   cpuBrand: "", physicalMemoryBytes: 0, processorCount: 0, localeIdentifier: "",
                   preferredLanguages: [])
    }

    /// 骨架：返回空的名字表（WP-2 实现）。
    func sensitiveNames() -> SensitiveNames {
        SensitiveNames(userName: "", fullUserName: "", homeDirectory: "", hostNames: [])
    }

    /// 骨架：返回空数组（WP-2 实现）。
    func crashReportCandidates(executableName: String) -> [CrashReportCandidate] {
        []
    }

    /// 骨架：返回 nil（WP-2 实现）。
    func readCrashReport(named fileName: String, maxBytes: Int) -> Data? {
        nil
    }

    /// 骨架：总是抛 `archiveFailed`（WP-2 实现）。
    func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL {
        throw .archiveFailed(reason: "尚未实现")
    }

    /// 骨架：不做事（WP-2 实现）。
    @MainActor func revealInFinder(_ url: URL) {}

    /// 骨架：不做事（WP-2 实现）。
    @MainActor func openInBrowser(_ url: URL) {}
}
