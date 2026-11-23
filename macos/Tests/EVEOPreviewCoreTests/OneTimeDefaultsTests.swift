// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「全部隐藏」默认热键 ⌃⌥⌘H 的用例：新建配置与配置方案带上它，已有配置按 OneTimeDefaults 补一次。

import Foundation
import Testing
import EVEOPreviewCore

/// 新默认值与一次性补齐。
struct OneTimeDefaultsTests {
    /// 默认热键能解析，是全局生效的 ⌃⌥⌘H，并且能通过热键规划（不缺修饰键、不是系统保留）。
    @Test func defaultHotkeyIsGlobalCtrlOptCmdH() throws {
        let spec = try #require(HotkeySpec(string: GeneralHotkeys.defaultToggleHideAll))
        #expect(spec.hotkey == Hotkey(string: "ctrl+opt+cmd+H"))
        #expect(spec.scope == .global)
        #expect(HotkeyPlanner.rejection(for: spec.hotkey) == nil)
        // 写法是规范写法，存进配置后再读出来不变。
        #expect(spec.stringValue() == GeneralHotkeys.defaultToggleHideAll)
    }

    /// 新建配置文件、新建配置方案都带默认热键；手工构造的 Profile 与解码缺键时仍为空。
    @Test func newProfilesCarryDefaultHotkey() throws {
        let config = AppConfig.makeDefault()
        #expect(config.profiles[0].hotkeys.toggleHideAll == [GeneralHotkeys.defaultToggleHideAll])
        let added = try #require(ProfileEditor.add(named: "Second", to: config))
        #expect(added.profiles[1].hotkeys.toggleHideAll == [GeneralHotkeys.defaultToggleHideAll])
        #expect(Profile(name: "X").hotkeys.toggleHideAll.isEmpty)
        let decoded = try JSONDecoder().decode(GeneralHotkeys.self, from: Data("{}".utf8))
        #expect(decoded.toggleHideAll.isEmpty)
    }

    /// 默认配置的热键规划里，⌃⌥⌘H 是唯一一条绑定，动作是「全部隐藏」，作用范围全局。
    @Test func defaultConfigPlansGlobalBinding() {
        var profile = AppConfig.makeDefault().profiles[0]
        // 即使配置方案的默认范围是仅游戏内，带后缀的默认热键也是全局的。
        profile.hotkeyDefaultScope = .game
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.issues.isEmpty)
        #expect(plan.bindings.map(\.action) == [.toggleHideAll])
        #expect(plan.bindings.first?.scope == .global)
    }

    /// 还没补过的项按 `all` 的顺序列出；补过的不再列出。
    @Test func pendingSkipsApplied() {
        #expect(OneTimeDefaults.pending(applied: []) == OneTimeDefaults.all)
        #expect(OneTimeDefaults.pending(applied: [OneTimeDefaults.toggleHideAllHotkey])
                == [OneTimeDefaults.highlightActiveClient])
        #expect(OneTimeDefaults.pending(applied: OneTimeDefaults.all).isEmpty)
        #expect(OneTimeDefaults.pending(applied: ["unknown"]) == OneTimeDefaults.all)
    }

    /// 已有配置：「全部隐藏」没有热键的方案补上；已有热键的方案不动；不认识的 id 不改配置。
    @Test func applyFillsOnlyEmptyLists() {
        var empty = Profile(id: "a", name: "A")
        empty.hotkeys.minimizeAll = ["ctrl+M"]
        var custom = Profile(id: "b", name: "B")
        custom.hotkeys.toggleHideAll = ["F13@game"]
        let config = AppConfig(activeProfileID: "a", profiles: [empty, custom])

        let result = OneTimeDefaults.apply([OneTimeDefaults.toggleHideAllHotkey], to: config)
        #expect(result.profiles[0].hotkeys.toggleHideAll == [GeneralHotkeys.defaultToggleHideAll])
        #expect(result.profiles[0].hotkeys.minimizeAll == ["ctrl+M"])
        #expect(result.profiles[1].hotkeys.toggleHideAll == ["F13@game"])
        #expect(OneTimeDefaults.apply(["unknown"], to: config) == config)
    }

    /// ⌃⌥⌘H 已被其他动作占用（不论写法与作用范围）时不补，避免出现重复提示。
    @Test func applySkipsWhenComboTaken() {
        var group = Profile(id: "a", name: "A")
        group.cycleGroups = [CycleGroup(id: "g", name: "G", forwardHotkeys: ["cmd+opt+ctrl+h@game"])]
        var character = Profile(id: "b", name: "B")
        character.characterHotkeys = ["Pilot": ["ctrl+opt+cmd+H"]]
        let config = AppConfig(activeProfileID: "a", profiles: [group, character])

        let result = OneTimeDefaults.apply([OneTimeDefaults.toggleHideAllHotkey], to: config)
        #expect(result.profiles.allSatisfy { $0.hotkeys.toggleHideAll.isEmpty })
    }

    /// 「高亮活动客户端」：每个配置方案都打开，颜色与粗细不动；重复补一次结果不变；不影响热键。
    @Test func applyTurnsOnHighlightForAllProfiles() {
        var off = Profile(id: "a", name: "A")
        off.overlay.highlightEnabled = false
        off.overlay.highlightColor = "#123456"
        off.overlay.highlightThickness = 5
        var alsoOff = Profile(id: "b", name: "B")
        alsoOff.overlay.highlightEnabled = false
        let config = AppConfig(activeProfileID: "a", profiles: [off, alsoOff])

        let result = OneTimeDefaults.apply([OneTimeDefaults.highlightActiveClient], to: config)
        #expect(result.profiles.allSatisfy { $0.overlay.highlightEnabled })
        #expect(result.profiles[0].overlay.highlightColor == "#123456")
        #expect(result.profiles[0].overlay.highlightThickness == 5)
        #expect(result.profiles.map(\.hotkeys) == config.profiles.map(\.hotkeys))
        #expect(OneTimeDefaults.apply([OneTimeDefaults.highlightActiveClient], to: result) == result)
    }

    /// 补过的项记在 state.json 的 appliedDefaults 里；旧的状态文件没有这个键时为空。
    @Test func appStateRoundTripsAppliedDefaults() throws {
        let state = AppState(appliedDefaults: [OneTimeDefaults.toggleHideAllHotkey])
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AppState.self, from: data) == state)
        let old = try JSONDecoder().decode(AppState.self, from: Data(#"{"stateVersion":1}"#.utf8))
        #expect(old.appliedDefaults.isEmpty)
    }
}
