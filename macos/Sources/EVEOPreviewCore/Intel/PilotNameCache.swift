// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的缓存（docs/macos/design-intel-translate.md 6.10 节）。键是比较键（PilotLookupAnswer.key）。
// - matched 的结果保留 30 天，存进 pilot-names.json（由 Platform 的 FilePilotNameCacheStore 读写）。
// - ambiguous 与 notFound 保留 6 小时，只留在内存里：这些词多半不是人名，是消息正文的片段。
// - needsLookup：没有结果或结果已过期时为真。过期的结果在新结果到达之前仍在 directory 里，显示不倒退。
// - 容量：matched 至多 5,000 条，其余至多 5,000 条，超过时丢最早查到的。
// - snapshot：要存盘的条目（只有查到的、没过期的），并清掉 isDirty。
// 时刻都用墙上时钟（1970 年以来的秒数）。

import Foundation

/// 人名核对的缓存。
public struct PilotNameCache: Sendable {
    /// 查到的结果的期限：30 天。
    public static let matchedTTL = 2_592_000.0
    /// 没查到与有歧义的结果的期限：6 小时。
    public static let unmatchedTTL = 21_600.0
    /// 查到的结果至多几条。
    public static let matchedCapacity = 5_000
    /// 其余结果至多几条。
    public static let unmatchedCapacity = 5_000

    /// 一条结果与查到它的时刻。
    private struct Record: Sendable {
        var outcome: PilotLookupOutcome
        var time: Double
    }

    /// 查到的结果。
    private var matched: [String: Record] = [:]
    /// 没查到与有歧义的结果。
    private var unmatched: [String: Record] = [:]
    /// 两者合起来的结果表，directory 直接用它（不在每次刷新时重建）。
    private var table: [String: PilotLookupOutcome] = [:]
    /// 查到的结果有改动、还没存盘。
    public private(set) var isDirty = false

    /// 用缓存文件里的条目建缓存；过期的条目丢掉，超过容量时留最新的。
    public init(entries: [PilotNameCacheEntry] = [], now: Double) {
        for entry in entries where now - entry.time < PilotNameCache.matchedTTL && entry.characterID >= 0 {
            let key = PilotLookupAnswer.key(for: entry.key)
            guard !key.isEmpty else { continue }
            if let existing = matched[key], existing.time >= entry.time { continue }
            matched[key] = Record(outcome: .matched(characterID: entry.characterID, name: entry.name),
                                  time: entry.time)
        }
        PilotNameCache.trim(&matched, capacity: PilotNameCache.matchedCapacity)
        table = matched.mapValues(\.outcome)
    }

    /// 存入一批结果。查到的进 matched（从 unmatched 移出）；其余进 unmatched（从 matched 移出）。
    public mutating func store(_ outcomes: [String: PilotLookupOutcome], now: Double) {
        for (rawKey, outcome) in outcomes {
            let key = PilotLookupAnswer.key(for: rawKey)
            guard !key.isEmpty else { continue }
            let record = Record(outcome: outcome, time: now)
            if case .matched = outcome {
                matched[key] = record
                unmatched[key] = nil
                isDirty = true
            } else {
                if matched.removeValue(forKey: key) != nil { isDirty = true }
                unmatched[key] = record
            }
            table[key] = outcome
        }
        let droppedMatched = PilotNameCache.trim(&matched, capacity: PilotNameCache.matchedCapacity)
        let droppedOther = PilotNameCache.trim(&unmatched, capacity: PilotNameCache.unmatchedCapacity)
        for key in droppedMatched + droppedOther where matched[key] == nil && unmatched[key] == nil {
            table[key] = nil
        }
    }

    /// 没有结果或结果已过期时为真。
    public func needsLookup(_ name: String, now: Double) -> Bool {
        let key = PilotLookupAnswer.key(for: name)
        if let record = matched[key] { return now - record.time >= PilotNameCache.matchedTTL }
        if let record = unmatched[key] { return now - record.time >= PilotNameCache.unmatchedTTL }
        return true
    }

    /// 全部结果（含已过期、还没被新结果替换的），给分人用。
    public var directory: PilotDirectory { PilotDirectory(table) }

    /// 查到的结果的条数（「预警」页显示的「已保存的角色名个数」）。
    public var matchedCount: Int { matched.count }

    /// 要存盘的条目（只有查到的、没过期的），按比较键排序，并清掉 isDirty。
    public mutating func snapshot(now: Double) -> [PilotNameCacheEntry] {
        isDirty = false
        return matched.compactMap { key, record -> PilotNameCacheEntry? in
            guard now - record.time < PilotNameCache.matchedTTL,
                  case .matched(let id, let name) = record.outcome else { return nil }
            return PilotNameCacheEntry(key: key, characterID: id, name: name, time: record.time)
        }
        .sorted { $0.key < $1.key }
    }

    /// 清空全部结果。之后存盘会写出空文件。
    public mutating func removeAll() {
        matched.removeAll()
        unmatched.removeAll()
        table.removeAll()
        isDirty = true
    }

    /// 超过容量时丢最早查到的，返回丢掉的键。
    @discardableResult
    private static func trim(_ records: inout [String: Record], capacity: Int) -> [String] {
        guard records.count > capacity else { return [] }
        let excess = records.count - capacity
        let dropped = records.sorted { ($0.value.time, $0.key) < ($1.value.time, $1.key) }.prefix(excess).map(\.key)
        for key in dropped { records[key] = nil }
        return dropped
    }
}
