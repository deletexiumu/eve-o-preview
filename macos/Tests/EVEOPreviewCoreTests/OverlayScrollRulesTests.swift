// SPDX-License-Identifier: GPL-3.0-or-later
//
// OverlayScrollRules 的用例（docs/macos/design-intel-translate.md 8.5 节、14.1 节）。

import Testing
import EVEOPreviewCore

/// 滚动状态、追加计数、列表差异与空列表的说明。
struct OverlayScrollRulesTests {
    /// 一行：编号与正文，正文不同的两行内容不等。
    private func line(_ id: UInt64, _ text: String = "") -> OverlayLine {
        OverlayLine(id: id, primary: [OverlaySpan(text.isEmpty ? "line \(id)" : text, .plain)], copyText: text)
    }

    /// 一组编号对应的行。
    private func lines(_ ids: [UInt64]) -> [OverlayLine] {
        ids.map { line($0) }
    }

    // MARK: - 滚动状态

    /// 距底部 0、8 点时贴住底部且条数为 0；9 点时不贴。
    @Test func userScrollDistances() {
        #expect(OverlayScrollRules.afterUserScroll(distanceFromBottom: 0) == .initial)
        #expect(OverlayScrollRules.afterUserScroll(distanceFromBottom: 8) == .initial)
        #expect(OverlayScrollRules.afterUserScroll(distanceFromBottom: 9)
                == OverlayScrollState(isPinnedToBottom: false, unseenCount: 0))
        // 弹性滚动越过底部时距离是负数，也算贴住。
        #expect(OverlayScrollRules.afterUserScroll(distanceFromBottom: -12).isPinnedToBottom)
    }

    /// 带状态的重载：不在底部时保留已累计的条数，回到底部时清零。
    @Test func userScrollKeepsCount() {
        let away = OverlayScrollState(isPinnedToBottom: false, unseenCount: 5)
        #expect(OverlayScrollRules.afterUserScroll(away, distanceFromBottom: 200) == away)
        #expect(OverlayScrollRules.afterUserScroll(away, distanceFromBottom: 3) == .initial)
        #expect(OverlayScrollRules.afterUserScroll(.initial, distanceFromBottom: 200).unseenCount == 0)
        #expect(!OverlayScrollRules.afterUserScroll(.initial, distanceFromBottom: .nan).isPinnedToBottom)
    }

    /// 贴住底部时追加不计数；不贴时累加；负数按 0 处理。
    @Test func appendCounting() {
        #expect(OverlayScrollRules.afterAppend(.initial, appended: 3) == .initial)
        let away = OverlayScrollState(isPinnedToBottom: false, unseenCount: 2)
        #expect(OverlayScrollRules.afterAppend(away, appended: 3).unseenCount == 5)
        #expect(OverlayScrollRules.afterAppend(away, appended: -1).unseenCount == 2)
        #expect(!OverlayScrollRules.afterAppend(away, appended: 3).isPinnedToBottom)
    }

    // MARK: - 列表差异

    /// 只追加：旧列表全部保留，尾部新增 2 行。
    @Test func diffAppendOnly() {
        let diff = OverlayScrollRules.diff(old: lines([1, 2, 3]), new: lines([1, 2, 3, 4, 5]))
        #expect(diff == OverlayListDiff(removedFromHead: 0, appended: 2, changed: [], isReload: false))
        // 从空列表开始也是只追加。
        #expect(OverlayScrollRules.diff(old: [], new: lines([7, 8])).appended == 2)
        // 完全相同时没有变化。
        #expect(OverlayScrollRules.diff(old: lines([1, 2]), new: lines([1, 2])).isEmpty)
    }

    /// 头部去掉加尾部追加：去掉 2 行、加 1 行；全部换成新行时去掉全部、加全部。
    @Test func diffHeadRemovedAndAppended() {
        let diff = OverlayScrollRules.diff(old: lines([1, 2, 3, 4]), new: lines([3, 4, 5]))
        #expect(diff == OverlayListDiff(removedFromHead: 2, appended: 1, changed: [], isReload: false))
        let replaced = OverlayScrollRules.diff(old: lines([1, 2]), new: lines([8, 9]))
        #expect(replaced == OverlayListDiff(removedFromHead: 2, appended: 2, changed: [], isReload: false))
        let cleared = OverlayScrollRules.diff(old: lines([1, 2]), new: [])
        #expect(cleared == OverlayListDiff(removedFromHead: 2, appended: 0, changed: [], isReload: false))
    }

    /// 中间一行内容变了（译文晚到、人名核对的结果到达）：编号不变，列进 changed，下标是新列表里的。
    @Test func diffChangedRow() {
        var new = lines([2, 3, 4, 5])
        new[1] = line(3, "translated")
        let diff = OverlayScrollRules.diff(old: lines([1, 2, 3, 4]), new: new)
        #expect(diff == OverlayListDiff(removedFromHead: 1, appended: 1, changed: [1], isReload: false))
    }

    /// 对不上时整表重载：中间删了一行、顺序变了、头部插了一行、新增的编号与旧列表重复。
    @Test func diffReload() {
        #expect(OverlayScrollRules.diff(old: lines([1, 2, 3]), new: lines([1, 3])).isReload)
        #expect(OverlayScrollRules.diff(old: lines([1, 2, 3]), new: lines([2, 1, 3])).isReload)
        #expect(OverlayScrollRules.diff(old: lines([1, 2, 3]), new: lines([0, 1, 2, 3])).isReload)
        #expect(OverlayScrollRules.diff(old: lines([1, 2, 3]), new: lines([3, 1])).isReload)
        #expect(OverlayScrollRules.diff(old: lines([1, 2, 3]), new: lines([1, 2, 3, 2])) == .reload)
    }

    // MARK: - 空列表的说明

    /// 列表不空时没有说明；contextKey 以 `:` 结尾或为空时是「没有角色」，否则是「还没有消息」。
    @Test func placeholder() {
        let withLines = OverlayContent(contextKey: "intel:", title: "T", status: nil, lines: lines([1]))
        #expect(OverlayScrollRules.placeholder(for: withLines) == nil)
        let noCharacter = OverlayContent(contextKey: "translation:", title: "T", status: nil, lines: [])
        #expect(OverlayScrollRules.placeholder(for: noCharacter) == .noActiveCharacter)
        let blank = OverlayContent(contextKey: "", title: "T", status: nil, lines: [])
        #expect(OverlayScrollRules.placeholder(for: blank) == .noActiveCharacter)
        let empty = OverlayContent(contextKey: "intel:Pilot Alpha", title: "T", status: nil, lines: [])
        #expect(OverlayScrollRules.placeholder(for: empty) == .empty)
    }
}
