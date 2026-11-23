// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的缓冲与排队（docs/design-intel-translate.md 7.6 节）。缓冲按收听者分开，每个收听者至多 300 条。
// 规则：
// - 消息由控制器决定进入时的阶段（skipped、done、pending、off）。
// - activate：换了活动角色，把它最近 600 秒内最新 20 条里 off 的消息排进队列。
// - takeBatch：最早的 pending 消息进入队列满 1 秒、没有在途的一批、没有暂停时，取一批标成 inFlight。
//   只取活动角色的消息：一段长时间的暂停之后切换客户端时，不为没人看的缓冲花钱（R34，规格没写，回报里列出）。
// - complete、fail：按结果改阶段与状态。一批在途时记下它的 id 集合；只有与之相同的一批才能释放在途的位置，
//   reset 或清空之后才到的旧结果仍可填上译文（complete），但不改状态。
// - complete 的结果按 TranslationRules.resultPhase 换成阶段（给了目标语言时）：模型原样抄回、或判断原文
//   已是目标语言的，是 skipped(.sameLanguage)，不是 done（审查 m7）。
// - 答复被截断（truncated）：一批多于 1 条时把这一批放回 pending，之后每批至多取原来的一半；
//   只有 1 条时这一条改成 failed。成功一批后上限加倍，回到 20 为止（审查 m8）。
// - 等待时长：429 带 retry-after 时用答复给的秒数，不参与加倍；不带时 30 秒起，连续限流时每次加倍，上限 600 秒。
//   408、409、5xx 与网络失败 30 秒起，连续失败时每次加倍，上限 300 秒。
// - nextAttempt：在等待、而活动角色没有 pending 的消息时，返回等待结束的时刻，让控制器到时调 takeBatch
//   把状态改回 idle，状态行不停在「等待重试」。
// 时刻（now、until、pendingSince）都用墙上时钟的秒数，与日志里的消息时间同一个时钟。

import Foundation

/// 翻译的缓冲与队列。值类型，由翻译控制器在主线程持有。
public struct TranslationQueue: Sendable {
    /// 最早的 pending 消息进入队列满这么多秒才发。
    public static let debounceSeconds = 1.0
    /// 每个收听者至多保留几条。
    public static let capacityPerCharacter = 300
    /// 服务出错与网络失败的首次等待秒数。
    public static let baseRetrySeconds = 30.0
    /// 连续失败时等待秒数的上限。
    public static let maxRetrySeconds = 300.0
    /// 429 没有给等待秒数时，连续限流的等待上限。
    public static let maxRateLimitSeconds = 600.0

    /// 队列的状态。
    public private(set) var status: TranslationStatus = .idle
    /// 活动角色（最近一次 activate 的参数）。
    public private(set) var activeListener: String?

    /// 收听者 → 按进入顺序排列的条目。
    private var buffers: [String: [Slot]] = [:]
    /// 下一个条目编号；从不复用，浮窗按编号对齐行。
    private var nextID: UInt64 = 1
    /// 在途的一批的 id 集合；没有在途的一批时为 nil。
    private var inFlightIDs: Set<UInt64>?
    /// 连续的服务出错与网络失败次数。
    private var consecutiveFailures = 0
    /// 连续的、没有给等待秒数的 429 次数。
    private var consecutiveRateLimits = 0
    /// 一批至多几条；答复被截断后减半，成功后加倍，最多 TranslationRules.maxBatchMessages。
    public private(set) var batchLimit = TranslationRules.maxBatchMessages

    /// 一条缓冲：条目与它变成 pending 的时刻。
    private struct Slot: Sendable {
        var item: TranslationItem
        var pendingSince: Double
    }

    /// 建空队列，状态是 idle。
    public init() {}

    // MARK: - 进入与读取

    /// 放入一条消息，返回它的编号。超过每个收听者的容量时丢掉最早的。
    @discardableResult
    public mutating func append(_ message: ChatMessage, phase: TranslationPhase, now: Double) -> UInt64 {
        let id = nextID
        nextID += 1
        let key = bufferKey(for: message.listener) ?? message.listener
        var slots = buffers[key] ?? []
        slots.append(Slot(item: TranslationItem(id: id, message: message, phase: phase), pendingSince: now))
        if slots.count > Self.capacityPerCharacter { slots.removeFirst(slots.count - Self.capacityPerCharacter) }
        buffers[key] = slots
        return id
    }

    /// 某个收听者的条目，按进入顺序。收听者先按原样、再不区分大小写匹配。
    public func items(for listener: String) -> [TranslationItem] {
        guard let key = bufferKey(for: listener) else { return [] }
        return buffers[key]?.map(\.item) ?? []
    }

    /// 全部收听者的条目，按编号（进入顺序）排列。目标语言或星图数据变了时，控制器据此重新判断。
    public func allItems() -> [TranslationItem] {
        buffers.values.joined().map(\.item).sorted { $0.id < $1.id }
    }

    /// 是否有一批在途。
    public var hasBatchInFlight: Bool { inFlightIDs != nil }

    // MARK: - 活动角色

