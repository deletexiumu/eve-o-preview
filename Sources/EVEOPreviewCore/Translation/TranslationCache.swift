// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存（docs/design-intel-translate.md 7.8 节）：键是（目标语言代码，cacheKey(原文)），至多 10,000 条，
// 最近用过的留下。存盘由 App 安排（有改动时满 30 秒存一次，退出时存一次），文件的读写在 Platform。
// 做法：字典存条目与「最近使用的序号」，另有一条按使用先后排列的序号队列；淘汰时从队头取，
// 序号已过时（那一条之后又被用过）的跳过。队列过长时整理一次，摊下来每次操作是常数时间。

import Foundation

/// 译文缓存。值类型，由翻译控制器在主线程持有。
public struct TranslationCache: Sendable {
    /// 默认容量。
    public static let defaultCapacity = 10_000

    /// 有没有没存盘的改动。
    public private(set) var isDirty = false
    /// 条目数。
    public var count: Int { table.count }

    /// 容量，至少 1。
    private let capacity: Int
    /// 组合键 → 条目与最近一次使用的序号。
    private var table: [String: Slot] = [:]
    /// 按使用先后排列的（组合键，序号）；从 head 起有效。
    private var order: [(key: String, stamp: UInt64)] = []
    /// order 里第一个有效元素的下标。
    private var head = 0
    /// 下一个序号。
    private var nextStamp: UInt64 = 0

    /// 一条缓存与它最近一次使用的序号。
    private struct Slot: Sendable {
        var entry: TranslationCacheEntry
        var stamp: UInt64
    }

    /// 建缓存。entries 按「最近用过的在后」的顺序给出；同一个键出现多次时后面的为准；超过容量时只留最后的。
    public init(capacity: Int = TranslationCache.defaultCapacity, entries: [TranslationCacheEntry] = []) {
        self.capacity = max(1, capacity)
        for entry in entries where !entry.key.isEmpty && !entry.text.isEmpty {
            put(entry)
        }
        isDirty = false
    }

    /// 取一条译文；命中时刷新它的新旧顺序。
    public mutating func value(for text: String, target: AppLanguage) -> TranslatedText? {
        let key = Self.compositeKey(target: target.rawValue, key: TranslationRules.cacheKey(text))
        guard var slot = table[key] else { return nil }
        slot.stamp = touch(key)
        table[key] = slot
        return TranslatedText(text: slot.entry.text, sourceLanguage: slot.entry.sourceLanguage)
    }

    /// 存一条译文；原文的缓存键为空或译文为空时不存。
    public mutating func store(_ value: TranslatedText, for text: String, target: AppLanguage) {
        let key = TranslationRules.cacheKey(text)
        guard !key.isEmpty, !value.text.isEmpty else { return }
        put(TranslationCacheEntry(target: target.rawValue, key: key, text: value.text,
                                  sourceLanguage: value.sourceLanguage))
        isDirty = true
    }

    /// 清空全部条目，标记为有改动（存盘后文件也变空）。
    public mutating func removeAll() {
        table.removeAll()
        order.removeAll()
        head = 0
        isDirty = true
    }

    /// 取出要存盘的条目（最近用过的在后）并清掉 isDirty。
    public mutating func snapshot() -> [TranslationCacheEntry] {
        isDirty = false
        return orderedEntries
    }

    /// 全部条目，最近用过的在后；不改 isDirty。
    public var orderedEntries: [TranslationCacheEntry] {
        table.values.sorted { $0.stamp < $1.stamp }.map(\.entry)
    }

    /// 把从文件读到的条目并进来，当作比现有条目都旧（现有的同键条目为准）。isDirty 不变。
    ///
    /// 应用启动后缓存文件在后台读取；读完之前已经翻译的句子在内存里，合并后都保留。
    public mutating func merge(older entries: [TranslationCacheEntry]) {
        let dirty = isDirty
        let current = orderedEntries
        self = TranslationCache(capacity: capacity, entries: entries + current)
        isDirty = dirty
    }

    // MARK: - 内部

    /// 组合键：目标语言代码与缓存键之间用 U+0001 隔开（缓存键里不会有这个字符以外的控制符冲突）。
    private static func compositeKey(target: String, key: String) -> String {
        target + "\u{1}" + key
    }

    /// 放入一条（已规整的）条目，超过容量时淘汰最久没用的。
    private mutating func put(_ entry: TranslationCacheEntry) {
        let key = Self.compositeKey(target: entry.target, key: entry.key)
        table[key] = Slot(entry: entry, stamp: touch(key))
        while table.count > capacity {
            // 队列与字典始终一致，淘汰总能成功；万一失败也退出，不陷入死循环。
            guard evictOldest() else { break }
        }
    }

    /// 记下一次使用，返回新的序号。调用方随后把序号写进字典。
    /// 整理放在追加之前：这时字典里还是旧序号，整理掉的只是已失效的元素，新追加的元素不受影响。
    private mutating func touch(_ key: String) -> UInt64 {
        if order.count - head > 2 * table.count + 64 { compact() }
        let stamp = nextStamp
        nextStamp += 1
        order.append((key, stamp))
        return stamp
    }

    /// 淘汰最久没用的一条：从队头取，序号与字典里不一致（之后又被用过或已删除）的跳过。淘汰了一条时为真。
    @discardableResult
    private mutating func evictOldest() -> Bool {
        while head < order.count {
            let candidate = order[head]
            head += 1
            if let slot = table[candidate.key], slot.stamp == candidate.stamp {
                table.removeValue(forKey: candidate.key)
                return true
            }
        }
        return false
    }

    /// 只留下有效的队列元素。
    private mutating func compact() {
        order = order[head...].filter { table[$0.key]?.stamp == $0.stamp }
        head = 0
    }
}
