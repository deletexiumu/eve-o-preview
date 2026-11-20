// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键规划、循环与客户端登记的补充用例（架构文档 5.3 节、5.4 节、5.5 节）。测试方于 2026-11-20 补写，
// 覆盖原有用例没有检查的边界：同一列表内与同组前进后退之间的重复、角色热键按名字排序后的取舍、
// 不同写法的同一热键、拒绝后编号连续、V7 的 opt+F13；循环里 active 被跳过且是唯一在线成员、
// 重复成员经校验去重后连按前进能否走遍全部成员；登记里改名与移动同时发生、输入里重复的窗口 ID。

import Testing
import EVEOPreviewCore

/// HotkeyPlanner 的边界用例。
struct HotkeyPlannerEdgeCaseTests {
    /// 解析热键字符串，测试里的写法都合法。
    private func key(_ text: String) -> Hotkey {
        Hotkey(string: text)!
    }

    /// 同一个动作的列表里写了两次：第二次记为 duplicate，kept 与 dropped 是同一个动作。
    @Test func duplicateWithinOneList() {
        var profile = Profile(name: "P")
        profile.hotkeys.minimizeAll = ["ctrl+F1", "CTRL+f1"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.id) == [1])
        #expect(plan.issues == [.duplicate(hotkey: key("ctrl+F1"), kept: .minimizeAll, dropped: .minimizeAll)])
    }

    /// 同一循环组的前进与后退用了同一个热键：前进先出现，后退被丢弃。
    @Test func forwardBeatsBackwardOfSameGroup() {
        var profile = Profile(name: "P")
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", forwardHotkeys: ["ctrl+F2"], backwardHotkeys: ["ctrl+F2"])]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.action) == [.cycle(groupID: "g", direction: .forward)])
        #expect(plan.issues == [.duplicate(hotkey: key("ctrl+F2"), kept: .cycle(groupID: "g", direction: .forward),
                                           dropped: .cycle(groupID: "g", direction: .backward))])
    }

    /// 两个角色用了同一个热键：按角色名排序后先出现的生效（Amy 在 Zed 之前），与字典的写入顺序无关。
    @Test func duplicateAcrossCharactersSortedByName() {
        var profile = Profile(name: "P")
        profile.characterHotkeys = ["Zed": ["ctrl+1"], "Amy": ["ctrl+1"]]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.action) == [.activateCharacter("Amy")])
        #expect(plan.issues == [.duplicate(hotkey: key("ctrl+1"), kept: .activateCharacter("Amy"),
                                           dropped: .activateCharacter("Zed"))])
    }

    /// 不同写法的同一热键算重复：`alt+f1` 与 `opt+F1`；`Key105` 与 `F13`（F13 的键码是 105）。
    @Test func aliasSpellingsAreDuplicates() {
        var profile = Profile(name: "P")
        profile.hotkeys = GeneralHotkeys(toggleHideAll: ["alt+f1", "F13"], minimizeAll: ["opt+F1"],
                                         cycleLoginClients: ["Key105"])
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("opt+F1"), key("F13")])
        #expect(plan.issues == [
            .duplicate(hotkey: key("opt+F1"), kept: .toggleHideAll, dropped: .minimizeAll),
            .duplicate(hotkey: key("F13"), kept: .toggleHideAll, dropped: .cycleLoginClients),
        ])
    }

    /// 被拒绝、无法解析、重复的热键不占编号；通过的绑定跨动作从 1 起连续编号，问题按遍历顺序排列。
    @Test func idsStayContiguousAfterRejects() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["A", "ctrl+A", "nope", "cmd+Q", "ctrl+B"]
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", forwardHotkeys: ["ctrl+A", "ctrl+C"])]
        profile.characterHotkeys = ["Amy": ["", "ctrl+D"]]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.id) == [1, 2, 3, 4])
        #expect(plan.bindings.map(\.hotkey) == [key("ctrl+A"), key("ctrl+B"), key("ctrl+C"), key("ctrl+D")])
        #expect(plan.issues == [
            .rejected(hotkey: key("A"), action: .toggleHideAll, reason: .missingModifier),
            .unparsable(text: "nope", action: .toggleHideAll),
            .rejected(hotkey: key("cmd+Q"), action: .toggleHideAll, reason: .systemReserved),
            .duplicate(hotkey: key("ctrl+A"), kept: .toggleHideAll, dropped: .cycle(groupID: "g", direction: .forward)),
            .unparsable(text: "", action: .activateCharacter("Amy")),
        ])
    }

    /// 修饰键规则的边界：opt+F13（V7）与 shift+F13 可用；只带 shift 的普通键、单独的 Space 缺修饰键；
    /// cmd+shift+Q 是系统保留，cmd+opt+shift+W 不是；Key105 即 F13，可以不带修饰键。
    @Test func modifierRuleBoundaries() {
        #expect(HotkeyPlanner.rejection(for: key("opt+F13")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("shift+F13")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("Key105")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("ctrl+shift+F13")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("shift+Tab")) == .missingModifier)
        #expect(HotkeyPlanner.rejection(for: key("Space")) == .missingModifier)
        #expect(HotkeyPlanner.rejection(for: key("shift+Num0")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("cmd+shift+Q")) == .systemReserved)
        #expect(HotkeyPlanner.rejection(for: key("cmd+opt+shift+W")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("cmd+1")) == nil)
    }
}

/// CycleEngine 的边界用例。
struct CycleEngineEdgeCaseTests {
    /// active 自己被跳过，且它是唯一在线的成员：没有符合条件的成员，返回 nil。
    @Test func skippedActiveAloneGivesNil() {
        let result = CycleEngine.next(in: ["A", "B", "C"], direction: .forward, active: "B",
                                      running: ["B"], skipped: ["B"])
        #expect(result == nil)
    }

