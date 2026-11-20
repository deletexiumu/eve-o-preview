// SPDX-License-Identifier: GPL-3.0-or-later
//
// ThumbnailPlanner 的用例（架构文档 5.6 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 规划器：高亮、悬停、拖动、占位、捕获、自动布局与定时重算。
struct ThumbnailPlannerTests {
    private let pilotA = Fixtures.character(Fixtures.pilotAlpha, id: 1, pid: Fixtures.pidA)
    private let pilotB = Fixtures.character(Fixtures.pilotBravo, id: 2, pid: Fixtures.pidB)
    private let login = Fixtures.client(3, pid: Fixtures.pidC, .login)

    /// 两个角色都有布局记录，避免自动排位干扰其他断言。
    private func profile(_ edit: (inout Profile) -> Void = { _ in }) -> Profile {
        var profile = Profile(name: "T")
        profile.layouts = [Fixtures.pilotAlpha: ThumbnailLayout(x: 100, y: 100),
                           Fixtures.pilotBravo: ThumbnailLayout(x: 600, y: 100)]
        edit(&profile)
        return profile
    }

    /// 规划并返回结果。
    private func plan(frontmost: FrontmostContext = .other, profile: Profile? = nil,
                      session: SessionState = SessionState(), permissions: PermissionStatus = .granted,
                      states: [WindowID: CaptureState]? = nil, clients: [EVEClient]? = nil) -> ThumbnailPlan {
        ThumbnailPlanner.plan(Fixtures.plannerInput(clients: clients ?? [pilotA, pilotB], profile: profile ?? self.profile(),
                                                    frontmost: frontmost, session: session,
                                                    permissions: permissions, captureStates: states))
    }

    /// 呈现的顺序与客户端相同，基础字段取自配置。
    @Test func basicPresentation() {
        let result = plan(clients: [pilotB, pilotA, login])
        #expect(result.presentations.map(\.id) == [pilotB.id, pilotA.id, login.id])
        let first = result.presentations[0]
        #expect(first.title == Fixtures.pilotBravo && first.showsTitle && first.titleFontSize == 12)
        #expect(first.titleColor == "#FFFFFF" && first.opacity == 0.5 && first.isAlwaysOnTop)
        #expect(first.frame == ScreenRect(x: 600, y: 100, width: 384, height: 216))
        #expect(result.presentations[2].title == "EVE")
        #expect(result.presentations[2].frame.origin == ScreenPoint(x: 5, y: 40))
    }

    /// 活动高亮：前台客户端高亮，用全局颜色；高亮关闭时不画。
    @Test func activeHighlight() {
        let enabled = profile { $0.overlay.highlightEnabled = true }
        let result = plan(frontmost: .client(pid: Fixtures.pidA), profile: enabled)
        #expect(result.presentations.map(\.isActive) == [true, false])
        #expect(result.presentations.map(\.highlightColor) == ["#ADFF2F", nil])
        #expect(result.presentations[0].highlightThickness == 3)
        let disabled = plan(frontmost: .client(pid: Fixtures.pidA))
        #expect(disabled.presentations[0].isActive && disabled.presentations[0].highlightColor == nil)
    }

    /// 前台离开 EVE 后，高亮留在 lastActivePID 对应的客户端上；本应用在前台时同样如此。
    @Test func lastActivePIDKeepsHighlight() {
        let enabled = profile { $0.overlay.highlightEnabled = true }
        for frontmost in [FrontmostContext.other, .selfApp] {
            let result = plan(frontmost: frontmost, profile: enabled, session: SessionState(lastActivePID: Fixtures.pidB))
            #expect(result.presentations.map(\.isActive) == [false, true])
            #expect(result.presentations[1].highlightColor == "#ADFF2F")
        }
    }

    /// 按角色设置的高亮颜色优先于全局颜色。
    @Test func perCharacterColor() {
        let colored = profile {
            $0.overlay.highlightEnabled = true
            $0.highlightColors = [Fixtures.pilotAlpha: "#FF0000"]
        }
        let result = plan(frontmost: .client(pid: Fixtures.pidA), profile: colored)
        #expect(result.presentations[0].highlightColor == "#FF0000")
    }

    /// 悬停：不透明度变为 1.0；打开放大时按锚点放大，捕获规格随之变大。
    @Test func hoverZoomAndOpacity() {
        let zoom = profile {
            $0.thumbnail.zoomEnabled = true
            $0.thumbnail.zoomFactor = 2
            $0.thumbnail.zoomAnchor = .nw
        }
        let result = plan(profile: zoom, session: SessionState(hoveredWindow: pilotA.id))
        let hovered = result.presentations[0]
        #expect(hovered.opacity == 1.0 && hovered.isZoomed)
        #expect(hovered.frame == ScreenRect(x: 100, y: 100, width: 768, height: 432))
        #expect(result.presentations[1].opacity == 0.5 && !result.presentations[1].isZoomed)
        #expect(result.captures[pilotA.id]?.pixelWidth == 1536)
        // 没打开放大时只改不透明度。
        let plain = plan(session: SessionState(hoveredWindow: pilotA.id))
        #expect(plain.presentations[0].opacity == 1.0 && !plain.presentations[0].isZoomed)
    }

