// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对排队与节流的测试（docs/design-intel-translate.md 6.10 节、14.1 节）。名字是编的。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct PilotLookupQueueTests {
    /// 排进 n 个名字。
    private func queue(_ names: [String], at now: Double = 0) -> PilotLookupQueue {
        var queue = PilotLookupQueue()
        queue.enqueue(names, now: now)
        return queue
    }

    /// 不足 0.5 秒时不取；两批之间隔 2 秒；nextAttempt 给出对应的时刻。
    @Test func debounceAndInterval() {
        var value = queue(["Kael Doran"])
        #expect(value.nextAttempt(now: 0) == 0.5)
        #expect(value.takeBatch(now: 0.4) == nil)
        #expect(value.takeBatch(now: 0.5) == ["Kael Doran"])
        #expect(value.status == .resolving)
        value.complete(PilotLookupAnswer(outcomes: [:]), now: 0.8)
        #expect(value.status == .idle)
        value.enqueue(["Mira Voss"], now: 1)
        #expect(value.nextAttempt(now: 1) == 2.5)
        #expect(value.takeBatch(now: 2) == nil)
        #expect(value.takeBatch(now: 2.5) == ["Mira Voss"])
    }

    /// 一批至多 500 个；有一批在途时不取，nextAttempt 是 nil。
    @Test func batchSizeAndInFlight() {
        var value = queue((0..<600).map { "Name\($0)" })
        #expect(value.takeBatch(now: 1)?.count == 500)
        #expect(value.takeBatch(now: 10) == nil)
        #expect(value.nextAttempt(now: 10) == nil)
        value.complete(PilotLookupAnswer(outcomes: [:]), now: 10)
        #expect(value.takeBatch(now: 10)?.count == 100)
        value.complete(PilotLookupAnswer(outcomes: [:]), now: 11)
        #expect(value.nextAttempt(now: 11) == nil)
    }

    /// 已在待查或在途的名字不重复排（按比较键）；超过 2,000 个时丢最早的。
    @Test func deduplicationAndCap() {
        var value = queue(["Kael Doran", "kael  doran"])
        #expect(value.pendingCount == 1)
        _ = value.takeBatch(now: 1)
        value.enqueue(["KAEL DORAN"], now: 1)
        #expect(value.pendingCount == 0)
        var big = queue((0..<2_005).map { "N\($0)" })
        #expect(big.pendingCount == PilotLookupQueue.maxPending)
        #expect(big.takeBatch(now: 1)?.first == "N5")
    }

    /// complete 在错误额度小于 20 时进入等待，秒数夹到 1～120，没有头时 60。
    @Test func lowErrorBudget() {
        var value = queue(["A1", "B2"])
        _ = value.takeBatch(now: 1)
        value.complete(PilotLookupAnswer(outcomes: [:], errorLimitRemain: 19, errorLimitReset: 500), now: 10)
        #expect(value.status == .waiting(until: 130))
        value.enqueue(["C3"], now: 10)
        #expect(value.takeBatch(now: 129) == nil)
        #expect(value.nextAttempt(now: 20) == 130)
        _ = value.takeBatch(now: 130)
        value.complete(PilotLookupAnswer(outcomes: [:], errorLimitRemain: 5), now: 131)
        #expect(value.status == .waiting(until: 191))
        _ = value.takeBatch(now: 191)
        value.complete(PilotLookupAnswer(outcomes: [:], errorLimitRemain: 20), now: 192)
        #expect(value.status == .idle)
    }

    /// rateLimited：回到待查，等 retryAfter 秒。
    @Test func rateLimitedRequeues() {
        var value = queue(["Kael Doran"])
        _ = value.takeBatch(now: 1)
        value.fail(.rateLimited(retryAfter: 45), now: 2)
        #expect(value.status == .waiting(until: 47))
        #expect(value.pendingCount == 1)
        #expect(value.takeBatch(now: 46) == nil)
        #expect(value.takeBatch(now: 47) == ["Kael Doran"])
    }

    /// network、server、malformedAnswer：回到待查，等 30 秒，连续失败时加倍，上限 600 秒；成功后清零。
    @Test func transientFailuresBackOff() {
        var value = queue(["Kael Doran"])
        var now = 1.0
        var waits: [Double] = []
        for failure in [PilotLookupFailure.network("x"), .server(status: 503), .malformedAnswer, .network("x"),
                        .network("x"), .network("x")] {
            #expect(value.takeBatch(now: now) != nil)
            value.fail(failure, now: now)
            guard case .waiting(let until) = value.status else {
                Issue.record("应当在等待")
                return
            }
            waits.append(until - now)
            now = until
        }
        #expect(waits == [30, 60, 120, 240, 480, 600])
        _ = value.takeBatch(now: now)
        value.complete(PilotLookupAnswer(outcomes: [:]), now: now)
        value.enqueue(["Mira Voss"], now: now)
        _ = value.takeBatch(now: now + 2)
        value.fail(.network("x"), now: now + 2)
        #expect(value.status == .waiting(until: now + 32))
    }

    /// rejected：这一批丢掉、不回到待查，等 300 秒。
    @Test func rejectedDropsBatch() {
        var value = queue(["Kael Doran"])
        _ = value.takeBatch(now: 1)
        value.fail(.rejected(status: 400), now: 2)
        #expect(value.pendingCount == 0)
        #expect(value.status == .waiting(until: 302))
        #expect(value.nextAttempt(now: 2) == nil)
        value.enqueue(["Mira Voss"], now: 3)
        #expect(value.nextAttempt(now: 3) == 302)
    }

    /// rejected 的名字 1 小时内不再排（补排不会把同一批反复发出）；过了 1 小时又能排；别的名字不受影响。
    @Test func rejectedNamesAreHeldBack() {
        var value = queue(["Kael Doran", "Tarn Vex"])
        _ = value.takeBatch(now: 1)
        value.fail(.rejected(status: 400), now: 2)
        value.enqueue(["kael doran", "Tarn Vex", "Mira Voss"], now: 10)
        #expect(value.pendingCount == 1)
        value.removeAll()
        value.enqueue(["Kael Doran"], now: 2 + 3_599)
        #expect(value.pendingCount == 0)
        value.enqueue(["Kael Doran"], now: 2 + 3_600)
        #expect(value.pendingCount == 1)
    }

    /// removeAll 清空待查与在途，保留等待的时刻。
    @Test func removeAllKeepsWait() {
        var value = queue(["Kael Doran"])
        _ = value.takeBatch(now: 1)
        value.fail(.rateLimited(retryAfter: 100), now: 1)
        value.removeAll()
        #expect(value.pendingCount == 0)
        #expect(value.status == .waiting(until: 101))
        value.enqueue(["Mira Voss"], now: 2)
        #expect(value.takeBatch(now: 50) == nil)
    }
}
