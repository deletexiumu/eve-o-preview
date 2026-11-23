// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的队列（docs/macos/design-intel-translate.md 7.6 节，14.1 节 TranslationQueueTests）：进入队列不足 1 秒时不取；
// 同一时刻只有一批在途；complete 把相同原文的消息一并完成；3 类失败各自的状态与消息阶段；waiting 到时后可再取；
// 连续失败时等待时长加倍且有上限；reset；activate 只排最近 600 秒内的最新 20 条；nextAttempt 的各种结果。
// 另有：只取活动角色的消息、旧请求的结果、清空缓冲不解除暂停。收听者名是虚构的。

import Testing
import Foundation
import EVEOPreviewCore

/// 翻译的队列。
struct TranslationQueueTests {
    /// 起始时刻（墙上时钟）。
    let t0 = 1_000_000.0
    /// 活动角色。
    let alpha = "Pilot Alpha"

    /// 放入几条 pending 的消息并激活 alpha，返回队列与编号。
    func queue(_ texts: [String], at now: Double? = nil) -> (TranslationQueue, [UInt64]) {
        var queue = TranslationQueue()
        let time = now ?? t0
        queue.activate(listener: alpha, now: time)
        let ids = texts.map { queue.append(trMessage($0, listener: alpha, time: time), phase: .pending, now: time) }
        return (queue, ids)
    }

    /// 取一批；没有时记一次失败并抛出（#require 不能包住会修改值的调用）。
    func take(_ queue: inout TranslationQueue, _ now: Double) throws -> [TranslationItem] {
        let batch = queue.takeBatch(now: now)
        return try #require(batch)
    }

    /// alpha 的各条阶段。
    func phases(_ queue: TranslationQueue) -> [TranslationPhase] {
        queue.items(for: alpha).map(\.phase)
    }

    /// 进入队列不足 1 秒时不取，满 1 秒后取。
    @Test func debounce() throws {
        var (queue, _) = queue(["hello"])
        #expect(queue.takeBatch(now: t0 + 0.5) == nil)
        let batch = try take(&queue, t0 + 1)
        #expect(batch.count == 1 && batch[0].phase == .inFlight)
        #expect(queue.status == .translating)
        #expect(phases(queue) == [.inFlight])
    }

    /// 同一时刻只有一批在途。
    @Test func singleBatchInFlight() {
        var (queue, _) = queue(["one"])
        #expect(queue.takeBatch(now: t0 + 2) != nil)
        queue.append(trMessage("two", listener: alpha), phase: .pending, now: t0 + 2)
        #expect(queue.takeBatch(now: t0 + 10) == nil)
        #expect(queue.hasBatchInFlight)
    }

