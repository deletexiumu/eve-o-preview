// SPDX-License-Identifier: GPL-3.0-or-later
//
// 历史回放过滤的用例（CombatLogReplayGuard，反馈文档 7.3 节）。
// 过滤只依赖日志行里的时间与调用方传入的接入时刻，不读系统时钟，所以用例里的时间全是固定值。

import Foundation
import Testing
import EVEOPreviewCore

struct CombatLogReplayGuardTests {
    /// 2026-11-20 12:34:56 UTC 的秒数（Python `calendar.timegm` 算出，不经过任何时区换算）。
    static let noon = 1_795_178_096.0

    /// 带指定时间的一行受到伤害。
    private func line(_ time: String) -> String {
        "[ \(time) ] (combat) <color=0xffcc0000><b>19</b> <color=0x77ffffff><font size=10>from</font> Sample Pilot"
    }

    /// 日志时间按 UTC 换算：固定的时间串对应固定的秒数，与本机时区无关。
    @Test func logTimeIsUTC() {
        #expect(CombatLogParser.logTime(line("2026.11.20 12:34:56")) == Self.noon)
    }

    /// 比接入时刻早很多的行丢弃，新写入的行保留。
    @Test func oldLineDroppedFreshLineKept() {
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.11.20 11:00:00"), attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.10.22 10:30:13"), attachedAt: Self.noon))
        #expect(CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:34:56"), attachedAt: Self.noon))
        // 接入之后才写的行（时间晚于接入时刻）保留。
        #expect(CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:35:30"), attachedAt: Self.noon))
    }

    /// 边界：正好等于「接入时刻减容差」的行保留，早 1 秒的丢弃；默认容差是 5 秒。
    @Test func boundaryIsInclusive() {
        #expect(CombatLogReplayGuard.tolerance == 5)
        #expect(CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:34:51"), attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:34:50"), attachedAt: Self.noon))
        // 容差由参数给出时按参数。
        #expect(CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:34:46"), attachedAt: Self.noon, tolerance: 10))
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:34:45"), attachedAt: Self.noon, tolerance: 10))
    }

    /// 容差覆盖 2 秒的保险定时器加 1 秒的时间戳粒度：接入前 3 秒写的行仍保留。
    @Test func toleranceCoversSafetyNetAndGranularity() {
        #expect(CombatLogReplayGuard.shouldKeep(line("2026.11.20 12:34:53"), attachedAt: Self.noon))
        #expect(CombatLogReplayGuard.tolerance > 2 + 1)
    }

    /// 时间解析不出来的行丢弃：不是日志行、时间形式不对、月份或时刻不合法。
    @Test func unparseableTimestampDropped() {
        #expect(!CombatLogReplayGuard.shouldKeep("not a log line", attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep("", attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.13.20 12:34:56"), attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.11.20 25:00:00"), attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep("[ 2026-11-20 12:34:56 ] (combat) x", attachedAt: Self.noon))
    }

    /// 用 UTC 而不是本地时间：接入时刻按 UTC 给出时，同一个时间串的新旧结论固定。
    /// 若误按本地时区换算，非 UTC 机器上结论会偏移整数小时，下面两条至少一条会失败。
    @Test func comparesAgainstUTCNotLocalTime() {
        let attached = Self.noon
        // 1 小时前的 UTC 时间串：不论本机时区，都是旧行。
        #expect(!CombatLogReplayGuard.shouldKeep(line("2026.11.20 11:34:56"), attachedAt: attached))
        // 1 小时后的 UTC 时间串：不论本机时区，都是新行。
        #expect(CombatLogReplayGuard.shouldKeep(line("2026.11.20 13:34:56"), attachedAt: attached))
    }

    /// 带 BOM 与 CRLF 的行照常判断。
    @Test func bomAndCarriageReturnTolerated() {
        #expect(CombatLogReplayGuard.shouldKeep("\u{FEFF}" + line("2026.11.20 12:34:56") + "\r", attachedAt: Self.noon))
        #expect(!CombatLogReplayGuard.shouldKeep("\u{FEFF}" + line("2026.11.20 10:00:00") + "\r", attachedAt: Self.noon))
    }
}
