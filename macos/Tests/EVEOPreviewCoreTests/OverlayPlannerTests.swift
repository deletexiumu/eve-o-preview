// SPDX-License-Identifier: GPL-3.0-or-later
//
// OverlayPlanner 的用例（docs/macos/design-intel-translate.md 8.6 节、14.1 节）。
// 角色名用 Fixtures 里虚构的名字。

import Foundation
import Testing
import EVEOPreviewCore

/// 浮窗规划：启用与呈现、可见性、隐藏延迟、层级、活动角色、默认位置与收进屏幕。
struct OverlayPlannerTests {
    private let pilotA = Fixtures.character(Fixtures.pilotAlpha, id: 1, pid: Fixtures.pidA)
    private let pilotB = Fixtures.character(Fixtures.pilotBravo, id: 2, pid: Fixtures.pidB)
    private let login = Fixtures.client(3, pid: Fixtures.pidC, .login)

    /// 构造输入：两个功能默认都启用，前台是其他应用，离开 EVE 的时刻是 99，now = 100。
    private func input(clients: [EVEClient]? = nil, frontmost: FrontmostContext = .other, now: Double = 100,
                       screens: [ScreenInfo] = [Fixtures.mainScreen],
                       profile edit: (inout Profile) -> Void = { _ in },
                       session sessionEdit: (inout SessionState) -> Void = { _ in }) -> OverlayPlannerInput {
        var profile = Profile(name: "T")
        profile.intel.enabled = true
        profile.translation.enabled = true
        edit(&profile)
        var session = SessionState(lastEVEContextAt: 99)
        sessionEdit(&session)
        return OverlayPlannerInput(clients: clients ?? [pilotA, pilotB], frontmost: frontmost, profile: profile,
                                   session: session, screens: screens, now: now)
    }

    // MARK: - 启用与呈现

    /// 两个功能都没开时没有呈现，也没有定时重算；活动角色照样算出来。
    @Test func noPresentationWhenDisabled() {
        let plan = OverlayPlanner.plan(input(profile: {
            $0.intel.enabled = false
            $0.translation.enabled = false
        }, session: { $0.lastActivePID = Fixtures.pidB }))
        #expect(plan.presentations.isEmpty)
        #expect(plan.nextWakeAt == nil)
        #expect(plan.activeCharacter == Fixtures.pilotBravo)
    }

    /// 只开一个功能时只有它的呈现；两个都开时按 intel、translation 的顺序。
    @Test func onlyEnabledKinds() {
        let onlyTranslation = OverlayPlanner.plan(input(profile: { $0.intel.enabled = false }))
        #expect(onlyTranslation.presentations.map(\.kind) == [.translation])
        let both = OverlayPlanner.plan(input())
        #expect(both.presentations.map(\.kind) == [.intel, .translation])
        #expect(both.presentations.allSatisfy { $0.isVisible })
    }

    /// 外观与锁定取自配置：不透明度、字号、置顶、锁定布局。越界的数值被夹进范围。
    @Test func appearanceFromSettings() {
        let plan = OverlayPlanner.plan(input(profile: {
            $0.intel.overlay.opacity = 0.4
            $0.intel.overlay.fontSize = 18
            $0.translation.overlay.opacity = 5
            $0.translation.overlay.fontSize = 2
            $0.behavior.alwaysOnTop = false
            $0.behavior.lockLayout = true
        }))
        let intel = plan.presentations[0]
        #expect(intel.opacity == 0.4)
        #expect(intel.fontSize == 18)
        #expect(!intel.isAlwaysOnTop)
        #expect(intel.isLocked)
        let translation = plan.presentations[1]
        #expect(translation.opacity == 1.0)
        #expect(translation.fontSize == 10)
    }

    // MARK: - 可见性

    /// 没有任何客户端时不可见，也不安排定时重算。
    @Test func invisibleWithoutClients() {
        let plan = OverlayPlanner.plan(input(clients: [], profile: { $0.behavior.hideWhenEVENotFrontmost = true }))
        #expect(plan.presentations.count == 2)
        #expect(plan.presentations.allSatisfy { !$0.isVisible })
        #expect(plan.nextWakeAt == nil)
        #expect(plan.activeCharacter == nil)
    }

    /// 只有登录界面的客户端时浮窗可见（有客户端），但没有活动角色。
    @Test func visibleWithOnlyLoginClient() {
        let plan = OverlayPlanner.plan(input(clients: [login]))
        #expect(plan.presentations.allSatisfy { $0.isVisible })
        #expect(plan.activeCharacter == nil)
    }