    /// 拖动中的缩略图即使悬停也不放大，frame 是基准 frame。
    @Test func interactingNotZoomed() {
        let zoom = profile { $0.thumbnail.zoomEnabled = true }
        let session = SessionState(hoveredWindow: pilotA.id, interactingWindows: [pilotA.id])
        let presentation = plan(profile: zoom, session: session).presentations[0]
        #expect(!presentation.isZoomed)
        #expect(presentation.frame == ScreenRect(x: 100, y: 100, width: 384, height: 216))
    }

    /// 占位按顺序取第一个成立的。
    @Test(arguments: [
        (CaptureState.permissionDenied, false, ThumbnailPlaceholder.needsScreenRecording),
        (.stoppedByUser, true, .captureStopped),
        (.running, true, .minimized),
        (.idle, false, .waitingForFrame),
        (.starting, false, .waitingForFrame),
        (.retrying(attempt: 2, delay: 1), false, .waitingForFrame),
        (.running, false, .none),
        (.windowGone, false, .none),
    ])
    func placeholders(state: CaptureState, minimized: Bool, expected: ThumbnailPlaceholder) {
        var client = pilotA
        client.isMinimized = minimized
        let result = plan(states: [pilotA.id: state], clients: [client])
        #expect(result.presentations[0].placeholder == expected)
    }

    /// 没有屏幕录制权限：占位是 needsScreenRecording（优先于最小化），captures 为空。
    @Test func noScreenRecording() {
        var client = pilotA
        client.isMinimized = true
        let result = plan(permissions: PermissionStatus(screenRecording: false, accessibility: true),
                          clients: [client, pilotB])
        #expect(result.presentations.allSatisfy { $0.placeholder == .needsScreenRecording })
        #expect(result.captures.isEmpty)
    }

    /// 隐藏的缩略图不捕获；可见的按缩略图尺寸与屏幕 scale 生成规格。
    @Test func hiddenNotCaptured() {
        let hidden = profile { $0.hiddenCharacters = [Fixtures.pilotAlpha] }
        let result = plan(profile: hidden)
        #expect(result.presentations.map(\.isVisible) == [false, true])
        #expect(result.captures.keys.sorted() == [pilotB.id])
        #expect(result.captures[pilotB.id] == CaptureSpec(pixelWidth: 768, pixelHeight: 454, framesPerSecond: 15))
    }

    /// 跳过标记取自会话的 skippedCharacters。
    @Test func skippedFlag() {
        let result = plan(session: SessionState(skippedCharacters: [Fixtures.pilotBravo]))
        #expect(result.presentations.map(\.isSkipped) == [false, true])
    }

    /// 自动布局：没有记录的角色避开有记录的角色与登录客户端，只持久化它自己。
    @Test func layoutsToPersistAvoidsKnownFrames() {
        var withRecord = Profile(name: "T")
        withRecord.layouts = [Fixtures.pilotAlpha: ThumbnailLayout(x: 16, y: 49)]
        // pilotB 排在最前，仍应避开后面 pilotA 与登录客户端的位置。
        let result = plan(profile: withRecord, clients: [pilotB, pilotA, login])
        #expect(result.layoutsToPersist == [Fixtures.pilotBravo: ThumbnailLayout(x: 16, y: 273)])
        #expect(result.presentations[0].frame.origin == ScreenPoint(x: 16, y: 273))
    }

    /// 多个没有记录的角色依次排位，互不重叠。
    @Test func multipleAutoPlacements() {
        let result = plan(profile: Profile(name: "T"), clients: [pilotA, pilotB])
        #expect(result.layoutsToPersist == [Fixtures.pilotAlpha: ThumbnailLayout(x: 16, y: 49),
                                            Fixtures.pilotBravo: ThumbnailLayout(x: 16, y: 273)])
    }

    /// 被拉回屏幕内的有记录布局不写回配置。
    @Test func clampedRecordNotPersisted() {
        var offscreen = Profile(name: "T")
        offscreen.layouts = [Fixtures.pilotAlpha: ThumbnailLayout(x: 5000, y: 5000)]
        let result = plan(profile: offscreen, clients: [pilotA])
        #expect(result.layoutsToPersist.isEmpty)
        #expect(result.presentations[0].frame.origin == ScreenPoint(x: 1344, y: 901))
    }

    /// 定时重算：离开 EVE 的隐藏延迟未到时，nextWakeAt 是到期时刻。
    @Test func nextWakeAt() {
        let hide = profile { $0.behavior.hideWhenEVENotFrontmost = true }
        let input = Fixtures.plannerInput(clients: [pilotA], profile: hide, frontmost: .other,
                                          session: SessionState(lastEVEContextAt: 99.5), now: 100)
        #expect(ThumbnailPlanner.plan(input).nextWakeAt == 100.5)
        // 本应用在前台时不触发隐藏，也就不需要定时重算。
        #expect(plan(frontmost: .selfApp, profile: hide, session: SessionState(lastEVEContextAt: 99.5)).nextWakeAt == nil)
        // 延迟已过：已经隐藏，同样不需要定时重算。
        #expect(plan(profile: hide, session: SessionState(lastEVEContextAt: 50)).nextWakeAt == nil)
    }
}

