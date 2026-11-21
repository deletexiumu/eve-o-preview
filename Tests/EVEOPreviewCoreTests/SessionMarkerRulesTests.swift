// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionMarkerRules 的用例（v1.1 设计 6.1 节，14.1 节）：规则表的 4 行、编码后解码一致、损坏的数据返回 nil。

import Foundation
import Testing
import EVEOPreviewCore

/// 会话标记的编码与上一次运行的归类。
struct SessionMarkerRulesTests {
    /// 样例标记。时刻取整秒：编码只保留到秒。
    private func marker(endedCleanly: Bool, version: Int = 1) -> SessionMarker {
        SessionMarker(markerVersion: version, sessionID: "6F1D3C2A-0000-4000-8000-000000000001", pid: 4242,
                      appVersion: "1.1.0", buildLabel: "1.1.0-pr.12.abc1234",
                      startedAt: Date(timeIntervalSince1970: 1_795_233_906), endedCleanly: endedCleanly)
    }

    /// 规则表第 1 行：没有标记或版本不是 1 时是 noRecord，与进程是否还在无关。
    @Test func missingOrUnknownVersionIsNoRecord() {
        for alive in [false, true] {
            #expect(SessionMarkerRules.outcome(previous: nil, isPreviousProcessAlive: alive) == .noRecord)
            #expect(SessionMarkerRules.outcome(previous: marker(endedCleanly: false, version: 2),
                                               isPreviousProcessAlive: alive) == .noRecord)
            #expect(SessionMarkerRules.outcome(previous: marker(endedCleanly: true, version: 0),
                                               isPreviousProcessAlive: alive) == .noRecord)
        }
    }

    /// 规则表第 2 行：已正常结束时是 clean，与进程是否还在无关。
    @Test func endedCleanlyIsClean() {
        for alive in [false, true] {
            #expect(SessionMarkerRules.outcome(previous: marker(endedCleanly: true), isPreviousProcessAlive: alive) == .clean)
        }
    }

    /// 规则表第 3 行：没有正常结束、进程还在时是 stillRunning，带上那份标记。
    @Test func unfinishedAndAliveIsStillRunning() {
        let previous = marker(endedCleanly: false)
        #expect(SessionMarkerRules.outcome(previous: previous, isPreviousProcessAlive: true) == .stillRunning(previous))
    }

    /// 规则表第 4 行：没有正常结束、进程不在时是 abnormal，带上那份标记。
    @Test func unfinishedAndGoneIsAbnormal() {
        let previous = marker(endedCleanly: false)
        #expect(SessionMarkerRules.outcome(previous: previous, isPreviousProcessAlive: false) == .abnormal(previous))
    }

    /// 编码后解码一致；日期是 ISO 8601 字符串，键按字母排序。
    @Test func encodeDecodeRoundTrip() throws {
        for ended in [false, true] {
            let original = marker(endedCleanly: ended)
            let data = SessionMarkerRules.encode(original)
            #expect(SessionMarkerRules.decode(data) == original)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains(#""startedAt" : "2026-11-21T04:05:06Z""#))
            let keys = ["appVersion", "buildLabel", "endedCleanly", "markerVersion", "pid", "sessionID", "startedAt"]
            let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
            #expect(positions.count == keys.count)
            #expect(positions == positions.sorted())
        }
    }

    /// 版本不认识的标记仍能解码，由 outcome 归为 noRecord。
    @Test func unknownVersionStillDecodes() {
        let data = SessionMarkerRules.encode(marker(endedCleanly: false, version: 7))
        #expect(SessionMarkerRules.decode(data)?.markerVersion == 7)
    }

    /// 损坏或结构不符的数据返回 nil。
    @Test func corruptDataDecodesToNil() {
        #expect(SessionMarkerRules.decode(Data()) == nil)
        #expect(SessionMarkerRules.decode(Data("{ not json".utf8)) == nil)
        #expect(SessionMarkerRules.decode(Data("{}".utf8)) == nil)
        #expect(SessionMarkerRules.decode(Data("[1, 2]".utf8)) == nil)
        // 日期不是 ISO 8601 字符串。
        let wrongDate = #"{"appVersion":"1.1.0","buildLabel":"1.1.0","endedCleanly":false,"markerVersion":1,"pid":1,"sessionID":"x","startedAt":12345}"#
        #expect(SessionMarkerRules.decode(Data(wrongDate.utf8)) == nil)
        // 截断的文件（写到一半断电）。
        let full = SessionMarkerRules.encode(marker(endedCleanly: false))
        #expect(SessionMarkerRules.decode(full.prefix(full.count / 2)) == nil)
    }
}
