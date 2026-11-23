// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的契约（v1.1 设计 7.2 节）：系统信息、要脱敏的名字、压缩包里的文件与平台服务协议。
// 协议只含值类型；Platform 的实现是 `SystemDiagnosticsService`，演示模式是 `FakeDiagnosticsService`。

import Foundation

/// 报告里的系统信息（`summary.md` 与 Issue 正文用）。
public struct SystemInfo: Sendable, Equatable, Codable {
    /// macOS 版本，如 `27.0`。
    public var osVersion: String
    /// macOS 构建号。
    public var osBuild: String
    /// 进程的架构：`arm64` 或 `x86_64`。
    public var architecture: String
    /// 是否在 Rosetta 下运行。
    public var isTranslated: Bool
    /// `sysctl hw.model`。
    public var hardwareModel: String
    /// `sysctl machdep.cpu.brand_string`。
    public var cpuBrand: String
    /// 物理内存，单位是字节。
    public var physicalMemoryBytes: UInt64
    /// 处理器核数。
    public var processorCount: Int
    /// 系统的区域设置，如 `zh_CN`。
    public var localeIdentifier: String
    /// 系统的首选语言列表。
    public var preferredLanguages: [String]

    /// 用各字段建系统信息。
    public init(osVersion: String, osBuild: String, architecture: String, isTranslated: Bool,
                hardwareModel: String, cpuBrand: String, physicalMemoryBytes: UInt64, processorCount: Int,
                localeIdentifier: String, preferredLanguages: [String]) {
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.architecture = architecture
        self.isTranslated = isTranslated
        self.hardwareModel = hardwareModel
        self.cpuBrand = cpuBrand
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.localeIdentifier = localeIdentifier
        self.preferredLanguages = preferredLanguages
    }
}

/// 报告里要替换成占位符的本机名字（7.3 节）。
public struct SensitiveNames: Sendable, Equatable {
    /// 短用户名（`NSUserName()`）。
    public var userName: String
    /// 全名（`NSFullUserName()`）。
    public var fullUserName: String
    /// 主目录路径。
    public var homeDirectory: String
    /// 主机名与电脑名称。
    public var hostNames: [String]

    /// 用各字段建名字表。
    public init(userName: String, fullUserName: String, homeDirectory: String, hostNames: [String]) {
        self.userName = userName
        self.fullUserName = fullUserName
        self.homeDirectory = homeDirectory
        self.hostNames = hostNames
    }
}

/// 压缩包里的一个文件。
public struct DiagnosticsFile: Sendable, Equatable {
    /// 压缩包里的相对路径，如 `logs/eve-o-preview.log`。
    public var relativePath: String
    /// 已脱敏的内容。
    public var contents: Data

    /// 用各字段建文件。
    public init(relativePath: String, contents: Data) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

/// 生成报告时的文件错误。
public enum DiagnosticsIOError: Error, Sendable, Equatable {
    /// 写文件失败。
    case writeFailed(path: String, reason: String)
    /// 压缩失败。
    case archiveFailed(reason: String)
}

/// 问题报告的平台服务。除标了 `@MainActor` 的两个方法外，都可以在任何线程调用。
public protocol DiagnosticsService: Sendable {
    /// 读系统信息。
    func systemInfo() -> SystemInfo
    /// 读要脱敏的本机名字。
    func sensitiveNames() -> SensitiveNames
    /// ~/Library/Logs/DiagnosticReports（含 Retired 子目录）里文件名以可执行文件名开头的报告。
    func crashReportCandidates(executableName: String) -> [CrashReportCandidate]
    /// 读一个崩溃报告，最多 maxBytes 字节；读不到时返回 nil。
    func readCrashReport(named fileName: String, maxBytes: Int) -> Data?
    /// 把 files 写进一个以 name 命名的文件夹并压成 zip，返回 zip 的位置；同时只保留最近 3 个报告。
    func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL
    /// 在访达里显示并选中文件。
    @MainActor func revealInFinder(_ url: URL)
    /// 用默认浏览器打开地址。
    @MainActor func openInBrowser(_ url: URL)
}