    /// 换了活动角色：只看它时间在最近 600 秒内的最新 20 条，把其中 off 的改成 pending。
    /// 重复调用不会排进更多的消息。listener 为 nil 时只记下「没有活动角色」。
    public mutating func activate(listener: String?, now: Double) {
        activeListener = listener
        guard let listener, let key = bufferKey(for: listener), var slots = buffers[key] else { return }
        let recent = slots.indices.filter { slots[$0].item.message.time >= now - TranslationRules.backfillQueueSeconds }
        for index in recent.suffix(TranslationRules.backfillQueueLimit) where slots[index].item.phase == .off {
            slots[index].item.phase = .pending
            slots[index].pendingSince = now
        }
        buffers[key] = slots
    }

    // MARK: - 取一批与结果

    /// 现在该不该发下一批；该发时返回这一批并把它们标成 inFlight，状态改成 translating。
    ///
    /// 返回 nil 的情况：blocked；waiting 且还没到时刻；有一批在途；活动角色没有 pending 的消息；
    /// 最早的 pending 消息进入队列不足 1 秒。waiting 到时后状态先回到 idle。
    public mutating func takeBatch(now: Double) -> [TranslationItem]? {
        switch status {
        case .blocked: return nil
        case .waiting(let until, _):
            if now < until { return nil }
            status = .idle
        default: break
        }
        guard inFlightIDs == nil, let key = activeKey, var slots = buffers[key] else { return nil }
        let pending = slots.filter { $0.item.phase == .pending }
        guard let earliest = pending.map(\.pendingSince).min(), now >= earliest + Self.debounceSeconds else {
            return nil
        }
        let batch = TranslationRules.nextBatch(pending: pending.map(\.item), maxMessages: batchLimit)
        guard !batch.isEmpty else { return nil }
        let ids = Set(batch.map(\.id))
        for index in slots.indices where ids.contains(slots[index].item.id) {
            slots[index].item.phase = .inFlight
        }
        buffers[key] = slots
        inFlightIDs = ids
        status = .translating
        return batch.map { item in
            var copy = item
            copy.phase = .inFlight
            return copy
        }
    }

    /// 一批的结果：有结果的改成 done，在途而没有结果的改成 failed；
    /// 队列里缓存键相同的其他 pending 消息一并改成 done。是当前在途的一批时释放位置，状态回到 idle。
    ///
    /// 不是当前在途的一批（reset 或清空之后才到的旧结果）时，只把结果填给仍在 pending 或 inFlight 的消息，
    /// 不把没有结果的改成 failed，也不改状态。
    /// target 不为 nil 时，结果按 `TranslationRules.resultPhase` 换成阶段；为 nil 时一律是 done。
    public mutating func complete(_ results: [UInt64: TranslatedText], batch: [TranslationItem],
                                  target: AppLanguage? = nil) {
        let isCurrent = isCurrentBatch(batch)
        var byKey: [String: TranslatedText] = [:]
        for item in batch {
            if let result = results[item.id] { byKey[TranslationRules.cacheKey(item.message.text)] = result }
        }
        let batchIDs = Set(batch.map(\.id))
        for (key, var slots) in buffers {
            var changed = false
            for index in slots.indices {
                let item = slots[index].item
                let open = item.phase == .pending || item.phase == .inFlight
                guard open else { continue }
                if let result = byKey[TranslationRules.cacheKey(item.message.text)] {
                    slots[index].item.phase = target.map {
                        TranslationRules.resultPhase(result, original: item.message.text, target: $0)
                    } ?? .done(text: result.text, sourceLanguage: result.sourceLanguage)
                    changed = true
                } else if isCurrent, item.phase == .inFlight, batchIDs.contains(item.id) {
                    slots[index].item.phase = .failed
                    changed = true
                }
            }
            if changed { buffers[key] = slots }
        }
        guard isCurrent else { return }
        inFlightIDs = nil
        consecutiveFailures = 0
        consecutiveRateLimits = 0
        batchLimit = min(TranslationRules.maxBatchMessages, batchLimit * 2)
        if status == .translating { status = .idle }
    }

