// SPDX-License-Identifier: GPL-3.0-or-later
//
// HotkeyPlanner 的用例（架构文档 5.5 节、10.2 节，反馈文档 6.3 节、10.1 节）。

import Testing
import EVEOPreviewCore

/// 热键规划：编号顺序、重复的取舍、缺修饰键、系统保留、无法解析。
struct HotkeyPlannerTests {
    /// 解析热键字符串，测试里的写法都合法。
    private func key(_ text: String) -> Hotkey {
        Hotkey(string: text)!
    }

    /// 编号顺序：全局三项、循环组（先前进后后退）、按角色名排序的角色热键，id 从 1 起连续。
    @Test func numberingOrder() {
        var profile = Profile(name: "P")
        profile.hotkeys = GeneralHotkeys(toggleHideAll: ["ctrl+H"], minimizeAll: ["ctrl+M"],
                                         cycleLoginClients: ["ctrl+L"])
        profile.cycleGroups = [
            CycleGroup(id: "g1", name: "1", forwardHotkeys: ["F13"], backwardHotkeys: ["shift+F13"]),
            CycleGroup(id: "g2", name: "2", forwardHotkeys: ["F14", "ctrl+F14"], backwardHotkeys: []),
        ]
        profile.characterHotkeys = ["zed": ["ctrl+Z"], "Alpha": ["ctrl+A"], "beta": ["ctrl+B"]]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.issues.isEmpty)
        #expect(plan.bindings.map(\.id) == Array(1...10))
        #expect(plan.bindings.map(\.action) == [
            .toggleHideAll, .minimizeAll, .cycleLoginClients,
            .cycle(groupID: "g1", direction: .forward), .cycle(groupID: "g1", direction: .backward),
            .cycle(groupID: "g2", direction: .forward), .cycle(groupID: "g2", direction: .forward),
            .activateCharacter("Alpha"), .activateCharacter("beta"), .activateCharacter("zed"),
        ])
        #expect(plan.binding(withID: 2)?.hotkey == key("ctrl+M"))
    }

    /// 重复：先出现的生效，后出现的记为 duplicate，不占编号。
    @Test func duplicates() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["ctrl+F1"]
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", forwardHotkeys: ["Ctrl+f1", "ctrl+F2"])]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("ctrl+F1"), key("ctrl+F2")])
        #expect(plan.bindings.map(\.id) == [1, 2])
        #expect(plan.issues == [.duplicate(hotkey: key("ctrl+F1"), kept: .toggleHideAll,
                                           dropped: .cycle(groupID: "g", direction: .forward))])
    }

    /// 缺修饰键：只有 shift 或没有修饰键时，只允许 F1～F20 与 Num0～Num9。
    @Test func missingModifier() {
        var profile = Profile(name: "P")
        profile.hotkeys.minimizeAll = ["A", "shift+A", "F20", "shift+Num0", "opt+A", "Num9"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("F20"), key("shift+Num0"), key("opt+A"), key("Num9")])
        #expect(plan.issues == [
            .rejected(hotkey: key("A"), action: .minimizeAll, reason: .missingModifier),
            .rejected(hotkey: key("shift+A"), action: .minimizeAll, reason: .missingModifier),
        ])
    }

    /// 系统保留：cmd 或 cmd+shift 加 Tab、Space、Q、W、H、M、Grave；加了别的修饰键就不算。
    @Test func systemReserved() {
        let reserved = ["cmd+Tab", "cmd+Space", "cmd+Q", "cmd+W", "cmd+H", "cmd+M", "cmd+Grave",
                        "shift+cmd+Tab", "cmd+shift+Grave"]
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = reserved + ["ctrl+cmd+Q", "opt+cmd+Tab", "cmd+E"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("ctrl+cmd+Q"), key("opt+cmd+Tab"), key("cmd+E")])
        #expect(plan.issues == reserved.map {
            .rejected(hotkey: key($0), action: .toggleHideAll, reason: .systemReserved)
        })
    }

    /// 无法解析的字符串记为 unparsable，原文保留；被拒绝的热键不参与重复判断。
    @Test func unparsableAndRejectedDoNotBlock() {
        var profile = Profile(name: "P")
        profile.characterHotkeys = ["Pilot Alpha": ["ctrl+Nope", "A"], "bravo pilot": ["A", "ctrl+A"]]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.action) == [.activateCharacter("bravo pilot")])
        // 角色名按 Unicode 码位排序：大写的 R 排在小写的 l 之前。
        #expect(plan.issues == [
            .unparsable(text: "ctrl+Nope", action: .activateCharacter("Pilot Alpha")),
            .rejected(hotkey: key("A"), action: .activateCharacter("Pilot Alpha"), reason: .missingModifier),
            .rejected(hotkey: key("A"), action: .activateCharacter("bravo pilot"), reason: .missingModifier),
        ])
    }

    /// 空配置方案没有绑定也没有问题。
    @Test func emptyProfile() {
        #expect(HotkeyPlanner.plan(for: Profile(name: "P")) == HotkeyPlan(bindings: [], issues: []))
    }

    // MARK: - 作用范围与鼠标（反馈文档 6.3 节）

    /// 没有后缀的绑定取配置方案的默认范围；后缀覆盖默认范围。
    @Test(arguments: HotkeyScope.allCases)
    func defaultScopeAndSuffix(defaultScope: HotkeyScope) {
        var profile = Profile(name: "P")
        profile.hotkeyDefaultScope = defaultScope
        profile.hotkeys.toggleHideAll = ["ctrl+F1", "ctrl+F2@game", "ctrl+F3@GLOBAL"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.issues.isEmpty)
        #expect(plan.bindings.map(\.scope) == [defaultScope, .game, .global])
        #expect(plan.bindings.map(\.hotkey) == [key("ctrl+F1"), key("ctrl+F2"), key("ctrl+F3")])
    }

    /// 不带修饰键的鼠标触发键被接受；带修饰键的也接受，不受系统保留名单影响。
    @Test func mouseWithoutModifierAccepted() {
        var profile = Profile(name: "P")
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", forwardHotkeys: ["Mouse4", "cmd+Mouse5@game"],
                                          backwardHotkeys: ["Mouse3"])]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.issues.isEmpty)
        #expect(plan.bindings.map(\.hotkey) == [key("Mouse4"), key("cmd+Mouse5"), key("Mouse3")])
        #expect(plan.bindings.map(\.scope) == [.global, .game, .global])
        #expect(HotkeyPlanner.rejection(for: key("Mouse4")) == nil)
    }

    /// 同一热键、不同作用范围记为重复，后出现的被丢弃。
    @Test func sameHotkeyDifferentScopeIsDuplicate() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["F13@game"]
        profile.hotkeys.minimizeAll = ["F13@global", "Mouse4@game"]
        profile.hotkeys.cycleLoginClients = ["mouse4"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("F13"), key("Mouse4")])
        #expect(plan.bindings.map(\.id) == [1, 2])
        #expect(plan.issues == [
            .duplicate(hotkey: key("F13"), kept: .toggleHideAll, dropped: .minimizeAll),
            .duplicate(hotkey: key("Mouse4"), kept: .minimizeAll, dropped: .cycleLoginClients),
        ])
    }

    /// 键盘与鼠标的触发键互不重复，即使数字相同（Key3 与 Mouse4 的按钮号都是 3）。
    @Test func keyboardAndMouseNeverDuplicate() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["ctrl+Key3"]
        profile.hotkeys.minimizeAll = ["ctrl+Mouse4"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.issues.isEmpty)
        #expect(plan.bindings.count == 2)
    }

    /// Mouse1、Mouse2 与非法的后缀记为 unparsable，原文保留，不占编号。
    @Test func invalidMouseAndSuffixUnparsable() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["Mouse1", "Mouse2", "F13@foo", "@game", "Mouse5"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("Mouse5")])
        #expect(plan.bindings.map(\.id) == [1])
        #expect(plan.issues == ["Mouse1", "Mouse2", "F13@foo", "@game"].map {
            .unparsable(text: $0, action: .toggleHideAll)
        })
    }

    /// 编号顺序不受作用范围与鼠标触发键影响：被拒绝或重复的不占编号，其余从 1 起连续。
    @Test func numberingWithMixedTriggers() {
        var profile = Profile(name: "P")
        profile.hotkeyDefaultScope = .game
        profile.hotkeys = GeneralHotkeys(toggleHideAll: ["Mouse4"], minimizeAll: ["A", "ctrl+M@global"],
                                         cycleLoginClients: ["Mouse4@global"])
        profile.characterHotkeys = ["b": ["Mouse5"], "a": ["ctrl+Mouse5"]]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.id) == [1, 2, 3, 4])
        #expect(plan.bindings.map(\.action) == [.toggleHideAll, .minimizeAll, .activateCharacter("a"),
                                                 .activateCharacter("b")])
        #expect(plan.bindings.map(\.scope) == [.game, .global, .game, .game])
        #expect(plan.issues.count == 2)
    }
}
