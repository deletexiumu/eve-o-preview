// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的排队与节流（docs/design-intel-translate.md 6.10 节）。只是状态机，不发请求、不读时钟：
// 时刻都由调用方传入（墙上时钟）。
// - enqueue：名字按比较键记进待查，记下排进来的时刻；已在待查或在途的不重复排；超过 2,000 个时丢最早的。
// - takeBatch：有一批在途、在等待且没到时刻、没有待查、最早的名字排进来不足 0.5 秒、距上一批不足 2 秒时返回 nil；
//   否则取最早的至多 500 个，状态改成 resolving。两批之间至少 2 秒，每分钟至多 30 个请求。
// - complete：这一批离开在途，连续失败清零。错误额度（errorLimitRemain）小于 20 时等 errorLimitReset 秒
//   （夹到 1～120，没有时 60），否则回到 idle。
// - fail：rateLimited 回到待查、等 retryAfter 秒；network、server、malformedAnswer 回到待查、等 30 秒，
//   连续失败时每次加倍，上限 600 秒；rejected 丢掉这一批、等 300 秒（请求写法有错，重发只会再扣错误额度）。
//   失败不产生任何结果，缓存不变。

import Foundation

/// 人名核对的队列。
public struct PilotLookupQueue: Sendable {
    /// 最早的名字排进来后至少等多久再发：同一条消息的名字一起发。
    public static let debounceSeconds = 0.5
    /// 两批之间至少隔多久。
    public static let minimumInterval = 2.0
    /// 待查的名字至多几个。
    public static let maxPending = 2_000
    /// 错误额度低于这个数时暂停。
    public static let lowErrorBudget = 20
    /// 失败后等待的起点与上限，以及 rejected 的等待。
    static let failureDelay = 30.0
    static let maxFailureDelay = 600.0
    static let rejectedDelay = 300.0

    /// 一个待查的名字。
    private struct Pending: Sendable {
        var key: String
        var name: String
        var enqueuedAt: Double
    }

    /// 待查的名字，最早的在前。
    private var pending: [Pending] = []
    /// 待查名字的比较键。
    private var pendingKeys: Set<String> = []
    /// 在途的一批。
    private var inFlight: [Pending]?
    /// 等到这个时刻再发；nil 表示不在等待。
    private var waitingUntil: Double?
    /// 上一批发出的时刻。
    private var lastBatchAt: Double?
    /// 连续失败的次数（network、server、malformedAnswer）。
    private var consecutiveFailures = 0

    /// 建一个空队列。
    public init() {}

    /// 当前状态（不含 off；off 由控制器按开关判断）。等待的时刻已过、还没取下一批时仍是 waiting，
    /// 界面按剩余秒数显示（不足 1 秒时显示成就绪）。
    public var status: PilotLookupStatus {
        if inFlight != nil { return .resolving }
        if let waitingUntil { return .waiting(until: waitingUntil) }
        return .idle
    }

    /// 待查的名字个数。
    public var pendingCount: Int { pending.count }

    /// 排进待查的名字；已在待查或在途的不重复排。超过 2,000 个时丢最早的。
    public mutating func enqueue(_ names: [String], now: Double) {
        let inFlightKeys = Set(inFlight?.map(\.key) ?? [])
        for name in names {
            let key = PilotLookupAnswer.key(for: name)
            guard !key.isEmpty, !pendingKeys.contains(key), !inFlightKeys.contains(key) else { continue }
            pending.append(Pending(key: key, name: name, enqueuedAt: now))
            pendingKeys.insert(key)
        }
        trimPending()
    }

    /// 取下一批；不能发时返回 nil。
    public mutating func takeBatch(now: Double) -> [String]? {
        guard inFlight == nil, let first = pending.first else { return nil }
        if let waitingUntil, now < waitingUntil { return nil }
        guard now - first.enqueuedAt >= PilotLookupQueue.debounceSeconds else { return nil }
        if let lastBatchAt, now - lastBatchAt < PilotLookupQueue.minimumInterval { return nil }
        let count = min(ESINameWire.maxNamesPerRequest, pending.count)
        let batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        for item in batch { pendingKeys.remove(item.key) }
        inFlight = batch
        waitingUntil = nil
        lastBatchAt = now
        return batch.map(\.name)
    }

    /// 下一次可以调 takeBatch 的时刻；没有待查的名字或有一批在途时返回 nil。
    public func nextAttempt(now: Double) -> Double? {
        guard inFlight == nil, let first = pending.first else { return nil }
        var time = first.enqueuedAt + PilotLookupQueue.debounceSeconds
        if let lastBatchAt { time = max(time, lastBatchAt + PilotLookupQueue.minimumInterval) }
        if let waitingUntil { time = max(time, waitingUntil) }
        return time
    }

    /// 一批成功：离开在途，连续失败清零；错误额度低时进入等待。
    public mutating func complete(_ answer: PilotLookupAnswer, now: Double) {
        inFlight = nil
        consecutiveFailures = 0
        if let remain = answer.errorLimitRemain, remain < PilotLookupQueue.lowErrorBudget {
            let reset = Double(answer.errorLimitReset ?? 60)
            waitingUntil = now + min(max(reset, 1), 120)
        } else {
            waitingUntil = nil
        }
    }

    /// 一批失败：按失败的种类决定这一批回不回到待查、等多久。
    public mutating func fail(_ failure: PilotLookupFailure, now: Double) {
        let batch = inFlight ?? []
        inFlight = nil
        switch failure {
        case .rateLimited(let retryAfter):
            requeue(batch)
            waitingUntil = now + max(0, retryAfter)
        case .network, .server, .malformedAnswer:
            requeue(batch)
            consecutiveFailures += 1
            let delay = PilotLookupQueue.failureDelay * pow(2, Double(min(consecutiveFailures - 1, 10)))
            waitingUntil = now + min(delay, PilotLookupQueue.maxFailureDelay)
        case .rejected:
            waitingUntil = now + PilotLookupQueue.rejectedDelay
        }
    }

    /// 清空待查与在途。等待的时刻保留：开关关了再开不应绕过 ESI 要求的等待。
    public mutating func removeAll() {
        pending.removeAll()
        pendingKeys.removeAll()
        inFlight = nil
        consecutiveFailures = 0
    }

    // MARK: - 内部

    /// 失败的一批放回待查的最前面，保留原来排进来的时刻；期间又排进来的同名不重复。
    private mutating func requeue(_ batch: [Pending]) {
        let restored = batch.filter { !pendingKeys.contains($0.key) }
        pending.insert(contentsOf: restored, at: 0)
        for item in restored { pendingKeys.insert(item.key) }
        trimPending()
    }

    /// 超过上限时丢最早的。
    private mutating func trimPending() {
        guard pending.count > PilotLookupQueue.maxPending else { return }
        let excess = pending.count - PilotLookupQueue.maxPending
        for item in pending.prefix(excess) { pendingKeys.remove(item.key) }
        pending.removeFirst(excess)
    }
}