    /// 一批失败，或者发请求之前就发现的失败（batch 为空）。
    ///
    /// - 致命的失败：这一批回到 pending，状态改成 blocked。
    /// - rateLimited：这一批回到 pending；有秒数时等答复给的秒数，没有时等 30 秒，连续限流时加倍，上限 600 秒。
    /// - server、network：这一批回到 pending，等 30 秒，连续失败时加倍，上限 300 秒。
    /// - truncated：多于 1 条时这一批回到 pending，每批的上限改成这一批条数的一半；只有 1 条时改成 failed。
    /// - malformedAnswer、refused：这一批改成 failed，状态回到 idle。
    /// batch 不为空但不是当前在途的一批时（旧请求的结果）不做任何事。
    public mutating func fail(_ failure: TranslationFailure, batch: [TranslationItem], now: Double) {
        if !batch.isEmpty {
            guard isCurrentBatch(batch) else { return }
            inFlightIDs = nil
        }
        let ids = Set(batch.map(\.id))
        switch failure {
        case .truncated where batch.count > 1:
            setPhase(of: ids, to: .pending, now: now)
            batchLimit = max(1, batch.count / 2)
            status = .idle
        case .malformedAnswer, .refused, .truncated:
            setPhase(of: ids, to: .failed, now: now)
            consecutiveFailures = 0
            status = .idle
        case .rateLimited(let seconds?):
            setPhase(of: ids, to: .pending, now: now)
            status = .waiting(until: now + seconds, reason: failure)
        case .rateLimited(nil):
            setPhase(of: ids, to: .pending, now: now)
            consecutiveRateLimits += 1
            let exponent = Double(min(consecutiveRateLimits - 1, 16))
            let delay = min(Self.baseRetrySeconds * pow(2, exponent), Self.maxRateLimitSeconds)
            status = .waiting(until: now + delay, reason: failure)
        case .server, .network:
            setPhase(of: ids, to: .pending, now: now)
            consecutiveFailures += 1
            let exponent = Double(min(consecutiveFailures - 1, 16))
            let delay = min(Self.baseRetrySeconds * pow(2, exponent), Self.maxRetrySeconds)
            status = .waiting(until: now + delay, reason: failure)
        default:
            setPhase(of: ids, to: .pending, now: now)
            status = .blocked(failure)
        }
    }

    /// 设置或 Key 变了、或用户点了重试：状态回到 idle，连续失败的计数清零；在途的消息回到 pending，
    /// 最近 600 秒内 failed 的消息改回 pending。在途的请求由控制器取消，它的结果到达时按旧结果处理。
    public mutating func reset(now: Double) {
        status = .idle
        consecutiveFailures = 0
        consecutiveRateLimits = 0
        batchLimit = TranslationRules.maxBatchMessages
        inFlightIDs = nil
        for (key, var slots) in buffers {
            for index in slots.indices {
                let item = slots[index].item
                let retry = item.phase == .failed && item.message.time >= now - TranslationRules.backfillQueueSeconds
                if item.phase == .inFlight || retry {
                    slots[index].item.phase = .pending
                    slots[index].pendingSince = now
                }
            }
            buffers[key] = slots
        }
    }

    /// 下一次该调 takeBatch 的时刻；blocked 或有一批在途时为 nil。
    /// 活动角色没有 pending 的消息时：在等待则是等待结束的时刻（到时 takeBatch 把状态改回 idle），否则为 nil。
    public func nextAttempt(now: Double) -> Double? {
        if case .blocked = status { return nil }
        guard inFlightIDs == nil else { return nil }
        var waitingUntil: Double?
        if case .waiting(let until, _) = status { waitingUntil = until }
        guard let key = activeKey, let slots = buffers[key],
              let earliest = slots.filter({ $0.item.phase == .pending }).map(\.pendingSince).min() else {
            return waitingUntil
        }
        var time = earliest + Self.debounceSeconds
        if case .waiting(let until, _) = status { time = max(time, until) }
        return time
    }

    /// 清空全部缓冲与状态（目标语言变了时调用，之后控制器重新放入消息）。编号不复用。
    public mutating func removeAll() {
        buffers.removeAll()
        inFlightIDs = nil
        consecutiveFailures = 0
        consecutiveRateLimits = 0
        batchLimit = TranslationRules.maxBatchMessages
        status = .idle
    }

    /// 清空某个收听者（nil 表示全部）的缓冲，不改状态与在途的位置：跟踪请求变了、或用户点「清空列表」时调用，
    /// 暂停的原因（如 Key 无效）不因此消失；在途的一批的结果到达时照常释放位置。
    public mutating func removeItems(listener: String?) {
        guard let listener else {
            buffers.removeAll()
            return
        }
        if let key = bufferKey(for: listener) { buffers.removeValue(forKey: key) }
    }

    // MARK: - 内部

    /// 收听者对应的缓冲键：先原样，再不区分大小写（同 `CharacterNameMatch`）。
    private func bufferKey(for listener: String) -> String? {
        CharacterNameMatch.key(for: listener, in: buffers)
    }

    /// 活动角色的缓冲键。
    private var activeKey: String? {
        activeListener.flatMap { bufferKey(for: $0) }
    }

    /// batch 是否就是当前在途的那一批。
    private func isCurrentBatch(_ batch: [TranslationItem]) -> Bool {
        guard let inFlightIDs, !batch.isEmpty else { return false }
        return Set(batch.map(\.id)) == inFlightIDs
    }

    /// 把 ids 里仍在途的条目改成 phase；改成 pending 时记下时刻。
    private mutating func setPhase(of ids: Set<UInt64>, to phase: TranslationPhase, now: Double) {
        guard !ids.isEmpty else { return }
        for (key, var slots) in buffers {
            var changed = false
            for index in slots.indices where ids.contains(slots[index].item.id) && slots[index].item.phase == .inFlight {
                slots[index].item.phase = phase
                if phase == .pending { slots[index].pendingSince = now }
                changed = true
            }
            if changed { buffers[key] = slots }
        }
    }
}
