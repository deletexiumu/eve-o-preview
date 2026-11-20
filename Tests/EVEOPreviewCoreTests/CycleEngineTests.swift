// SPDX-License-Identifier: GPL-3.0-or-later
//
// CycleEngine 的用例（架构文档 5.4 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 循环顺序：前进后退、绕回、跳过、离线、不在组内、全部不可用、唯一可用、去重后的成员、登录循环。
struct CycleEngineTests {
    private let members = ["A", "B", "C", "D"]
    private let allRunning: Set<String> = ["A", "B", "C", "D"]

    /// 简写：在 members 里找下一个。
    private func next(_ direction: CycleDirection, from active: String?, running: Set<String>? = nil,
                      skipped: Set<String> = [], in list: [String]? = nil) -> String? {
        CycleEngine.next(in: list ?? members, direction: direction, active: active,
                         running: running ?? allRunning, skipped: skipped)
    }

    /// 前进与后退各走一步。
    @Test func forwardAndBackward() {
        #expect(next(.forward, from: "B") == "C")
        #expect(next(.backward, from: "B") == "A")
    }

    /// 到头后绕回。
    @Test func wrapsAround() {
        #expect(next(.forward, from: "D") == "A")
        #expect(next(.backward, from: "A") == "D")
    }

    /// 被跳过的成员不参与。
    @Test func skipsSkipped() {
        #expect(next(.forward, from: "A", skipped: ["B", "C"]) == "D")
        #expect(next(.backward, from: "A", skipped: ["D"]) == "C")
    }

    /// 不在运行的成员（离线）不参与。
    @Test func skipsOffline() {
        #expect(next(.forward, from: "A", running: ["A", "D"]) == "D")
    }

    /// active 不在组内或为 nil 时，从该方向的第一个成员开始找。
    @Test func activeNotInGroup() {
        #expect(next(.forward, from: "Z") == "A")
        #expect(next(.backward, from: "Z") == "D")
        #expect(next(.forward, from: nil, running: ["C", "D"]) == "C")
        #expect(next(.backward, from: nil, skipped: ["D"]) == "C")
    }

    /// active 自己被跳过时仍以它的位置为起点。
    @Test func activeSkippedKeepsPosition() {
        #expect(next(.forward, from: "B", skipped: ["B"]) == "C")
        #expect(next(.backward, from: "B", skipped: ["B"]) == "A")
    }

    /// 全部不可用时返回 nil；空组也返回 nil。
    @Test func noneAvailable() {
        #expect(next(.forward, from: "A", running: []) == nil)
        #expect(next(.forward, from: "A", skipped: allRunning) == nil)
        #expect(next(.forward, from: nil, in: []) == nil)
    }

    /// 唯一可用的成员就是 active 时返回它自己。
    @Test func onlyActiveAvailable() {
        #expect(next(.forward, from: "B", running: ["B"]) == "B")
        #expect(next(.backward, from: "B", running: ["B", "C"], skipped: ["C"]) == "B")
    }

    /// 重复成员由 ConfigValidator 去掉（5.4 节），引擎拿到的是去重后的列表：
    /// 配置里的 A、B、A、C 变成 A、B、C，前进依次是 B、C、A。
    @Test func duplicateMembers() {
        var profile = Profile(id: "p", name: "P")
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", members: ["A", "B", "A", "C"])]
        let config = ConfigValidator.normalized(AppConfig(activeProfileID: "p", profiles: [profile])).config
        let list = config.profiles[0].cycleGroups[0].members
        #expect(list == ["A", "B", "C"])
        #expect(next(.forward, from: "A", in: list) == "B")
        #expect(next(.forward, from: "B", in: list) == "C")
        #expect(next(.forward, from: "C", in: list) == "A")
        #expect(next(.backward, from: "A", in: list) == "C")
    }

    /// 登录循环：PID 先升序，前进与后退各取下一个并绕回。
    @Test func loginCycleOrderAndWrap() {
        let pids: [Int32] = [300, 100, 200]
        #expect(CycleEngine.nextLoginClient(pids: pids, activePID: 100, direction: .forward) == 200)
        #expect(CycleEngine.nextLoginClient(pids: pids, activePID: 300, direction: .forward) == 100)
        #expect(CycleEngine.nextLoginClient(pids: pids, activePID: 100, direction: .backward) == 300)
    }

    /// 登录循环：activePID 不在其中时取该方向的第一个；空数组返回 nil；只有一个时返回它自己。
    @Test func loginCycleEdgeCases() {
        let pids: [Int32] = [300, 100, 200]
        #expect(CycleEngine.nextLoginClient(pids: pids, activePID: nil, direction: .forward) == 100)
        #expect(CycleEngine.nextLoginClient(pids: pids, activePID: 999, direction: .backward) == 300)
        #expect(CycleEngine.nextLoginClient(pids: [], activePID: 1, direction: .forward) == nil)
        #expect(CycleEngine.nextLoginClient(pids: [7], activePID: 7, direction: .forward) == 7)
    }
}
