// SPDX-License-Identifier: GPL-3.0-or-later
//
// VisibilityRules 的用例（架构文档 5.6 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 可见性：4 条规则各自与组合、.selfApp 不触发隐藏、延迟未到与已到、hideDeadline。
struct VisibilityRulesTests {
    private let pilotA = Fixtures.character(Fixtures.pilotAlpha, id: 1, pid: Fixtures.pidA)
    private let login = Fixtures.client(2, pid: Fixtures.pidB, .login)

    /// 构造输入：可修改配置方案与会话，默认前台是其他应用，now = 100。
    private func input(frontmost: FrontmostContext = .other, now: Double = 100,
                       profile edit: (inout Profile) -> Void = { _ in },
                       session sessionEdit: (inout SessionState) -> Void = { _ in }) -> PlannerInput {
        var profile = Profile(name: "T")
        edit(&profile)
        var session = SessionState(lastEVEContextAt: 99)
        sessionEdit(&session)
        return Fixtures.plannerInput(clients: [pilotA, login], profile: profile, frontmost: frontmost,
                                     session: session, now: now)
    }

    /// 默认设置下全部可见，没有定时重算。
    @Test func visibleByDefault() {
        let i = input()
        #expect(VisibilityRules.isVisible(client: pilotA, input: i))
        #expect(VisibilityRules.isVisible(client: login, input: i))
        #expect(VisibilityRules.hideDeadline(input: i) == nil)
    }

    /// 规则 1：全部隐藏。
    @Test func hideAll() {
        let i = input(session: { $0.hideAll = true })
        #expect(!VisibilityRules.isVisible(client: pilotA, input: i))
        #expect(!VisibilityRules.isVisible(client: login, input: i))
    }

    /// 规则 2：按角色隐藏，区分大小写；登录客户端不受影响。
    @Test func hiddenCharacter() {
        let i = input(profile: { $0.hiddenCharacters = [Fixtures.pilotAlpha, "EVE"] })
        #expect(!VisibilityRules.isVisible(client: pilotA, input: i))
        #expect(VisibilityRules.isVisible(client: login, input: i))
        let other = input(profile: { $0.hiddenCharacters = ["pilot alpha"] })
        #expect(VisibilityRules.isVisible(client: pilotA, input: other))
    }

    /// 规则 3：隐藏活动客户端，只看前台，不看 lastActivePID。
    @Test func hideActiveClient() {
        let front = input(frontmost: .client(pid: Fixtures.pidA), profile: { $0.behavior.hideActiveClientThumbnail = true })
        #expect(!VisibilityRules.isVisible(client: pilotA, input: front))
        #expect(VisibilityRules.isVisible(client: login, input: front))
        let away = input(frontmost: .other, profile: { $0.behavior.hideActiveClientThumbnail = true },
                         session: { $0.lastActivePID = Fixtures.pidA })
        #expect(VisibilityRules.isVisible(client: pilotA, input: away))
        // 设置关闭时不隐藏。
        #expect(VisibilityRules.isVisible(client: pilotA, input: input(frontmost: .client(pid: Fixtures.pidA))))
    }

    /// 规则 4：前台是其他应用且延迟已到时隐藏；恰好到期也算。
    @Test func hideWhenNotFrontmostElapsed() {
        let enable: (inout Profile) -> Void = { $0.behavior.hideWhenEVENotFrontmost = true }
        let elapsed = input(now: 100.5, profile: enable)          // 99 + 1.0 ≤ 100.5
        #expect(!VisibilityRules.isVisible(client: pilotA, input: elapsed))
        #expect(VisibilityRules.hideDeadline(input: elapsed) == nil)
        let exact = input(now: 100, profile: enable)              // 恰好 1.0 秒
        #expect(!VisibilityRules.isVisible(client: pilotA, input: exact))
    }

    /// 规则 4：延迟未到时仍可见，hideDeadline 返回到期时刻。
    @Test func hideWhenNotFrontmostPending() {
        let pending = input(now: 99.4, profile: { $0.behavior.hideWhenEVENotFrontmost = true })
        #expect(VisibilityRules.isVisible(client: pilotA, input: pending))
        #expect(VisibilityRules.hideDeadline(input: pending) == 100)
    }

    /// 前台是本应用或客户端时，规则 4 不触发，也没有定时重算。
    @Test func selfAppAndClientDoNotHide() {
        for frontmost in [FrontmostContext.selfApp, .client(pid: Fixtures.pidB)] {
            let i = input(frontmost: frontmost, now: 500, profile: { $0.behavior.hideWhenEVENotFrontmost = true })
            #expect(VisibilityRules.isVisible(client: pilotA, input: i))
            #expect(VisibilityRules.hideDeadline(input: i) == nil)
        }
    }

    /// 组合：规则 3 与规则 4 同时打开时，各自按自己的条件生效。
    @Test func combinedRules() {
        let edit: (inout Profile) -> Void = {
            $0.behavior.hideActiveClientThumbnail = true
            $0.behavior.hideWhenEVENotFrontmost = true
            $0.behavior.hideDelaySeconds = 0
        }
        let onClient = input(frontmost: .client(pid: Fixtures.pidA), profile: edit)
        #expect(!VisibilityRules.isVisible(client: pilotA, input: onClient))
        #expect(VisibilityRules.isVisible(client: login, input: onClient))
        let away = input(frontmost: .other, profile: edit)
        #expect(!VisibilityRules.isVisible(client: pilotA, input: away))
        #expect(!VisibilityRules.isVisible(client: login, input: away))
    }
}

// MARK: - 第一轮反馈：战斗提醒的可见性例外（反馈文档 7.7 节）

extension VisibilityRulesTests {
    /// 给 pilotA 一条到 until 为止的提醒。
    private func alert(until: Double) -> (inout SessionState) -> Void {
        { [pilotA] in $0.combatAlerts = [pilotA.id: CombatAlertWindow(startedAt: 98, until: until)] }
    }

    /// 有未到期的提醒时，第 4 条规则不隐藏该客户端，其他客户端照常隐藏。
    @Test func alertOverridesRule4() {
        let i = input(now: 101, profile: { $0.behavior.hideWhenEVENotFrontmost = true }, session: alert(until: 102))
        #expect(VisibilityRules.isVisible(client: pilotA, input: i))
        #expect(!VisibilityRules.isVisible(client: login, input: i))
    }

    /// 第 1～3 条不受提醒影响。
    @Test func alertDoesNotOverrideRules1To3() {
        let hideAll = input(session: { session in
            self.alert(until: 200)(&session)
            session.hideAll = true
        })
        #expect(!VisibilityRules.isVisible(client: pilotA, input: hideAll))
        let hidden = input(profile: { $0.hiddenCharacters = [Fixtures.pilotAlpha] }, session: alert(until: 200))
        #expect(!VisibilityRules.isVisible(client: pilotA, input: hidden))
        let active = input(frontmost: .client(pid: Fixtures.pidA),
                           profile: { $0.behavior.hideActiveClientThumbnail = true }, session: alert(until: 200))
        #expect(!VisibilityRules.isVisible(client: pilotA, input: active))
    }

    /// 提醒到期（now >= until）后恢复原规则。
    @Test func expiredAlertRestoresRule4() {
        let enable: (inout Profile) -> Void = { $0.behavior.hideWhenEVENotFrontmost = true }
        let exact = input(now: 102, profile: enable, session: alert(until: 102))
        #expect(!VisibilityRules.isVisible(client: pilotA, input: exact))
        let later = input(now: 110, profile: enable, session: alert(until: 102))
        #expect(!VisibilityRules.isVisible(client: pilotA, input: later))
    }
}
