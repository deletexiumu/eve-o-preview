// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式（`EVEO_FAKE=1`）的问题报告服务（v1.1 设计第 12 节）。让报告窗口在任何机器上都能演示，含崩溃情境。
//
// - 系统信息是固定的样例，不读真实的 `sysctl`。
// - 崩溃报告：列出两个样例文件（日期在匹配窗口之外）；文件名以 `EVEOPreview-` 开头的报告都返回样例内容，
//   所以 `SessionTracker.sampleCrash` 的两个文件名（`EVEO_FAKE_CRASH=1`）也能预览。
//   样例内容含真实的主目录路径（JSON 转义写法）、主机名、假角色名与 `crashReporterKey`，预览里能看到每种脱敏。
// - 本机名字、压缩包、访达与浏览器转给真实的 `SystemDiagnosticsService`：演示模式与正式运行写同一个日志目录
//   （v1.1 设计 5.2 节），日志里有真实的主目录路径，脱敏要用真实的名字。
//   因此演示模式生成的 zip 也放在真实的 `Reports/` 目录里，参与「只保留最新 3 个」。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 演示模式的问题报告服务。
struct FakeDiagnosticsService: DiagnosticsService {
    /// 真实的服务：本机名字、压缩包、访达与浏览器。
    private let live = SystemDiagnosticsService()
    /// 样例崩溃报告的文件名前缀。
    static let samplePrefix = "EVEOPreview-"
    /// 样例里出现的假角色名（与 FakeServices 的假客户端一致）。
    static let sampleCharacter = "Fake Alpha"

    /// 固定的样例系统信息。
    func systemInfo() -> SystemInfo {
        SystemInfo(osVersion: "27.0", osBuild: "26A0000", architecture: "arm64", isTranslated: false,
                   hardwareModel: "Mac00,0", cpuBrand: "Apple M (demo)", physicalMemoryBytes: 17_179_869_184,
                   processorCount: 10, localeIdentifier: "en_US", preferredLanguages: ["en-US"])
    }

    /// 真实的本机名字，脱敏日志里的真实路径要用它。
    func sensitiveNames() -> SensitiveNames {
        live.sensitiveNames()
    }

    /// 两个样例报告，修改时间是 2020-01-01，落在任何匹配窗口之外：演示模式被强制结束后，
    /// 下次启动的扫描不会把它们当成崩溃报告而弹出提示；手动报告的 7 天窗口也不取它们。
    /// 崩溃情境的演示走 `EVEO_FAKE_CRASH=1`，它不经扫描，直接给出两个文件名，由 `readCrashReport` 返回样例内容。
    func crashReportCandidates(executableName: String) -> [CrashReportCandidate] {
        let old = Date(timeIntervalSince1970: 1_577_836_800)
        return [
            CrashReportCandidate(fileName: "\(executableName)-2020-01-01-000000.ips",
                                 modifiedAt: old, byteCount: 2048, firstLine: nil),
            CrashReportCandidate(fileName: "\(executableName)-2019-12-31-235900.ips",
                                 modifiedAt: old.addingTimeInterval(-60), byteCount: 2048, firstLine: nil),
        ]
    }

    /// 文件名以 `EVEOPreview-` 开头时返回样例内容，最多 maxBytes 字节；其余返回 nil。
    func readCrashReport(named fileName: String, maxBytes: Int) -> Data? {
        guard fileName.hasPrefix(FakeDiagnosticsService.samplePrefix) else { return nil }
        return Data(sampleReport(named: fileName).utf8.prefix(max(0, maxBytes)))
    }

    /// 转给真实服务：写进真实的 `Reports/` 目录。
    func writeArchive(named name: String, files: [DiagnosticsFile]) throws(DiagnosticsIOError) -> URL {
        try live.writeArchive(named: name, files: files)
    }

    /// 转给真实服务。
    @MainActor func revealInFinder(_ url: URL) {
        live.revealInFinder(url)
    }

    /// 转给真实服务。
    @MainActor func openInBrowser(_ url: URL) {
        live.openInBrowser(url)
    }

    /// 样例的 `.ips` 内容：第一行是 JSON 文件头，之后是 JSON 正文，路径按 `\/` 转义。
    private func sampleReport(named fileName: String) -> String {
        let names = live.sensitiveNames()
        let home = names.homeDirectory.replacingOccurrences(of: "/", with: "\\/")
        let host = names.hostNames.first ?? "demo-host"
        let header = #"{"app_name":"EVEOPreview","app_version":"1.1.0","bundleID":"io.github.deletexiumu.eveopreview-macos","#
            + #""name":"EVEOPreview","os_version":"macOS 27.0 (26A0000)","incident_id":"\#(fileName)"}"#
        let body = """
        {
          "uptime" : 3600,
          "procPath" : "\(home)\\/Applications\\/EVE-O Preview.app\\/Contents\\/MacOS\\/EVEOPreview",
          "crashReporterKey" : "0A1B2C3D-4E5F-6789-ABCD-EF0123456789",
          "deviceIdentifierForVendor" : "11111111-2222-3333-4444-555555555555",
          "machineName" : "\(host)",
          "userName" : "\(names.userName)",
          "lastWindowTitle" : "EVE - \(FakeDiagnosticsService.sampleCharacter)",
          "exception" : {"type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV"},
          "note" : "Sample crash report for demo mode. Not a real crash."
        }
        """
        return header + "\n" + body + "\n"
    }
}