    /// 隐藏延迟到期前可见、nextWakeAt 是到期时刻；到期后不可见、nextWakeAt 为 nil。
    @Test func hideDelay() {
        let edit: (inout Profile) -> Void = {
            $0.behavior.hideWhenEVENotFrontmost = true
            $0.behavior.hideDelaySeconds = 3
        }
        let before = OverlayPlanner.plan(input(now: 101, profile: edit))
        #expect(before.presentations.allSatisfy { $0.isVisible })
        #expect(before.nextWakeAt == 102)
        let atDeadline = OverlayPlanner.plan(input(now: 102, profile: edit))
        #expect(atDeadline.presentations.allSatisfy { !$0.isVisible })
        #expect(atDeadline.nextWakeAt == nil)
        // 开关关着时不隐藏，也不安排定时重算。
        let off = OverlayPlanner.plan(input(now: 500))
        #expect(off.presentations.allSatisfy { $0.isVisible })
        #expect(off.nextWakeAt == nil)
    }

    /// 前台是本应用或客户端时不算离开 EVE，不隐藏。
    @Test func selfAppAndClientDoNotHide() {
        let edit: (inout Profile) -> Void = { $0.behavior.hideWhenEVENotFrontmost = true }
        for front in [FrontmostContext.selfApp, .client(pid: Fixtures.pidA)] {
            let plan = OverlayPlanner.plan(input(frontmost: front, now: 500, profile: edit))
            #expect(plan.presentations.allSatisfy { $0.isVisible })
            #expect(plan.nextWakeAt == nil)
        }
    }

    /// 「全部隐藏」只管缩略图，不影响浮窗（Q23）。
    @Test func hideAllDoesNotAffectOverlays() {
        let plan = OverlayPlanner.plan(input(session: { $0.hideAll = true }))
        #expect(plan.presentations.allSatisfy { $0.isVisible })
    }

    // MARK: - 层级

    /// 前台是原生全屏的客户端且置顶时 isOverFullScreen 为真；不置顶或前台不全屏时为假。
    @Test func overFullScreen() {
        var fullScreen = pilotA
        fullScreen.isFullScreen = true
        let front = FrontmostContext.client(pid: Fixtures.pidA)
        let onTop = OverlayPlanner.plan(input(clients: [fullScreen, pilotB], frontmost: front))
        #expect(onTop.presentations.allSatisfy { $0.isOverFullScreen })
        #expect(onTop.presentations.allSatisfy { $0.isAlwaysOnTop })
        let notOnTop = OverlayPlanner.plan(input(clients: [fullScreen, pilotB], frontmost: front,
                                                 profile: { $0.behavior.alwaysOnTop = false }))
        #expect(notOnTop.presentations.allSatisfy { !$0.isOverFullScreen })
        let otherFront = OverlayPlanner.plan(input(clients: [fullScreen, pilotB],
                                                   frontmost: .client(pid: Fixtures.pidB)))
        #expect(otherFront.presentations.allSatisfy { !$0.isOverFullScreen })
    }

    // MARK: - 活动角色

