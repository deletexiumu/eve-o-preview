// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的缓冲（docs/design-intel-translate.md 6.5 节）：按收听者分开，每个收听者至多 300 条，
// 编号在整个缓冲里递增、从 1 起。浮窗只显示活动角色的那一份，切换客户端时立即换内容。
// - 同一个收听者的消息按日志时间排列：补读时各频道的文件依次读入，时间可能交错；相同时间的按到达顺序。
// - items(for:) 的收听者先按原样比较，没有时再不区分大小写比较（CharacterNameMatch）。
// - 每次刷新前由控制器调 prune，丢掉早于 windowMinutes 的消息。
// - 星图数据晚于消息读完时，控制器用 reparse 重新解析缓冲里的消息。
// 6.5 节的接口之外另有 removeItems(for:) 与 reparse(_:)，给 IntelFeedController 的 clear 与重新解析用。

import Foundation

/// 缓冲里的一条消息。
public struct IntelItem: Sendable, Equatable, Identifiable {
    /// 编号，在整个缓冲里递增。
    public var id: UInt64
    /// 原始消息。
    public var message: ChatMessage
    /// 解析结果。
    public var report: IntelReport

    /// 用各字段建一条。
    public init(id: UInt64, message: ChatMessage, report: IntelReport) {
        self.id = id
        self.message = message
        self.report = report
    }
}

/// 预警缓冲。
public struct IntelFeed: Sendable {
    /// 每个收听者至多保留的条数。
    public static let capacityPerCharacter = 300

    /// 收听者 → 消息，按日志时间排列。
    private var byListener: [String: [IntelItem]] = [:]
    /// 下一条的编号。
    private var nextID: UInt64 = 1

    /// 建一个空缓冲。
    public init() {}

    /// 加一条消息；同一个收听者超过容量时丢最早的。返回这条的编号。
    @discardableResult
    public mutating func append(_ message: ChatMessage, report: IntelReport) -> UInt64 {
        let id = nextID
        nextID += 1
        let item = IntelItem(id: id, message: message, report: report)
        let key = CharacterNameMatch.key(for: message.listener, in: byListener) ?? message.listener
        var items = byListener[key] ?? []
        // 从末尾往前找第一条时间不晚于它的，插在它后面；多数消息直接追加在末尾。
        var position = items.count
        while position > 0, items[position - 1].message.time > message.time { position -= 1 }
        items.insert(item, at: position)
        if items.count > IntelFeed.capacityPerCharacter {
            items.removeFirst(items.count - IntelFeed.capacityPerCharacter)
        }
        byListener[key] = items
        return id
    }

    /// 丢掉时间早于 cutoff 的消息，返回有没有丢。
    @discardableResult
    public mutating func prune(olderThan cutoff: Double) -> Bool {
        var changed = false
        for (key, items) in byListener {
            let kept = items.filter { $0.message.time >= cutoff }
            guard kept.count != items.count else { continue }
            changed = true
            byListener[key] = kept.isEmpty ? nil : kept
        }
        return changed
    }

    /// 某个收听者的消息，旧的在前。
    public func items(for listener: String) -> [IntelItem] {
        CharacterNameMatch.value(for: listener, in: byListener) ?? []
    }

    /// 清空全部收听者的消息。编号不重新开始。
    public mutating func removeAll() {
        byListener.removeAll()
    }

    /// 清空某个收听者的消息，返回有没有清掉。
    @discardableResult
    public mutating func removeItems(for listener: String) -> Bool {
        guard let key = CharacterNameMatch.key(for: listener, in: byListener) else { return false }
        byListener[key] = nil
        return true
    }

    /// 用新的解析规则重新解析每一条消息（星图数据晚于消息读完时）。编号与顺序不变。
    public mutating func reparse(_ parse: (ChatMessage) -> IntelReport) {
        for (key, items) in byListener {
            byListener[key] = items.map { IntelItem(id: $0.id, message: $0.message, report: parse($0.message)) }
        }
    }

    /// 全部消息的条数。
    public var count: Int {
        byListener.values.reduce(0) { $0 + $1.count }
    }
}
