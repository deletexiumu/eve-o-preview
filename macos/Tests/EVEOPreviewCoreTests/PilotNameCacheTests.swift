// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名缓存的测试（docs/design-intel-translate.md 6.10 节、14.1 节）。人名是虚构的。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct PilotNameCacheTests {
    /// 存入与读出；键按比较键。
    @Test func storeAndRead() {
        var cache = PilotNameCache(now: 0)
        #expect(cache.needsLookup("Kael Doran", now: 0))
        cache.store(["kael doran": .matched(characterID: 7, name: "Kael Doran"), "mira": .notFound,
                     "veldspar": .ambiguous], now: 100)
        #expect(!cache.needsLookup("KAEL  DORAN", now: 100))
        #expect(cache.directory.outcome(for: "Kael Doran") == .matched(characterID: 7, name: "Kael Doran"))
        #expect(cache.directory.outcome(for: "Mira") == .notFound)
        #expect(cache.directory.outcome(for: "Veldspar") == .ambiguous)
        #expect(cache.matchedCount == 1)
        #expect(cache.isDirty)
    }

    /// matched 30 天、其余 6 小时；过期后 needsLookup 为真而 directory 里仍有。
    @Test func expiry() {
        var cache = PilotNameCache(now: 0)
        cache.store(["kael doran": .matched(characterID: 7, name: "Kael Doran"), "mira": .notFound], now: 0)
        let sixHours = PilotNameCache.unmatchedTTL
        #expect(!cache.needsLookup("Mira", now: sixHours - 1))
        #expect(cache.needsLookup("Mira", now: sixHours))
        #expect(cache.directory.outcome(for: "Mira") == .notFound)
        #expect(!cache.needsLookup("Kael Doran", now: PilotNameCache.matchedTTL - 1))
        #expect(cache.needsLookup("Kael Doran", now: PilotNameCache.matchedTTL))
        #expect(cache.directory.outcome(for: "Kael Doran") != nil)
    }

    /// 后来查不到的角色从 matched 移出。
    @Test func matchedReplacedByNotFound() {
        var cache = PilotNameCache(now: 0)
        cache.store(["kael doran": .matched(characterID: 7, name: "Kael Doran")], now: 0)
        _ = cache.snapshot(now: 0)
        cache.store(["kael doran": .notFound], now: 10)
        #expect(cache.matchedCount == 0)
        #expect(cache.isDirty)
        #expect(cache.directory.outcome(for: "Kael Doran") == .notFound)
    }

    /// snapshot 只含没过期的 matched，并清掉 isDirty；从条目恢复时丢掉过期的。
    @Test func snapshotAndRestore() {
        var cache = PilotNameCache(now: 0)
        cache.store(["kael doran": .matched(characterID: 7, name: "Kael Doran"), "mira": .notFound], now: 0)
        cache.store(["tarn vex": .matched(characterID: 8, name: "Tarn Vex")], now: 1_000)
        let entries = cache.snapshot(now: PilotNameCache.matchedTTL + 10)
        #expect(entries == [PilotNameCacheEntry(key: "tarn vex", characterID: 8, name: "Tarn Vex", time: 1_000)])
        #expect(!cache.isDirty)
        let saved = [PilotNameCacheEntry(key: "kael doran", characterID: 7, name: "Kael Doran", time: 0),
                     PilotNameCacheEntry(key: "Tarn Vex", characterID: 8, name: "Tarn Vex", time: 1_000)]
        let restored = PilotNameCache(entries: saved, now: PilotNameCache.matchedTTL + 10)
        #expect(restored.matchedCount == 1)
        #expect(restored.directory.outcome(for: "tarn vex") == .matched(characterID: 8, name: "Tarn Vex"))
        #expect(!restored.isDirty)
    }

    /// 两个容量：超过时丢最早查到的。
    @Test func capacities() {
        var cache = PilotNameCache(now: 0)
        var matched: [String: PilotLookupOutcome] = [:]
        for index in 0..<PilotNameCache.matchedCapacity {
            matched["m\(index)"] = .matched(characterID: index, name: "M\(index)")
        }
        cache.store(matched, now: 1)
        cache.store(["newest": .matched(characterID: 1, name: "Newest")], now: 2)
        #expect(cache.matchedCount == PilotNameCache.matchedCapacity)
        #expect(cache.directory.outcome(for: "newest") != nil)

        var other: [String: PilotLookupOutcome] = [:]
        for index in 0..<PilotNameCache.unmatchedCapacity { other["u\(index)"] = .notFound }
        cache.store(other, now: 3)
        cache.store(["latest": .notFound], now: 4)
        let remaining = (0..<PilotNameCache.unmatchedCapacity).filter { cache.directory.outcome(for: "u\($0)") != nil }
        #expect(remaining.count == PilotNameCache.unmatchedCapacity - 1)
        #expect(cache.directory.outcome(for: "latest") == .notFound)
    }

    /// removeAll 清空全部，之后存盘写出空文件。
    @Test func removeAll() {
        var cache = PilotNameCache(entries: [PilotNameCacheEntry(key: "kael doran", characterID: 7,
                                                                  name: "Kael Doran", time: 0)], now: 0)
        cache.removeAll()
        #expect(cache.matchedCount == 0)
        #expect(cache.directory.isEmpty)
        #expect(cache.isDirty)
        #expect(cache.snapshot(now: 0).isEmpty)
    }
}
