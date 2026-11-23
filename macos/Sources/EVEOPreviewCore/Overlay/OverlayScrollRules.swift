// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗列表的滚动规则（docs/macos/design-intel-translate.md 8.5 节）。纯函数，由 App 的 InfoOverlayContentView 调用。
// - 状态是 OverlayScrollState：是否贴住底部，以及离开底部后新到了几条。初始是贴住底部。
// - 用户滚动后：内容底部到可见区域底部的距离不超过 8 点时贴住底部并把条数清零，否则不贴。
// - 内容追加后：贴住底部时不计数（视图随后滚到底部）；不贴时累加条数，新消息条据此显示。
// - diff：两份行列表按行编号对齐。旧列表去掉头部若干行、尾部接上若干新行后，中间各行的编号与新列表逐一相同，
//   就是一般情况；编号相同但内容变了的行列进 changed。对不上时 isReload 为真，视图整表重载。
// - placeholder：列表为空时显示哪一句（WP-A 增补，见 OverlayListPlaceholder 的说明）。

import Foundation

/// 列表的滚动状态。
public struct OverlayScrollState: Sendable, Equatable {
    /// 是否贴住底部：贴住时内容更新后滚到底部。
    public var isPinnedToBottom: Bool
    /// 离开底部后新到的条数；贴住底部时为 0。
    public var unseenCount: Int

    /// 用两个字段建状态。
    public init(isPinnedToBottom: Bool, unseenCount: Int) {
        self.isPinnedToBottom = isPinnedToBottom
        self.unseenCount = unseenCount
    }

    /// 初始状态：贴住底部，没有新消息。
    public static let initial = OverlayScrollState(isPinnedToBottom: true, unseenCount: 0)
}

/// 新旧两份行列表的差异。
public struct OverlayListDiff: Sendable, Equatable {
    /// 旧列表头部去掉的行数。
    public var removedFromHead: Int
    /// 新列表尾部新增的行数。
    public var appended: Int
    /// 新列表里编号没变、内容变了的行的下标，从小到大。
    public var changed: [Int]
    /// 对不上：视图应整表重载，其余字段都是 0 或空。
    public var isReload: Bool

    /// 用各字段建差异。
    public init(removedFromHead: Int, appended: Int, changed: [Int], isReload: Bool) {
        self.removedFromHead = removedFromHead
        self.appended = appended
        self.changed = changed
        self.isReload = isReload
    }

    /// 要整表重载的差异。
    public static let reload = OverlayListDiff(removedFromHead: 0, appended: 0, changed: [], isReload: true)

    /// 没有任何变化。
    public var isEmpty: Bool {
        !isReload && removedFromHead == 0 && appended == 0 && changed.isEmpty
    }
}

/// 列表为空时显示的说明（8.4 节）。WP-A 增补的类型，签名不在 8.2 节里。
///
/// `OverlayContent` 没有「有没有活动角色」的字段。两个功能控制器的 contextKey 都是「功能名 + `:` + 活动角色名」
/// （6.8 节），没有活动角色时以 `:` 结尾，这里按这个约定区分两种空列表。
public enum OverlayListPlaceholder: Sendable, Equatable {
    /// 当前窗口没有角色（L10n.overlay.noActiveCharacter）。
    case noActiveCharacter
    /// 有角色但还没有消息（L10n.overlay.emptyList）。
    case empty
}

/// 滚动与列表差异的规则。
public enum OverlayScrollRules {
    /// 离底部不超过这么多点时算贴住底部。
    public static let bottomTolerance = 8.0

    /// 用户滚动后的状态：距离不超过 8 点时贴住底部且条数为 0，否则不贴、条数为 0。
    ///
    /// 不贴时条数取 0 是因为这个签名拿不到之前的条数；视图应调用带 state 的重载保留条数。
    public static func afterUserScroll(distanceFromBottom: Double) -> OverlayScrollState {
        afterUserScroll(.initial, distanceFromBottom: distanceFromBottom)
    }

    /// 用户滚动后的状态，保留离开底部期间已累计的条数：回到底部时清零，仍不在底部时条数不变。
    /// 距离不是有限值时按「不在底部」处理。
    public static func afterUserScroll(_ state: OverlayScrollState, distanceFromBottom: Double) -> OverlayScrollState {
        if distanceFromBottom.isFinite, distanceFromBottom <= bottomTolerance { return .initial }
        return OverlayScrollState(isPinnedToBottom: false, unseenCount: state.isPinnedToBottom ? 0 : state.unseenCount)
    }

    /// 尾部追加了 appended 行之后的状态：贴住底部时不变，不贴时累加条数。负数按 0 处理。
    public static func afterAppend(_ state: OverlayScrollState, appended: Int) -> OverlayScrollState {
        guard !state.isPinnedToBottom else { return state }
        return OverlayScrollState(isPinnedToBottom: false, unseenCount: state.unseenCount + max(0, appended))
    }

    /// 新旧两份行列表的差异：头部去掉几行、尾部加了几行、中间哪些行变了；对不上时 isReload 为真。
    ///
    /// 做法：旧列表里第一个编号也出现在新列表里的行是保留段的开头，它之前的行都算从头部去掉。
    /// 保留段一直延续到旧列表末尾，各行的编号应与新列表开头的各行逐一相同；新列表剩下的行是尾部新增的，
    /// 它们的编号不应出现在旧列表里。任何一条不满足时整表重载（中间删了一行、顺序变了、在头部插了行）。
    public static func diff(old: [OverlayLine], new: [OverlayLine]) -> OverlayListDiff {
        let newIDs = Set(new.map(\.id))
        let start = old.firstIndex { newIDs.contains($0.id) } ?? old.count
        let kept = old.count - start
        guard kept <= new.count else { return .reload }
        var changed: [Int] = []
        for offset in 0..<kept {
            let before = old[start + offset]
            let after = new[offset]
            guard before.id == after.id else { return .reload }
            if before != after { changed.append(offset) }
        }
        let oldIDs = Set(old.map(\.id))
        guard !new[kept...].contains(where: { oldIDs.contains($0.id) }) else { return .reload }
        return OverlayListDiff(removedFromHead: start, appended: new.count - kept, changed: changed, isReload: false)
    }

    /// 列表为空时显示哪一句；列表不空时为 nil。contextKey 为空或以 `:` 结尾表示没有活动角色。
    public static func placeholder(for content: OverlayContent) -> OverlayListPlaceholder? {
        guard content.lines.isEmpty else { return nil }
        let key = content.contextKey
        return key.isEmpty || key.hasSuffix(":") ? .noActiveCharacter : .empty
    }
}
