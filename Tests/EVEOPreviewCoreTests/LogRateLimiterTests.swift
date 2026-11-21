// SPDX-License-Identifier: GPL-3.0-or-later
//
// LogRateLimiter 的用例（v1.1 设计 5.2 节，14.1 节）：容量内全部放行、桶空后丢弃、
// 补充后第一条带丢弃计数、时间不前进时不补充。

import Testing
import EVEOPreviewCore

/// 令牌桶限速。
struct LogRateLimiterTests {
    /// 默认容量 200：同一时刻的前 200 条全部放行，第 201 条丢弃。
    @Test func defaultCapacityAdmitsTwoHundred() {
        var limiter = LogRateLimiter()
        let results = (0..<200).map { _ in limiter.admit(at: 10) }
        #expect(results.allSatisfy { $0 == .write })
        #expect(limiter.admit(at: 10) == .drop)
    }

    /// 桶空后一直丢弃，直到补充；补充后第一条带丢弃的条数，之后恢复普通放行。
    @Test func firstAdmissionAfterRefillReportsDroppedCount() {
        var limiter = LogRateLimiter(capacity: 2, refillPerSecond: 1)
        #expect(limiter.admit(at: 0) == .write)
        #expect(limiter.admit(at: 0) == .write)
        #expect(limiter.admit(at: 0.1) == .drop)
        #expect(limiter.admit(at: 0.5) == .drop)
        #expect(limiter.admit(at: 0.9) == .drop)
        // 1 秒补 1 条。
        #expect(limiter.admit(at: 1.0) == .writeAfterDropping(3))
        #expect(limiter.admit(at: 1.0) == .drop)
        #expect(limiter.admit(at: 2.0) == .writeAfterDropping(1))
        #expect(limiter.admit(at: 3.0) == .write)
    }

    /// 时间不前进或倒退时不补充。
    @Test func noRefillWithoutTimeAdvancing() {
        var limiter = LogRateLimiter(capacity: 1, refillPerSecond: 50)
        #expect(limiter.admit(at: 5) == .write)
        #expect(limiter.admit(at: 5) == .drop)
        #expect(limiter.admit(at: 4) == .drop)
        #expect(limiter.admit(at: 5) == .drop)
        // 从最后一次补充的时刻（5 秒）算起，过 0.1 秒补 5 条。
        #expect(limiter.admit(at: 5.1) == .writeAfterDropping(3))
    }

    /// 补充不超过容量：长时间空闲后也只能连续放行 capacity 条。
    @Test func refillIsCappedAtCapacity() {
        var limiter = LogRateLimiter(capacity: 3, refillPerSecond: 50)
        #expect(limiter.admit(at: 0) == .write)
        let later = (0..<4).map { _ in limiter.admit(at: 1000) }
        #expect(later == [.write, .write, .write, .drop])
    }

    /// 持续超速时，放行的速率等于补充的速率。
    @Test func sustainedRateMatchesRefill() {
        var limiter = LogRateLimiter(capacity: 200, refillPerSecond: 50)
        var written = 0
        // 10 秒内每 1 毫秒一条，共 10,000 条。
        for step in 0..<10_000 {
            if limiter.admit(at: Double(step) / 1000) != .drop { written += 1 }
        }
        // 开始的 200 条加上 10 秒补的约 500 条（浮点累加的误差允许差 2 条）。
        #expect((698...700).contains(written))
    }
}