    /// complete：有结果的 done，没有结果的 failed，缓存键相同的 pending 消息一并 done，状态回到 idle。
    @Test func completeFillsDuplicates() throws {
        var (queue, ids) = queue(["hello there", "hello  there*", "other"])
        let batch = try take(&queue, t0 + 1)
        #expect(batch.map(\.id) == [ids[0], ids[2]])
        queue.complete([ids[0]: TranslatedText(text: "你好", sourceLanguage: "en")], batch: batch)
        #expect(phases(queue) == [.done(text: "你好", sourceLanguage: "en"), .done(text: "你好", sourceLanguage: "en"),
                                  .failed])
        #expect(queue.status == .idle && !queue.hasBatchInFlight)
    }

    /// 致命的失败：这一批回到 pending，状态 blocked，之后不再取。
    @Test func fatalFailureBlocks() throws {
        var (queue, _) = queue(["hello"])
        let batch = try take(&queue, t0 + 1)
        queue.fail(.unauthorized(status: 401), batch: batch, now: t0 + 2)
        #expect(queue.status == .blocked(.unauthorized(status: 401)))
        #expect(phases(queue) == [.pending])
        #expect(queue.takeBatch(now: t0 + 100) == nil)
        #expect(queue.nextAttempt(now: t0 + 100) == nil)
    }

    /// 发请求之前的失败（batch 为空）也让队列进入 blocked。
    @Test func preSendFailureBlocks() {
        var (queue, _) = queue(["hello"])
        queue.fail(.missingKey, batch: [], now: t0)
        #expect(queue.status == .blocked(.missingKey))
        #expect(phases(queue) == [.pending])
    }

    /// 临时故障：回到 pending，waiting 到时刻；到时后可再取。
    @Test func temporaryFailureWaitsThenRetries() throws {
        var (queue, _) = queue(["hello"])
        let first = try take(&queue, t0 + 1)
        queue.fail(.rateLimited(retryAfter: 12), batch: first, now: t0 + 2)
        #expect(queue.status == .waiting(until: t0 + 14, reason: .rateLimited(retryAfter: 12)))
        #expect(phases(queue) == [.pending])
        #expect(queue.takeBatch(now: t0 + 13) == nil)
        #expect(queue.nextAttempt(now: t0 + 3) == t0 + 14)
        #expect(queue.takeBatch(now: t0 + 14) != nil)
        #expect(queue.status == .translating)
    }

    /// 只影响这一批的失败：这一批 failed，状态回到 idle，后面的消息照常处理。
    @Test func batchOnlyFailure() throws {
        var (queue, _) = queue(["hello"])
        let batch = try take(&queue, t0 + 1)
        queue.fail(.malformedAnswer, batch: batch, now: t0 + 2)
        #expect(queue.status == .idle)
        #expect(phases(queue) == [.failed])
        queue.append(trMessage("next", listener: alpha), phase: .pending, now: t0 + 3)
        #expect(queue.takeBatch(now: t0 + 4)?.count == 1)
    }

    /// 服务出错与网络失败：30、60、120、240、300、300 秒；成功后计数清零。429 不参与加倍。
    @Test func backoffDoublesWithCap() throws {
        var (queue, _) = queue(["hello"])
        var now = t0 + 1
        var waits: [Double] = []
        for index in 0..<6 {
            let batch = try take(&queue, now)
            let failure: TranslationFailure = index % 2 == 0 ? .server(status: 503) : .network("URLError -1001")
            queue.fail(failure, batch: batch, now: now)
            guard case .waiting(let until, _) = queue.status else { Issue.record("not waiting"); return }
            waits.append(until - now)
            now = until
        }
        #expect(waits == [30, 60, 120, 240, 300, 300])
        let rateLimited = try take(&queue, now)
        queue.fail(.rateLimited(retryAfter: 7), batch: rateLimited, now: now)
        #expect(queue.status == .waiting(until: now + 7, reason: .rateLimited(retryAfter: 7)))
        now += 7
        let ok = try take(&queue, now)
        queue.complete([ok[0].id: TranslatedText(text: "x", sourceLanguage: nil)], batch: ok)
        queue.append(trMessage("again", listener: alpha), phase: .pending, now: now)
        let next = try take(&queue, now + 1)
        queue.fail(.server(status: 500), batch: next, now: now + 1)
        #expect(queue.status == .waiting(until: now + 31, reason: .server(status: 500)))
    }

    /// reset：状态回到 idle，在途与最近 600 秒内 failed 的消息回到 pending，更早的 failed 不动。
    @Test func resetRequeues() throws {
        var queue = TranslationQueue()
        queue.activate(listener: alpha, now: t0)
        queue.append(trMessage("old", listener: alpha, time: t0 - 700), phase: .failed, now: t0)
        queue.append(trMessage("recent", listener: alpha, time: t0 - 10), phase: .failed, now: t0)
        queue.append(trMessage("sending", listener: alpha, time: t0), phase: .pending, now: t0)
        let batch = try take(&queue, t0 + 1)
        queue.fail(.unauthorized(status: 401), batch: batch, now: t0 + 1)
        queue.reset(now: t0 + 5)
        #expect(queue.status == .idle)
        #expect(phases(queue) == [.failed, .pending, .pending])
        // 「sending」在 t0 + 1 回到 pending，是最早的一条。
        #expect(queue.nextAttempt(now: t0 + 5) == t0 + 2)
    }

    /// activate 只把最近 600 秒内的最新 20 条里 off 的改成 pending；重复调用不排更多。
    @Test func activateQueuesRecentOnly() {
        var queue = TranslationQueue()
        // 5 条太旧，25 条在 600 秒内，其中 1 条已翻译。
        for index in 0..<5 {
            queue.append(trMessage("stale \(index)", listener: alpha, time: t0 - 900), phase: .off, now: t0)
        }
        for index in 0..<25 {
            let phase: TranslationPhase = index == 24 ? .done(text: "x", sourceLanguage: nil) : .off
            queue.append(trMessage("recent \(index)", listener: alpha, time: t0 - 100 + Double(index)), phase: phase,
                         now: t0)
        }
        queue.activate(listener: alpha, now: t0)
        let pending = phases(queue).filter { $0 == .pending }.count
        #expect(pending == 19)
        #expect(Array(phases(queue).prefix(10)).allSatisfy { $0 == .off })
        queue.activate(listener: alpha, now: t0 + 1)
        #expect(phases(queue).filter { $0 == .pending }.count == 19)
        #expect(queue.activeListener == alpha)
    }

    /// 只取活动角色的消息：别的收听者的 pending 留在缓冲里，切换后才发。收听者不区分大小写匹配。
    @Test func onlyActiveListenerIsSent() throws {
        var queue = TranslationQueue()
        queue.activate(listener: alpha, now: t0)
        queue.append(trMessage("for beta", listener: "Pilot Beta"), phase: .pending, now: t0)
        #expect(queue.takeBatch(now: t0 + 5) == nil)
        #expect(queue.nextAttempt(now: t0 + 5) == nil)
        queue.activate(listener: "pilot beta", now: t0 + 5)
        #expect(try take(&queue, t0 + 5).map(\.message.text) == ["for beta"])
        #expect(queue.items(for: "PILOT BETA").count == 1)
    }

    /// nextAttempt：没有待办为 nil；有 pending 时是最早进入时刻加 1 秒；有一批在途时为 nil。
    @Test func nextAttemptCases() throws {
        var queue = TranslationQueue()
        #expect(queue.nextAttempt(now: t0) == nil)
        queue.activate(listener: alpha, now: t0)
        queue.append(trMessage("a", listener: alpha), phase: .off, now: t0)
        #expect(queue.nextAttempt(now: t0) == nil)
        queue.append(trMessage("b", listener: alpha), phase: .pending, now: t0 + 2)
        #expect(queue.nextAttempt(now: t0 + 2) == t0 + 3)
        _ = try take(&queue, t0 + 3)
        #expect(queue.nextAttempt(now: t0 + 3) == nil)
    }

    /// 答复被截断：多条的一批放回 pending，下一批取一半；只剩 1 条再被截断时改成 failed。成功后上限加倍。
    @Test func truncatedBatchIsSplit() throws {
        var (queue, ids) = queue((0..<8).map { "line \($0)" })
        let full = try take(&queue, t0 + 1)
        #expect(full.count == 8)
        queue.fail(.truncated, batch: full, now: t0 + 2)
        #expect(queue.status == .idle && !queue.hasBatchInFlight)
        #expect(phases(queue).allSatisfy { $0 == .pending })
        #expect(queue.batchLimit == 4)
        let half = try take(&queue, t0 + 3)
        #expect(half.map(\.id) == Array(ids.prefix(4)))
        queue.fail(.truncated, batch: half, now: t0 + 4)
        #expect(queue.batchLimit == 2)
        let quarter = try take(&queue, t0 + 5)
        queue.complete(Dictionary(uniqueKeysWithValues: quarter.map { ($0.id, TranslatedText(text: "ok", sourceLanguage: nil)) }),
                       batch: quarter)
        #expect(queue.batchLimit == 4)
        // 只有 1 条的一批被截断：这一条 failed。
        var (single, _) = self.queue(["very long line"])
        let one = try take(&single, t0 + 1)
        single.fail(.truncated, batch: one, now: t0 + 2)
        #expect(phases(single) == [.failed])
        // reset 把上限恢复成 20。
        queue.reset(now: t0 + 6)
        #expect(queue.batchLimit == TranslationRules.maxBatchMessages)
    }

    /// 429 没有给秒数：30、60、120……秒，上限 600 秒；给了秒数时照用、不加倍；成功后计数清零。
    @Test func rateLimitWithoutRetryAfterBacksOff() throws {
        var (queue, _) = queue(["hello"])
        var now = t0 + 1
        var waits: [Double] = []
        for _ in 0..<7 {
            let batch = try take(&queue, now)
            queue.fail(.rateLimited(retryAfter: nil), batch: batch, now: now)
            guard case .waiting(let until, _) = queue.status else { Issue.record("not waiting"); return }
            waits.append(until - now)
            now = until
        }
        #expect(waits == [30, 60, 120, 240, 480, 600, 600])
        let explicit = try take(&queue, now)
        queue.fail(.rateLimited(retryAfter: 9), batch: explicit, now: now)
        #expect(queue.status == .waiting(until: now + 9, reason: .rateLimited(retryAfter: 9)))
        now += 9
        let ok = try take(&queue, now)
        queue.complete([ok[0].id: TranslatedText(text: "x", sourceLanguage: nil)], batch: ok)
        queue.append(trMessage("again", listener: alpha), phase: .pending, now: now)
        let next = try take(&queue, now + 1)
        queue.fail(.rateLimited(retryAfter: nil), batch: next, now: now + 1)
        #expect(queue.status == .waiting(until: now + 31, reason: .rateLimited(retryAfter: nil)))
    }

    /// 等待中而没有 pending 的消息（清空了列表、或没有活动角色）：nextAttempt 是等待结束的时刻，
    /// 到时 takeBatch 把状态改回 idle，不停在 waiting。
    @Test func waitingExpiresWithoutPending() throws {
        var (queue, _) = queue(["hello"])
        let batch = try take(&queue, t0 + 1)
        queue.fail(.server(status: 503), batch: batch, now: t0 + 2)
        queue.removeItems(listener: nil)
        #expect(queue.nextAttempt(now: t0 + 3) == t0 + 32)
        #expect(queue.takeBatch(now: t0 + 32) == nil)
        #expect(queue.status == .idle)
        #expect(queue.nextAttempt(now: t0 + 33) == nil)
        // 没有活动角色时同样到时恢复。
        var (other, _) = self.queue(["hi"])
        let first = try take(&other, t0 + 1)
        other.fail(.network("offline"), batch: first, now: t0 + 2)
        other.activate(listener: nil, now: t0 + 2)
        #expect(other.nextAttempt(now: t0 + 2) == t0 + 32)
        _ = other.takeBatch(now: t0 + 32)
        #expect(other.status == .idle)
    }

    /// complete 带目标语言时，模型原样抄回的结果是 sameLanguage，其余是 done；同缓存键的副本一并处理。
    @Test func completeWithTargetMarksEcho() throws {
        var (queue, ids) = queue(["Jita gate camp", "Jita  gate camp*", "hostiles"])
        let batch = try take(&queue, t0 + 1)
        queue.complete([ids[0]: TranslatedText(text: "Jita gate camp", sourceLanguage: "en"),
                        ids[2]: TranslatedText(text: "敌对", sourceLanguage: "en")], batch: batch, target: .zh)
        #expect(phases(queue) == [.skipped(.sameLanguage, rendered: nil), .skipped(.sameLanguage, rendered: nil),
                                  .done(text: "敌对", sourceLanguage: "en")])
    }

    /// 旧请求的结果：reset 后才到，填上仍在等的消息，但不改状态、不把别的改成 failed；旧的失败被忽略。
    @Test func staleResultsAfterReset() throws {
        var (queue, ids) = queue(["one", "two"])
        let batch = try take(&queue, t0 + 1)
        queue.reset(now: t0 + 2)
        queue.fail(.server(status: 500), batch: batch, now: t0 + 2)
        #expect(queue.status == .idle)
        queue.complete([ids[0]: TranslatedText(text: "壹", sourceLanguage: nil)], batch: batch)
        #expect(phases(queue) == [.done(text: "壹", sourceLanguage: nil), .pending])
        #expect(queue.status == .idle && !queue.hasBatchInFlight)
    }

    /// 清空缓冲不解除暂停；removeAll 清空一切，编号不复用；超过容量丢最早的。
    @Test func clearingAndCapacity() {
        var (queue, ids) = queue(["one"])
        queue.fail(.missingKey, batch: [], now: t0)
        queue.removeItems(listener: alpha)
        #expect(queue.items(for: alpha).isEmpty)
        #expect(queue.status == .blocked(.missingKey))
        queue.removeAll()
        #expect(queue.status == .idle)
        let next = queue.append(trMessage("again", listener: alpha), phase: .off, now: t0)
        #expect(next > ids[0])
        for index in 0..<(TranslationQueue.capacityPerCharacter + 5) {
            queue.append(trMessage("m\(index)", listener: alpha), phase: .off, now: t0)
        }
        #expect(queue.items(for: alpha).count == TranslationQueue.capacityPerCharacter)
        #expect(queue.items(for: alpha).first?.message.text == "m5")
        #expect(queue.allItems().count == TranslationQueue.capacityPerCharacter)
    }
}
