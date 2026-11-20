// SPDX-License-Identifier: GPL-3.0-or-later
//
// CrashReportMatcher 的用例（v1.1 设计 6.2 节，14.1 节）：文件名的合法形式与反例、时间窗口的两个边界、
// 文件头的 bundle id 不同时排除、文件头解析失败时仍按文件名匹配、多于 3 个时取最新的 3 个。
//
// 文件头样例的来源：2026-11-21 在 macOS 27.0.1（26A434）上用一个临时程序制造崩溃，系统写下的真实报告（V17）。
// `probeHeader` 与 `unbundledHeader` 复制自真实报告的第一行，只把 `slice_uuid` 与 `incident_id` 换成全零的占位值；
// `eveoHeader` 是同一份第一行，再把应用名、版本与 bundle id 换成本应用的值。键、顺序与结构不变。临时程序与报告已删除。

import Foundation
import Testing
import EVEOPreviewCore

/// 崩溃报告的匹配。
struct CrashReportMatcherTests {
    /// 本应用的可执行文件名与 bundle id。
    private let executable = "EVEOPreview"
    private let bundleID = "io.github.deletexiumu.eveopreview-macos"

    /// 真实报告的第一行：放在 .app 里运行、被 Swift 运行时错误终止的临时程序（别的 bundle id）。
    private let probeHeader = #"{"app_name":"EVEOWP1Probe","timestamp":"2026-11-21 00:56:21.00 +0800","app_version":"9.8.7","slice_uuid":"00000000-0000-0000-0000-000000000000","build_version":"42","platform":1,"bundleID":"io.github.example.wp1crashprobe","share_with_app_devs":1,"is_first_party":0,"bug_type":"309","os_version":"macOS 27.0.1 (26A434)","roots_installed":0,"name":"EVEOWP1Probe","incident_id":"00000000-0000-0000-0000-000000000001"}"#
    /// 真实报告的第一行：不在 .app 里运行的同一个程序，没有 bundleID 键，app_version 是空串。
    private let unbundledHeader = #"{"app_name":"EVEOWP1Probe","timestamp":"2026-11-21 00:56:21.00 +0800","app_version":"","slice_uuid":"00000000-0000-0000-0000-000000000000","build_version":"","platform":1,"share_with_app_devs":1,"is_first_party":1,"bug_type":"309","os_version":"macOS 27.0.1 (26A434)","roots_installed":0,"incident_id":"00000000-0000-0000-0000-000000000002","name":"EVEOWP1Probe"}"#
    /// 本应用的第一行：结构同 probeHeader，值换成本应用的。
    private let eveoHeader = #"{"app_name":"EVEOPreview","timestamp":"2026-11-21 00:56:27.00 +0800","app_version":"1.1.0","slice_uuid":"00000000-0000-0000-0000-000000000000","build_version":"1.1.0","platform":1,"bundleID":"io.github.deletexiumu.eveopreview-macos","share_with_app_devs":1,"is_first_party":0,"bug_type":"309","os_version":"macOS 27.0.1 (26A434)","roots_installed":0,"name":"EVEOPreview","incident_id":"00000000-0000-0000-0000-000000000003"}"#

    /// 上一次运行开始的时刻与扫描的时刻。
    private let startedAt = Date(timeIntervalSince1970: 1_795_233_906)
    private var scannedAt: Date { startedAt.addingTimeInterval(3600) }

    /// 建一个候选文件。
    private func candidate(_ name: String, at date: Date, firstLine: String? = nil) -> CrashReportCandidate {
        CrashReportCandidate(fileName: name, modifiedAt: date, byteCount: 7380, firstLine: firstLine)
    }

    /// 用异常退出检测的窗口选。
    private func select(_ candidates: [CrashReportCandidate]) -> [String] {
        CrashReportMatcher.select(from: candidates, executableName: executable, bundleID: bundleID,
                                  window: CrashReportMatcher.window(startedAt: startedAt, scannedAt: scannedAt))
            .map(\.fileName)
    }

    // MARK: - 文件名

    /// 合法的 4 种形式：`-` 与 `_` 两种分隔符，`ips` 与 `crash` 两种扩展名；
    /// 另含实测的同一秒第二份报告的写法（`.000.ips`）与大写扩展名。
    @Test func acceptsValidNames() {
        let names = [
            "EVEOPreview-2026-11-21-005621.ips",
            "EVEOPreview_2026-11-21-005621.ips",
            "EVEOPreview-2026-11-21-005621.crash",
            "EVEOPreview_2026-11-21-005621_host.crash",
            "EVEOPreview-2026-11-21-005621.000.ips",
            "EVEOPreview-2026-11-21-005621.IPS",
        ]
        for name in names {
            #expect(CrashReportMatcher.isCandidateName(name, executableName: executable), "\(name)")
        }
    }

    /// 反例：别的应用、`.diag` 与别的扩展名、前缀相同但更长的名字、只有前缀、带目录、ExcUserFault 前缀。
    @Test func rejectsOtherNames() {
        let names = [
            "EVEOWP1Probe-2026-11-21-005621.ips",
            "Google Chrome-2026-11-19-094219.ips",
            "EVEOPreview-2026-11-21-005621.diag",
            "EVEOPreview-2026-11-21-005621.ips.txt",
            "EVEOPreview-2026-11-21-005621",
            "EVEOPreviewHelper-2026-11-21-005621.ips",
            "EVEOPreview2026-11-21-005621.ips",
            "EVEOPreview-.ips",
            "EVEOPreview.ips",
            "Retired/EVEOPreview-2026-11-21-005621.ips",
            "ExcUserFault_EVEOPreview-2026-11-21-005621.ips",
            "eveopreview-2026-11-21-005621.ips",
        ]
        for name in names {
            #expect(!CrashReportMatcher.isCandidateName(name, executableName: executable), "\(name)")
        }
        #expect(!CrashReportMatcher.isCandidateName("-x.ips", executableName: ""))
    }

