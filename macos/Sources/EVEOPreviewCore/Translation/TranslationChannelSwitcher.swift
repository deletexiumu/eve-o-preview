// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗快速切换频道的纯逻辑：按钮文字、候选频道排序与分组、单选判断。
// 规则：
// - 内置频道（本地、军团、联盟、舰队）始终排在第一组，按 ID 匹配。
// - 最近 24 小时从日志里发现的频道去掉内置种类与私聊后，活动角色出现过的排在前面，其余按最后活跃时间倒序，
//   最多保留 maxRecentChannels（15）项，避免菜单过长。
// - 当前已选里如果还有不在内置与最近列表里的自定义频道（手动输入或超过 24 小时未发言），单独放进 customSelected，
//   菜单里仍能看到当前正在翻译什么，也能随时切回。
// - 按钮文字：未选时显示占位词，单选时显示频道名，多选时显示「首个频道名 +其余个数」。

import Foundation

/// 翻译浮窗频道切换的菜单分组。
public struct TranslationChannelSections: Sendable, Equatable {
    /// 4 个内置频道（本地、军团、联盟、舰队）。
    public var builtIns: [ChannelRef]
    /// 最近 24 小时活跃的非内置日志频道（已优先排当前角色，并按活跃时间倒序截断）。
    public var recent: [DiscoveredChannel]
    /// 当前已选但不在内置和最近列表里的频道，避免自定义或静默频道在菜单里「失踪」。
    public var customSelected: [ChannelRef]

    /// 用三组频道建分组结果。
    public init(builtIns: [ChannelRef], recent: [DiscoveredChannel], customSelected: [ChannelRef]) {
        self.builtIns = builtIns
        self.recent = recent
        self.customSelected = customSelected
    }
}

/// 翻译浮窗频道切换的纯计算规则。
public enum TranslationChannelSwitcher {
    /// 菜单里最多展示多少个近期日志频道。
    public static let maxRecentChannels = 15

    /// 内置频道对应的日志种类：它们在菜单里由内置分组提供，不重复出现在近期日志分组里。
    private static let builtInKinds: Set<ChatChannelKind> = [.local, .corp, .alliance, .fleet]

    /// 两个频道引用是否指同一个频道（与 ChannelListEditor / ConfigValidator 的去重规则一致）：
    /// 两边都有非空 ID 时按 ID 不区分大小写比较，否则按去掉首尾空白的名字不区分大小写比较。
    public static func isSameChannel(_ a: ChannelRef, _ b: ChannelRef) -> Bool {
        if let aid = trimmedNonEmpty(a.id), let bid = trimmedNonEmpty(b.id) {
            return aid.caseInsensitiveCompare(bid) == .orderedSame
        }
        return a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// 候选频道是否在当前已选列表里（用于菜单里显示勾选标记）。
    public static func isSelected(_ candidate: ChannelRef, in selected: [ChannelRef]) -> Bool {
        selected.contains { isSameChannel($0, candidate) }
    }

    /// 候选频道是否已经是唯一的当前翻译频道：是的话点击它无需重建跟踪器。
    /// 若当前只存了名字（无 ID）而候选项带规范 ID，返回 false，点击后可顺带升级成带 ID 的引用。
    public static func isOnlySelected(_ candidate: ChannelRef, in selected: [ChannelRef]) -> Bool {
        guard selected.count == 1, isSameChannel(selected[0], candidate) else { return false }
        if trimmedNonEmpty(selected[0].id) == nil, trimmedNonEmpty(candidate.id) != nil {
            return false
        }
        return true
    }

    /// 整理近期日志频道：去掉内置种类与私聊，活动角色出现过的排前面，同组内按最后修改时间倒序（相同时按 ID），
    /// 最多取 limit 个。
    public static func orderedRecentChannels(
        discovered: [DiscoveredChannel],
        activeCharacter: String?,
        limit: Int = maxRecentChannels
    ) -> [DiscoveredChannel] {
        let filtered = discovered.filter { !builtInKinds.contains($0.kind) && $0.kind != .privateChat }
        let active = trimmedNonEmpty(activeCharacter)?.lowercased()
        let sorted = filtered.sorted { lhs, rhs in
            if let active {
                let lhsActive = lhs.listenerNames.contains(active)
                let rhsActive = rhs.listenerNames.contains(active)
                if lhsActive != rhsActive { return lhsActive }
            }
            if lhs.lastModified != rhs.lastModified { return lhs.lastModified > rhs.lastModified }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// 生成频道切换菜单的三组频道。
    public static func sections(
        selected: [ChannelRef],
        discovered: [DiscoveredChannel],
        activeCharacter: String?,
        limit: Int = maxRecentChannels
    ) -> TranslationChannelSections {
        let builtIns = ChannelRef.builtIns
        let recent = orderedRecentChannels(discovered: discovered, activeCharacter: activeCharacter, limit: limit)
        let recentRefs = recent.map(\.ref)
        let customSelected = selected.filter { channel in
            !isSelected(channel, in: builtIns) && !isSelected(channel, in: recentRefs)
        }
        return TranslationChannelSections(builtIns: builtIns, recent: recent, customSelected: customSelected)
    }

    /// 浮窗标题栏右侧按钮的文字：没选时用 emptyLabel；1 个时显示名字；多个时显示「首个名字 +其余个数」。
    public static func buttonLabel(
        selected: [ChannelRef],
        emptyLabel: String,
        displayName: (ChannelRef) -> String
    ) -> String {
        guard let first = selected.first else { return emptyLabel }
        let name = displayName(first)
        guard selected.count > 1 else { return name }
        return "\(name) +\(selected.count - 1)"
    }

    /// 去掉首尾空白；空串或 nil 时返回 nil。
    private static func trimmedNonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
