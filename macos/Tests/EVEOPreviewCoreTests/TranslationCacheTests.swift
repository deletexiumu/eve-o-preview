// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存（docs/macos/design-intel-translate.md 7.8 节，14.1 节 TranslationCacheTests）：命中与未命中；
// 容量满时丢最久没用的；读取会刷新新旧顺序；snapshot 清掉 isDirty；从条目恢复；另有合并与大量写入。

import Testing
import Foundation
import EVEOPreviewCore

/// 译文缓存。
struct TranslationCacheTests {
    /// 一条译文。
    func value(_ text: String) -> TranslatedText { TranslatedText(text: text, sourceLanguage: "en") }

    /// 命中按缓存键比对（空白与 `*` 的差别不算新句子）；目标语言不同不命中。
    @Test func hitAndMiss() {
        var cache = TranslationCache()
        #expect(cache.value(for: "hello there", target: .zh) == nil)
        cache.store(value("你好"), for: "hello  there*", target: .zh)
        #expect(cache.value(for: " hello there ", target: .zh) == value("你好"))
        #expect(cache.value(for: "hello there", target: .ja) == nil)
        #expect(cache.count == 1)
        // 空的原文或空的译文不存。
        cache.store(value("x"), for: "   ", target: .zh)
        cache.store(value(""), for: "y", target: .zh)
        #expect(cache.count == 1)
    }

    /// 容量满时丢最久没用的；读取刷新顺序。
    @Test func evictsLeastRecentlyUsed() {
        var cache = TranslationCache(capacity: 2)
        cache.store(value("A"), for: "a", target: .zh)
        cache.store(value("B"), for: "b", target: .zh)
        _ = cache.value(for: "a", target: .zh)          // a 变成最近用过的
        cache.store(value("C"), for: "c", target: .zh)  // 丢 b
        #expect(cache.value(for: "b", target: .zh) == nil)
        #expect(cache.value(for: "a", target: .zh) == value("A"))
        #expect(cache.value(for: "c", target: .zh) == value("C"))
        #expect(cache.count == 2)
    }

    /// snapshot 按「最近用过的在后」给出条目，并清掉 isDirty。
    @Test func snapshotClearsDirty() {
        var cache = TranslationCache()
        #expect(!cache.isDirty)
        cache.store(value("A"), for: "a", target: .zh)
        cache.store(value("B"), for: "b", target: .zh)
        _ = cache.value(for: "a", target: .zh)
        #expect(cache.isDirty)
        let entries = cache.snapshot()
        #expect(entries.map(\.key) == ["b", "a"])
        #expect(entries.first == TranslationCacheEntry(target: "zh", key: "b", text: "B", sourceLanguage: "en"))
        #expect(!cache.isDirty)
        cache.removeAll()
        #expect(cache.isDirty && cache.count == 0)
    }

    /// 从条目恢复：不算改动；超过容量时只留最后的；同键后面的为准。
    @Test func restoresFromEntries() {
        let entries = [TranslationCacheEntry(target: "zh", key: "a", text: "A1", sourceLanguage: nil),
                       TranslationCacheEntry(target: "zh", key: "b", text: "B", sourceLanguage: nil),
                       TranslationCacheEntry(target: "zh", key: "a", text: "A2", sourceLanguage: "en"),
                       TranslationCacheEntry(target: "zh", key: "c", text: "C", sourceLanguage: nil)]
        var cache = TranslationCache(capacity: 2, entries: entries)
        #expect(!cache.isDirty)
        #expect(cache.count == 2)
        #expect(cache.value(for: "a", target: .zh) == TranslatedText(text: "A2", sourceLanguage: "en"))
        #expect(cache.value(for: "b", target: .zh) == nil)
    }

    /// 合并文件里的旧条目：现有的同键条目为准，旧条目排在前面，isDirty 不变。
    @Test func mergeOlderEntries() {
        var cache = TranslationCache(capacity: 3)
        cache.store(value("NEW"), for: "a", target: .zh)
        cache.merge(older: [TranslationCacheEntry(target: "zh", key: "a", text: "OLD", sourceLanguage: nil),
                            TranslationCacheEntry(target: "zh", key: "b", text: "B", sourceLanguage: nil)])
        #expect(cache.isDirty)
        #expect(cache.orderedEntries.map(\.text) == ["B", "NEW"])
    }

    /// 大量写入时容量保持不变，最后写入的都在。
    @Test func manyWritesStayWithinCapacity() {
        var cache = TranslationCache(capacity: 100)
        for index in 0..<5_000 {
            cache.store(value("v\(index)"), for: "k\(index)", target: .en)
            if index % 3 == 0 { _ = cache.value(for: "k\(index)", target: .en) }
        }
        #expect(cache.count == 100)
        #expect(cache.value(for: "k4999", target: .en) == value("v4999"))
        #expect(cache.value(for: "k0", target: .en) == nil)
    }
}