    /// 只有一个成员的组：active 为 nil 或就是它时都返回它；后退同样。
    @Test func singleMemberGroup() {
        for direction in [CycleDirection.forward, .backward] {
            #expect(CycleEngine.next(in: ["A"], direction: direction, active: nil, running: ["A"], skipped: []) == "A")
            #expect(CycleEngine.next(in: ["A"], direction: direction, active: "A", running: ["A"], skipped: []) == "A")
        }
    }

    /// 配置里写成 A、B、A、C 的组经校验后成员是 A、B、C（5.4 节）。
    private func dedupedMembers(_ members: [String]) -> [String] {
        var profile = Profile(id: "p", name: "P")
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", members: members)]
        let config = AppConfig(activeProfileID: "p", profiles: [profile])
        return ConfigValidator.normalized(config).config.profiles[0].cycleGroups[0].members
    }

    /// 重复成员去重后后退：从 C 后退到 B，从 A 后退绕回 C。
    @Test func backwardWithDuplicates() {
        let list = dedupedMembers(["A", "B", "A", "C"])
        #expect(list == ["A", "B", "C"])
        let all: Set<String> = ["A", "B", "C"]
        #expect(CycleEngine.next(in: list, direction: .backward, active: "C", running: all, skipped: []) == "B")
        #expect(CycleEngine.next(in: list, direction: .backward, active: "A", running: all, skipped: []) == "C")
    }

    /// 规格 5.4 节（2026-11-20 改定）：校验去掉重复成员，所以连按前进能走遍全部在线成员。
    /// 原规则下 A、B、A、C 从 A 连按前进是 B、A、B、A……，C 永远轮不到，曾记为已知问题。
    @Test func repeatedForwardVisitsEveryMember() {
        let list = dedupedMembers(["A", "B", "A", "C"])
        let all: Set<String> = ["A", "B", "C"]
        var active = "A"
        var visited: Set<String> = [active]
        for _ in 0..<list.count * 2 {
            guard let next = CycleEngine.next(in: list, direction: .forward, active: active,
                                              running: all, skipped: []) else { break }
            visited.insert(next)
            active = next
        }
        #expect(visited == all)
    }

    /// 登录循环：后退时从最小的 PID 绕回最大的；只有一个时前进后退都返回它自己。
    @Test func loginCycleBackwardWrapAndSingle() {
        #expect(CycleEngine.nextLoginClient(pids: [300, 100, 200], activePID: 100, direction: .backward) == 300)
        #expect(CycleEngine.nextLoginClient(pids: [300, 100, 200], activePID: nil, direction: .backward) == 300)
        #expect(CycleEngine.nextLoginClient(pids: [7], activePID: 7, direction: .backward) == 7)
        #expect(CycleEngine.nextLoginClient(pids: [7], activePID: nil, direction: .forward) == 7)
    }
}

/// ClientRegistry 的边界用例。
struct ClientRegistryEdgeCaseTests {
    /// 登录后改名的同时窗口也移动了：只记为 renamed（after 带新的位置），不重复记进 updated。
    @Test func renameAndMoveInSameTick() {
        var registry = ClientRegistry()
        registry.update(with: [Fixtures.window(1, 10, "EVE", x: 0, y: 0, w: 1728, h: 1018)])
        let diff = registry.update(with: [Fixtures.window(1, 10, "EVE - Pilot Alpha", x: 50, y: 60, w: 1728, h: 1018)])
        #expect(diff.renamed.count == 1 && diff.updated.isEmpty && diff.added.isEmpty && diff.removed.isEmpty)
        #expect(diff.renamed.first?.after.windowFrame.origin == ScreenPoint(x: 50, y: 60))
        #expect(registry.clients.first?.characterName == "Pilot Alpha")
    }

    /// 输入里同一个窗口 ID 出现两次时只登记第一次出现的那个。
    @Test func duplicateWindowIDInInput() {
        var registry = ClientRegistry()
        let diff = registry.update(with: [
            Fixtures.window(1, 10, "EVE - First", x: 0, y: 0, w: 1728, h: 1018),
            Fixtures.window(1, 10, "EVE - Second", x: 0, y: 0, w: 1728, h: 1018),
        ])
        #expect(diff.added.map(\.characterName) == ["First"])
        #expect(registry.clients.count == 1)
    }

    /// 已登记的客户端保持原顺序；新客户端按本轮输入的顺序追加在后面。
    @Test func newClientsAppendedInInputOrder() {
        var registry = ClientRegistry()
        registry.update(with: [Fixtures.window(2, 20, "EVE - B", x: 0, y: 0, w: 1728, h: 1018)])
        registry.update(with: [
            Fixtures.window(9, 90, "EVE - Z", x: 0, y: 0, w: 1728, h: 1018),
            Fixtures.window(2, 20, "EVE - B", x: 0, y: 0, w: 1728, h: 1018),
            Fixtures.window(5, 50, "EVE - E", x: 0, y: 0, w: 1728, h: 1018),
        ])
        #expect(registry.clients.map(\.id.rawValue) == [2, 9, 5])
    }

    /// 最小化状态从 nil（没有辅助功能权限）变成 true 也算 updated。
    @Test func minimizedStateChangeIsUpdate() {
        var registry = ClientRegistry()
        registry.update(with: [Fixtures.window(1, 10, "EVE - A", x: 0, y: 0, w: 1728, h: 1018, minimized: nil)])
        let diff = registry.update(with: [Fixtures.window(1, 10, "EVE - A", x: 0, y: 0, w: 1728, h: 1018,
                                                          onScreen: false, minimized: true)])
        #expect(diff.updated.count == 1 && diff.renamed.isEmpty)
        #expect(registry.clients.first?.isMinimized == true)
    }
}