    // MARK: - 文件头

    /// 真实的第一行能解析出 bundleID、app_name、app_version。
    @Test func parsesRealHeaders() {
        #expect(CrashReportMatcher.header(fromFirstLine: probeHeader)
                == CrashReportHeader(bundleID: "io.github.example.wp1crashprobe", appName: "EVEOWP1Probe", appVersion: "9.8.7"))
        #expect(CrashReportMatcher.header(fromFirstLine: unbundledHeader)
                == CrashReportHeader(bundleID: nil, appName: "EVEOWP1Probe", appVersion: ""))
        #expect(CrashReportMatcher.header(fromFirstLine: eveoHeader + "\n")?.bundleID == bundleID)
    }

    /// 不是 JSON 对象时返回 nil；键的类型不对时那个字段是 nil；空的 bundleID 当作没有。
    @Test func malformedHeaders() {
        #expect(CrashReportMatcher.header(fromFirstLine: "") == nil)
        #expect(CrashReportMatcher.header(fromFirstLine: "Process: EVEOPreview [4242]") == nil)
        #expect(CrashReportMatcher.header(fromFirstLine: #"["bundleID"]"#) == nil)
        #expect(CrashReportMatcher.header(fromFirstLine: String(probeHeader.prefix(80))) == nil)
        #expect(CrashReportMatcher.header(fromFirstLine: #"{"bundleID":42,"app_name":"EVEOPreview"}"#)
                == CrashReportHeader(bundleID: nil, appName: "EVEOPreview", appVersion: nil))
        #expect(CrashReportMatcher.header(fromFirstLine: #"{"bundleID":""}"#)?.bundleID == nil)
    }

    // MARK: - 时间窗口

    /// 窗口是开始前 5 秒到扫描后 5 秒，两端都含。
    @Test func windowBoundaries() {
        let early = candidate("EVEOPreview-a.ips", at: startedAt.addingTimeInterval(-5))
        let tooEarly = candidate("EVEOPreview-b.ips", at: startedAt.addingTimeInterval(-5.001))
        let late = candidate("EVEOPreview-c.ips", at: scannedAt.addingTimeInterval(5))
        let tooLate = candidate("EVEOPreview-d.ips", at: scannedAt.addingTimeInterval(5.001))
        #expect(select([early, tooEarly, late, tooLate]) == ["EVEOPreview-c.ips", "EVEOPreview-a.ips"])
    }

    /// 时钟被调回（开始时刻晚于扫描时刻）时不构造非法区间，窗口围绕扫描时刻。
    @Test func windowWithClockMovedBack() {
        let window = CrashReportMatcher.window(startedAt: scannedAt, scannedAt: startedAt)
        #expect(window.lowerBound == startedAt.addingTimeInterval(-5))
        #expect(window.upperBound == startedAt.addingTimeInterval(5))
    }

    // MARK: - 选择

    /// 文件头的 bundle id 是别的应用时排除；文件头是本应用、没有 bundleID、解析失败、读不到时都保留。
    @Test func headerExcludesOtherBundles() {
        let time = startedAt.addingTimeInterval(60)
        let candidates = [
            candidate("EVEOPreview-1.ips", at: time, firstLine: probeHeader),
            candidate("EVEOPreview-2.ips", at: time.addingTimeInterval(1), firstLine: eveoHeader),
            candidate("EVEOPreview-3.ips", at: time.addingTimeInterval(2), firstLine: unbundledHeader),
            candidate("EVEOPreview-4.crash", at: time.addingTimeInterval(3), firstLine: "Process: EVEOPreview [4242]"),
        ]
        #expect(select(candidates) == ["EVEOPreview-4.crash", "EVEOPreview-3.ips", "EVEOPreview-2.ips"])
        let unread = candidate("EVEOPreview-5.ips", at: time, firstLine: nil)
        #expect(select([unread]) == ["EVEOPreview-5.ips"])
    }

    /// 文件名不合格的候选即使时间与文件头都对也不选。
    @Test func nameIsRequired() {
        let wrongName = candidate("EVEOPreviewHelper-1.ips", at: startedAt.addingTimeInterval(1), firstLine: eveoHeader)
        #expect(select([wrongName]).isEmpty)
    }

    /// 多于 3 个时取最新的 3 个，最新的在前；结果与输入顺序无关，时间相同时按文件名从大到小。
    @Test func keepsNewestThree() {
        let base = startedAt.addingTimeInterval(10)
        let candidates = (0..<5).map { candidate("EVEOPreview-\($0).ips", at: base.addingTimeInterval(Double($0))) }
        let expected = ["EVEOPreview-4.ips", "EVEOPreview-3.ips", "EVEOPreview-2.ips"]
        #expect(select(candidates) == expected)
        #expect(select(candidates.reversed()) == expected)
        let tied = [candidate("EVEOPreview-a.ips", at: base), candidate("EVEOPreview-b.ips", at: base)]
        #expect(select(tied) == ["EVEOPreview-b.ips", "EVEOPreview-a.ips"])
        #expect(CrashReportMatcher.maxReports == 3)
    }

    /// 没有候选时返回空数组。
    @Test func emptyInput() {
        #expect(select([]).isEmpty)
    }
}