// MARK: - 第一轮反馈：边框与战斗提醒（反馈文档 4.2 节、7.7 节）

extension ThumbnailPlannerTests {
    /// 带一条战斗提醒的会话。
    private func alerted(_ id: WindowID, until: Double, startedAt: Double = 99) -> SessionState {
        SessionState(combatAlerts: [id: CombatAlertWindow(startedAt: startedAt, until: until)])
    }

    /// 边框默认打开：每个呈现都有边框颜色与粗细；关闭后颜色为 nil。
    @Test func borderDefaultsAndDisabled() {
        let result = plan()
        #expect(result.presentations.map(\.borderColor) == ["#C0C0C0", "#C0C0C0"])
        #expect(result.presentations.allSatisfy { $0.borderThickness == 2 })
        let off = plan(profile: profile { $0.overlay.borderEnabled = false; $0.overlay.borderThickness = 5 })
        #expect(off.presentations.allSatisfy { $0.borderColor == nil && $0.borderThickness == 5 })
    }

    /// 活动客户端同时有高亮颜色与边框颜色，由视图决定先用哪个。
    @Test func activeClientHasHighlightAndBorder() {
        let enabled = profile { $0.overlay.highlightEnabled = true; $0.overlay.borderColor = "#112233" }
        let active = plan(frontmost: .client(pid: Fixtures.pidA), profile: enabled).presentations[0]
        #expect(active.highlightColor == "#ADFF2F" && active.borderColor == "#112233")
    }

    /// 有未到期的提醒：alert 取 combatAlert 的颜色与样式，不透明度为 1.0；不看 enabled。
    @Test func activeAlertPresentation() {
        let styled = profile { $0.combatAlert.color = "#00FF00"; $0.combatAlert.style = .wash }
        let result = plan(profile: styled, session: alerted(pilotA.id, until: 101))
        #expect(!styled.combatAlert.enabled)
        #expect(result.presentations[0].alert == ThumbnailAlert(color: "#00FF00", style: .wash))
        #expect(result.presentations[0].opacity == 1.0)
        #expect(result.presentations[1].alert == nil && result.presentations[1].opacity == 0.5)
    }

    /// 提醒到期（now >= until）后 alert 为 nil，不透明度恢复。
    @Test func expiredAlertCleared() {
        for until in [100.0, 99.0] {
            let presentation = plan(session: alerted(pilotA.id, until: until)).presentations[0]
            #expect(presentation.alert == nil && presentation.opacity == 0.5)
        }
    }

    /// 提醒延长（until 变大、startedAt 不变）时呈现不变，面板不会重复更新。
    @Test func extendedAlertKeepsPresentation() {
        let first = plan(session: alerted(pilotA.id, until: 101)).presentations
        let extended = plan(session: alerted(pilotA.id, until: 104)).presentations
        #expect(first == extended)
    }

    /// nextWakeAt 取隐藏期限与最早的未到期提醒中较小的一个；已到期的提醒不参与。
    @Test func nextWakeAtIncludesAlerts() {
        let hide = profile { $0.behavior.hideWhenEVENotFrontmost = true }
        var session = SessionState(lastEVEContextAt: 99.5)        // 隐藏期限 100.5
        session.combatAlerts = [pilotA.id: CombatAlertWindow(startedAt: 99, until: 100.2),
                                pilotB.id: CombatAlertWindow(startedAt: 99, until: 103)]
        #expect(plan(profile: hide, session: session).nextWakeAt == 100.2)
        session.combatAlerts[pilotA.id] = CombatAlertWindow(startedAt: 99, until: 101)
        #expect(plan(profile: hide, session: session).nextWakeAt == 100.5)
        // 没有隐藏期限时只看提醒；已到期的提醒不安排重算。
        let alertsOnly = SessionState(combatAlerts: [pilotA.id: CombatAlertWindow(startedAt: 90, until: 95),
                                                     pilotB.id: CombatAlertWindow(startedAt: 99, until: 102)])
        #expect(plan(session: alertsOnly).nextWakeAt == 102)
        #expect(plan(session: alerted(pilotA.id, until: 95)).nextWakeAt == nil)
    }
}
