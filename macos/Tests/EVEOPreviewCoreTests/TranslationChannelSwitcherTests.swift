// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗快速切换频道（TranslationChannelSwitcher）的纯逻辑用例：
// 频道同一性判断、单选状态、近期日志频道按当前角色与活跃时间排序、菜单分组与按钮文字。

import Testing
@testable import EVEOPreviewCore

@Suite("TranslationChannelSwitcher")
struct TranslationChannelSwitcherTests {
    /// 建一个发现的频道样例，减少重复样板。
    private static func discovered(
        id: String,
        name: String,
        kind: ChatChannelKind = .player,
        lastModified: Double,
        listeners: [String] = []
    ) -> DiscoveredChannel {
        let lower = listeners.map { $0.lowercased() }.sorted()
        return DiscoveredChannel(
            id: id,
            name: name,
            kind: kind,
            listeners: lower.count,
            lastModified: lastModified,
            listenerNames: lower
        )
    }

    @Test("频道同一性：两边都有非空 ID 时按 ID，否则按去空白后的名字，不区分大小写")
    func sameChannelMatching() {
        let byID1 = ChannelRef(name: "Old Name", id: "Player_42")
        let byID2 = ChannelRef(name: "Renamed", id: "player_42")
        #expect(TranslationChannelSwitcher.isSameChannel(byID1, byID2))

        let byName = ChannelRef(name: "  intel.north  ", id: nil)
        let withID = ChannelRef(name: "INTEL.NORTH", id: "player_99")
        #expect(TranslationChannelSwitcher.isSameChannel(byName, withID))

        let blankID = ChannelRef(name: "Fleet Chat", id: "   ")
        let noID = ChannelRef(name: "fleet chat", id: nil)
        #expect(TranslationChannelSwitcher.isSameChannel(blankID, noID))

        let differentID = ChannelRef(name: "Same", id: "player_1")
        let otherID = ChannelRef(name: "Same", id: "player_2")
        #expect(!TranslationChannelSwitcher.isSameChannel(differentID, otherID))
    }

    @Test("单选状态：只有唯一选中该频道时 isOnlySelected 为真，多选与缺 ID 升级时为假")
    func singleAndMultiSelectionState() {
        let local = ChannelRef.local
        let corp = ChannelRef.corp
        #expect(TranslationChannelSwitcher.isSelected(local, in: [local]))
        #expect(TranslationChannelSwitcher.isOnlySelected(local, in: [local]))
        #expect(TranslationChannelSwitcher.isSelected(local, in: [local, corp]))
        #expect(!TranslationChannelSwitcher.isOnlySelected(local, in: [local, corp]))
        #expect(!TranslationChannelSwitcher.isSelected(local, in: []))
        #expect(!TranslationChannelSwitcher.isOnlySelected(local, in: []))
        // 之前按名字手动添加了 Local（没有 ID），再点菜单里的内置 Local（带 ID）时允许替换补全 ID。
        let nameOnlyLocal = ChannelRef(name: "Local", id: nil)
        #expect(TranslationChannelSwitcher.isSelected(local, in: [nameOnlyLocal]))
        #expect(!TranslationChannelSwitcher.isOnlySelected(local, in: [nameOnlyLocal]))
    }

    @Test("近期频道排序：过滤内置与私聊，活动角色优先，再按活跃时间倒序并截断上限")
    func orderedRecentPrioritizesActiveCharacter() {
        let input = [
            Self.discovered(id: "local", name: "Local", kind: .local, lastModified: 900, listeners: ["Alpha"]),
            Self.discovered(id: "fleet_1", name: "Fleet", kind: .fleet, lastModified: 900, listeners: ["Alpha"]),
            Self.discovered(id: "private_1", name: "DM", kind: .privateChat, lastModified: 900, listeners: ["Alpha"]),
            Self.discovered(id: "player_other_new", name: "OtherNewest", lastModified: 500, listeners: ["Beta"]),
            Self.discovered(id: "player_alpha_old", name: "AlphaOlder", lastModified: 100, listeners: ["Alpha"]),
            Self.discovered(id: "player_alpha_new", name: "AlphaNewer", lastModified: 200, listeners: ["Alpha", "Beta"]),
            Self.discovered(id: "other_1", name: "Help", kind: .other, lastModified: 300, listeners: ["Beta"]),
        ]
        // 活动角色 Alpha（不区分大小写）听过的两个频道排在最前，即便 Beta 的频道更新。
        let ordered = TranslationChannelSwitcher.orderedRecentChannels(
            discovered: input,
            activeCharacter: "  alpha ",
            limit: 3
        )
        #expect(ordered.map(\.id) == ["player_alpha_new", "player_alpha_old", "player_other_new"])
        // 没有活动角色时只按最后活跃时间倒序。
        let withoutActive = TranslationChannelSwitcher.orderedRecentChannels(
            discovered: input,
            activeCharacter: nil,
            limit: 10
        )
        #expect(withoutActive.map(\.id) == ["player_other_new", "other_1", "player_alpha_new", "player_alpha_old"])
    }

    @Test("菜单分组：保留不在内置与近期列表里的已选自定义频道，避免菜单里消失")
    func sectionsIncludeCustomSelected() {
        let recent = [
            Self.discovered(id: "player_1", name: "Fleet Ops", lastModified: 300, listeners: ["Alpha"]),
        ]
        let custom = ChannelRef(name: "Old Quiet Channel", id: "player_quiet")
        let selected = [ChannelRef.local, ChannelRef(name: "Fleet Ops", id: "player_1"), custom]
        let sections = TranslationChannelSwitcher.sections(
            selected: selected,
            discovered: recent,
            activeCharacter: "Alpha"
        )
        #expect(sections.builtIns == ChannelRef.builtIns)
        #expect(sections.recent.map(\.id) == ["player_1"])
        #expect(sections.customSelected == [custom])
    }

    @Test("按钮文字：未选、单选与多选三种格式")
    func buttonLabelFormats() {
        let display: (ChannelRef) -> String = { $0.isBuiltIn ? "本地" : $0.name }
        #expect(TranslationChannelSwitcher.buttonLabel(selected: [], emptyLabel: "选择频道", displayName: display) == "选择频道")
        #expect(TranslationChannelSwitcher.buttonLabel(selected: [.local], emptyLabel: "选择频道", displayName: display) == "本地")
        #expect(
            TranslationChannelSwitcher.buttonLabel(
                selected: [.local, ChannelRef(name: "A"), ChannelRef(name: "B")],
                emptyLabel: "选择频道",
                displayName: display
            ) == "本地 +2"
        )
    }

    @Test("DiscoveredChannel.hasListener 不区分大小写与首尾空白")
    func discoveredChannelHasListener() {
        let channel = Self.discovered(id: "player_1", name: "Ops", lastModified: 100, listeners: ["Longge Jiang"])
        #expect(channel.hasListener("longge jiang"))
        #expect(channel.hasListener("  LONGGE JIANG  "))
        #expect(!channel.hasListener(""))
        #expect(!channel.hasListener("Other Pilot"))
    }
}