    /// 3 级取法：前台客户端、最后活动的客户端、第一个有角色名的客户端。
    @Test func activeCharacterLevels() {
        let clients = [login, pilotA, pilotB]
        #expect(OverlayPlanner.activeCharacter(clients: clients, frontmost: .client(pid: Fixtures.pidB),
                                               lastActivePID: Fixtures.pidA) == Fixtures.pilotBravo)
        #expect(OverlayPlanner.activeCharacter(clients: clients, frontmost: .other,
                                               lastActivePID: Fixtures.pidB) == Fixtures.pilotBravo)
        #expect(OverlayPlanner.activeCharacter(clients: clients, frontmost: .selfApp,
                                               lastActivePID: nil) == Fixtures.pilotAlpha)
        #expect(OverlayPlanner.activeCharacter(clients: [], frontmost: .other, lastActivePID: nil) == nil)
    }

    /// WP-0 的取法：前台是登录界面的客户端时为 nil；最后活动的客户端在登录界面或已不在时退到第一个有角色名的客户端。
    @Test func activeCharacterWithLoginClients() {
        let clients = [login, pilotB, pilotA]
        #expect(OverlayPlanner.activeCharacter(clients: clients, frontmost: .client(pid: Fixtures.pidC),
                                               lastActivePID: Fixtures.pidA) == nil)
        #expect(OverlayPlanner.activeCharacter(clients: clients, frontmost: .other,
                                               lastActivePID: Fixtures.pidC) == Fixtures.pilotBravo)
        #expect(OverlayPlanner.activeCharacter(clients: clients, frontmost: .other,
                                               lastActivePID: 9_999) == Fixtures.pilotBravo)
        // 规划结果里的活动角色用同一个取法。
        let plan = OverlayPlanner.plan(input(clients: clients, frontmost: .client(pid: Fixtures.pidC)))
        #expect(plan.activeCharacter == nil)
    }

    // MARK: - 位置

    /// 默认位置在主屏可见区域的右上角，两个浮窗上下排列、不重叠，间隔 12 点。
    @Test func defaultFrames() {
        let screens = [Fixtures.leftScreen, Fixtures.mainScreen]
        let intel = OverlayPlanner.defaultFrame(kind: .intel, screens: screens)
        let translation = OverlayPlanner.defaultFrame(kind: .translation, screens: screens)
        #expect(intel == ScreenRect(x: 1728 - 20 - 380, y: 33 + 60, width: 380, height: 260))
        #expect(!intel.intersects(translation))
        #expect(translation.minY - intel.maxY == 12)
        #expect(translation.x == intel.x)
    }

    /// 没有保存位置时用默认位置；保存过时用收进屏幕后的位置。
    @Test func frameFromSettings() {
        let saved = ScreenRect(x: 100, y: 200, width: 300, height: 200)
        let plan = OverlayPlanner.plan(input(profile: { $0.intel.overlay.frame = saved }))
        #expect(plan.presentations[0].frame == saved)
        #expect(plan.presentations[1].frame == OverlayPlanner.defaultFrame(kind: .translation,
                                                                            screens: [Fixtures.mainScreen]))
    }

    /// 尺寸夹到上下限；在屏幕内的位置不动。
    @Test func clampedFrameSize() {
        let screens = [Fixtures.mainScreen]
        let small = OverlayPlanner.clampedFrame(ScreenRect(x: 100, y: 100, width: 10, height: 10), screens: screens)
        #expect(small == ScreenRect(x: 100, y: 100, width: 220, height: 120))
        let large = OverlayPlanner.clampedFrame(ScreenRect(x: 100, y: 100, width: 5000, height: 5000), screens: screens)
        #expect(large.width == 900)
        #expect(large.height == 900)
        #expect(large.origin == ScreenPoint(x: 100, y: 100))
    }

    /// 屏幕外的 frame 被拉回，至少 40 点留在可见区域内。
    @Test func clampedFramePullsBack() {
        let screens = [Fixtures.mainScreen]
        let farRight = OverlayPlanner.clampedFrame(ScreenRect(x: 5000, y: 300, width: 300, height: 200), screens: screens)
        #expect(farRight.x == 1728 - 40)
        #expect(farRight.y == 300)
        let farUp = OverlayPlanner.clampedFrame(ScreenRect(x: 100, y: -900, width: 300, height: 200), screens: screens)
        #expect(farUp.y == 33 - 200 + 40)
        #expect(farUp.x == 100)
        // 只露出 10 点也算不够，按最近的边拉回到 40 点。
        let sliver = OverlayPlanner.clampedFrame(ScreenRect(x: -290, y: 300, width: 300, height: 200), screens: screens)
        #expect(sliver.x == -260)
    }

    /// 多屏时留在副屏上的 frame 不被拉到主屏；没有屏幕时只夹尺寸。
    @Test func clampedFrameMultipleScreens() {
        let screens = [Fixtures.mainScreen, Fixtures.leftScreen]
        let onLeft = ScreenRect(x: -1500, y: 400, width: 300, height: 200)
        #expect(OverlayPlanner.clampedFrame(onLeft, screens: screens) == onLeft)
        // 在左屏更左边的 frame 拉回左屏，而不是主屏。
        let beyondLeft = OverlayPlanner.clampedFrame(ScreenRect(x: -4000, y: 400, width: 300, height: 200),
                                                     screens: screens)
        #expect(beyondLeft.x == -1920 - 300 + 40)
        let none = OverlayPlanner.clampedFrame(ScreenRect(x: 9000, y: 9000, width: 1, height: 1), screens: [])
        #expect(none == ScreenRect(x: 9000, y: 9000, width: 220, height: 120))
    }

    // MARK: - 显示范围（v1.2.1）

    /// 「仅游戏内」：前台是其他应用时立即隐藏（不等延迟、也不看「离开 EVE 时隐藏」）；前台是客户端或本应用时显示。
    /// 「始终显示」的另一个浮窗不受影响。
    @Test func gameOnlyHidesWhenEVENotFrontmost() {
        let edit: (inout Profile) -> Void = { $0.intel.overlay.visibility = .gameOnly }
        let away = OverlayPlanner.plan(input(frontmost: .other, profile: edit))
        #expect(away.presentations.map(\.isVisible) == [false, true])
        for frontmost in [FrontmostContext.client(pid: Fixtures.pidA), .selfApp] {
            let plan = OverlayPlanner.plan(input(frontmost: frontmost, profile: edit))
            #expect(plan.presentations.map(\.isVisible) == [true, true])
        }
    }

    /// 没有客户端时两种显示范围都不可见；不认识的显示范围解码成默认值，不让配置读取失败。
    @Test func visibilityEdgeCases() throws {
        let none = OverlayPlanner.plan(input(clients: [], frontmost: .selfApp,
                                             profile: { $0.translation.overlay.visibility = .gameOnly }))
        #expect(none.presentations.allSatisfy { !$0.isVisible })
        let decoded = try JSONDecoder().decode(OverlayPanelSettings.self,
                                               from: Data(#"{"visibility":"someday"}"#.utf8))
        #expect(decoded.visibility == .always)
        #expect(OverlayPanelSettings().visibility == .always)
    }
}
