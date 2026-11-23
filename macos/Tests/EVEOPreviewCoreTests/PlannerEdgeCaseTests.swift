// SPDX-License-Identifier: GPL-3.0-or-later
//
// 规划器与可见性规则的补充用例（架构文档 5.6 节）。测试方于 2026-11-20 补写，
// 覆盖原有用例没有检查的边界：占位的优先顺序组合、活动客户端的取法、捕获只给可见缩略图、
// 多屏下的 scale 与标题栏裁剪、登录客户端的层叠序号、隐藏延迟的到期时刻与可见性是否一致。
// 期望值都按规格文字手算，不照抄实现。

import Testing
import EVEOPreviewCore

/// 规划器的边界用例。
struct ThumbnailPlannerEdgeCaseTests {
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

    // MARK: - 占位的优先顺序

    /// 占位按「权限 → 用户停止 → 最小化 → 等待画面 → 无」的顺序取第一个成立的。
    /// 参数依次是：捕获状态（nil 表示状态表里没有记录，按 idle 处理）、isMinimized、屏幕录制权限、期望占位。
    @Test(arguments: [
        // 状态是 permissionDenied 时，即使窗口最小化也先提示权限。
        (CaptureState?.some(.permissionDenied), Bool?.some(true), true, ThumbnailPlaceholder.needsScreenRecording),
        // 没有屏幕录制权限时，用户停止的状态也让位于权限提示。
        (.some(.stoppedByUser), .some(false), false, .needsScreenRecording),
        // 用户停止优先于最小化。
        (.some(.stoppedByUser), .some(true), true, .captureStopped),
        // 最小化优先于「等待画面」的 3 种状态。
        (.some(.idle), .some(true), true, .minimized),
        (.some(.starting), .some(true), true, .minimized),
        (.some(.retrying(attempt: 3, delay: 2)), .some(true), true, .minimized),
        // windowGone 不属于等待画面的状态，最小化时仍显示最小化占位。
        (.some(.windowGone), .some(true), true, .minimized),
        // 状态表里没有记录时按 idle 处理，显示等待画面。
        (nil, .some(false), true, .waitingForFrame),
        // isMinimized 为 nil（没有辅助功能权限）不算最小化。
        (.some(.running), nil, true, .none),
        (.some(.idle), nil, true, .waitingForFrame),
    ])
    func placeholderPrecedence(state: CaptureState?, minimized: Bool?, screenRecording: Bool,
                               expected: ThumbnailPlaceholder) {
        var client = pilotA
        client.isMinimized = minimized
        let states: [WindowID: CaptureState] = state.map { [pilotA.id: $0] } ?? [:]
        let input = Fixtures.plannerInput(clients: [client], profile: profile(),
                                          permissions: PermissionStatus(screenRecording: screenRecording,
                                                                        accessibility: true),
                                          captureStates: states)
        #expect(ThumbnailPlanner.plan(input).presentations[0].placeholder == expected)
    }

    // MARK: - 活动客户端

    /// 前台是客户端时只看前台，不看 lastActivePID。
    @Test func frontmostClientBeatsLastActivePID() {
        let input = Fixtures.plannerInput(clients: [pilotA, pilotB], profile: profile { $0.overlay.highlightEnabled = true },
                                          frontmost: .client(pid: Fixtures.pidA),
                                          session: SessionState(lastActivePID: Fixtures.pidB))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations.map(\.isActive) == [true, false])
        #expect(result.presentations.map(\.highlightColor) == ["#ADFF2F", nil])
    }

    /// 前台是一个不在列表里的客户端 PID 时，没有缩略图是活动的，lastActivePID 也不起作用。
    @Test func unknownFrontmostPIDActivatesNothing() {
        let input = Fixtures.plannerInput(clients: [pilotA, pilotB], profile: profile(),
                                          frontmost: .client(pid: 9999),
                                          session: SessionState(lastActivePID: Fixtures.pidB))
        #expect(ThumbnailPlanner.plan(input).presentations.map(\.isActive) == [false, false])
    }

    /// 前台不是 EVE 且没有 lastActivePID 时，没有缩略图是活动的。
    @Test func noLastActivePIDActivatesNothing() {
        for frontmost in [FrontmostContext.other, .selfApp] {
            let input = Fixtures.plannerInput(clients: [pilotA, pilotB], profile: profile(), frontmost: frontmost)
            #expect(ThumbnailPlanner.plan(input).presentations.map(\.isActive) == [false, false])
        }
    }

    /// 登录客户端是活动客户端时用全局高亮颜色：它没有角色名，按角色的颜色表里即使有 `EVE` 键也不用。
    @Test func activeLoginClientUsesGlobalHighlight() {
        let colored = profile {
            $0.overlay.highlightEnabled = true
            $0.overlay.highlightColor = "#123456"
            $0.highlightColors = ["EVE": "#FF0000"]
        }
        let input = Fixtures.plannerInput(clients: [pilotA, login], profile: colored,
                                          frontmost: .client(pid: Fixtures.pidC))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations.map(\.isActive) == [false, true])
        #expect(result.presentations[1].highlightColor == "#123456")
    }

    /// 跳过标记只看角色名：登录客户端即使 skippedCharacters 里有 `EVE` 也不显示跳过标记。
    @Test func loginClientNeverSkipped() {
        let input = Fixtures.plannerInput(clients: [login], profile: profile(),
                                          session: SessionState(skippedCharacters: ["EVE"]))
        #expect(ThumbnailPlanner.plan(input).presentations[0].isSkipped == false)
    }

    // MARK: - 捕获只给可见的缩略图

    /// 全部隐藏时没有任何捕获。
    @Test func hideAllCapturesNothing() {
        let input = Fixtures.plannerInput(clients: [pilotA, pilotB, login], profile: profile(),
                                          session: SessionState(hideAll: true))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations.allSatisfy { !$0.isVisible })
        #expect(result.captures.isEmpty)
    }

    /// 「隐藏活动客户端」生效时，只停掉前台客户端的捕获，其他照常。
    @Test func hiddenActiveClientNotCaptured() {
        let input = Fixtures.plannerInput(clients: [pilotA, pilotB],
                                          profile: profile { $0.behavior.hideActiveClientThumbnail = true },
                                          frontmost: .client(pid: Fixtures.pidA))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations.map(\.isVisible) == [false, true])
        #expect(Set(result.captures.keys) == [pilotB.id])
    }

    /// 「离开 EVE 时隐藏」到期后没有任何捕获，也不需要定时重算。
    @Test func elapsedHideDelayCapturesNothing() {
        let input = Fixtures.plannerInput(clients: [pilotA, pilotB],
                                          profile: profile { $0.behavior.hideWhenEVENotFrontmost = true },
                                          session: SessionState(lastEVEContextAt: 90), now: 100)
        let result = ThumbnailPlanner.plan(input)
        #expect(result.captures.isEmpty)
        #expect(result.nextWakeAt == nil)
    }

    // MARK: - 多屏

    /// scale 取缩略图中心点所在屏幕的值：缩略图在 scale 1 的副屏上时，宽 384 × 1 = 384，
    /// 高按源窗口 1728×1018 的比例算出 226.2，向上取偶数得 228。
    @Test func captureScaleFollowsThumbnailScreen() {
        let onLeft = profile { $0.layouts[Fixtures.pilotAlpha] = ThumbnailLayout(x: -1500, y: 100) }
        let input = Fixtures.plannerInput(clients: [pilotA, pilotB], profile: onLeft,
                                          screens: [Fixtures.mainScreen, Fixtures.leftScreen])
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations[0].frame.origin == ScreenPoint(x: -1500, y: 100))
        #expect(result.captures[pilotA.id] == CaptureSpec(pixelWidth: 384, pixelHeight: 228, framesPerSecond: 15))
        // 主屏 scale 2：768 × 1018 / 1728 = 452.4，向上取偶数得 454。
        #expect(result.captures[pilotB.id] == CaptureSpec(pixelWidth: 768, pixelHeight: 454, framesPerSecond: 15))
    }

    /// 悬停放大后的捕获规格不超过源窗口的像素尺寸：放大 10 倍是 3840 点 × 2 = 7680 像素，
    /// 源窗口是 1728×1018 点 × 2 = 3456×2036 像素，结果取源窗口的像素尺寸。
    @Test func zoomedCaptureCappedAtSourcePixels() {
        let zoom = profile {
            $0.thumbnail.zoomEnabled = true
            $0.thumbnail.zoomFactor = 10
        }
        let input = Fixtures.plannerInput(clients: [pilotA], profile: zoom, session: SessionState(hoveredWindow: pilotA.id))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations[0].isZoomed)
        #expect(result.captures[pilotA.id] == CaptureSpec(pixelWidth: 3456, pixelHeight: 2036, framesPerSecond: 15))
    }

    /// 标题栏裁剪按源窗口「所在屏幕」的高度判断全屏：1920×1080 的窗口在 1080 高的副屏上不裁，
    /// 同样尺寸的窗口在 1117 高的主屏上要裁掉 28 点。
    @Test func fullScreenJudgedByWindowScreen() {
        let size = (width: 1920.0, height: 1080.0)
        let onLeft = Fixtures.client(1, pid: Fixtures.pidA, .character(Fixtures.pilotAlpha),
                                     frame: ScreenRect(x: -1920, y: 0, width: size.width, height: size.height))
        let onMain = Fixtures.client(2, pid: Fixtures.pidB, .character(Fixtures.pilotBravo),
                                     frame: ScreenRect(x: 0, y: 33, width: size.width, height: size.height))
        let input = Fixtures.plannerInput(clients: [onLeft, onMain], profile: profile(),
                                          screens: [Fixtures.mainScreen, Fixtures.leftScreen])
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations[0].contentsRect == UnitRect.full)
        let top = 28.0 / 1080.0
        #expect(result.presentations[1].contentsRect == UnitRect(x: 0, y: top, width: 1, height: 1 - top))
    }

    // MARK: - 登录客户端的层叠

    /// loginIndex 按 PID 升序编号，与客户端列表的顺序无关；登录与未知客户端同属一类。
    /// PID 100、200、300 依次得到 (5, 40)、(29, 64)、(53, 88)。
    @Test func loginIndexFollowsPIDOrder() {
        let pid300 = Fixtures.client(10, pid: 300, .login)
        let pid200 = Fixtures.client(11, pid: 200, .unknown)
        let pid100 = Fixtures.client(12, pid: 100, .login)
        let input = Fixtures.plannerInput(clients: [pid300, pid200, pid100], profile: Profile(name: "T"))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations.map(\.frame.origin) == [
            ScreenPoint(x: 53, y: 88), ScreenPoint(x: 29, y: 64), ScreenPoint(x: 5, y: 40),
        ])
        // 未知客户端的标题是 `EVE (<pid>)`；登录与未知客户端都不持久化位置。
        #expect(result.presentations[1].title == "EVE (200)")
        #expect(result.layoutsToPersist.isEmpty)
    }

    // MARK: - 自动排位

    /// 同名的两个客户端（同一角色开了两个窗口的异常情况）都自动排位且互不重叠，只持久化第一个。
    @Test func duplicateCharacterNamePersistsFirstOnly() {
        let twin = Fixtures.character(Fixtures.pilotAlpha, id: 5, pid: Fixtures.pidB)
        let input = Fixtures.plannerInput(clients: [pilotA, twin], profile: Profile(name: "T"))
        let result = ThumbnailPlanner.plan(input)
        #expect(result.presentations.map(\.frame.origin) == [ScreenPoint(x: 16, y: 49), ScreenPoint(x: 16, y: 273)])
        #expect(result.layoutsToPersist == [Fixtures.pilotAlpha: ThumbnailLayout(x: 16, y: 49)])
    }

    /// 规划器是纯函数：同样的输入两次得到同样的结果。
    @Test func deterministic() {
        let input = Fixtures.plannerInput(clients: [login, pilotB, pilotA], profile: Profile(name: "T"),
                                          frontmost: .client(pid: Fixtures.pidB),
                                          session: SessionState(hoveredWindow: login.id),
                                          screens: [Fixtures.leftScreen, Fixtures.mainScreen])
        #expect(ThumbnailPlanner.plan(input) == ThumbnailPlanner.plan(input))
    }

    // MARK: - 定时重算与可见性一致

    /// nextWakeAt 与 isVisible 一致：有定时重算时缩略图仍可见且到期时刻在未来；
    /// 没有定时重算时缩略图已隐藏。恰好到期（now == 99 + 1）算已到期。
    @Test(arguments: [98.0, 99.0, 99.5, 99.999, 100.0, 100.5])
    func nextWakeAtConsistentWithVisibility(now: Double) {
        let input = Fixtures.plannerInput(clients: [pilotA], profile: profile { $0.behavior.hideWhenEVENotFrontmost = true },
                                          session: SessionState(lastEVEContextAt: 99), now: now)
        let result = ThumbnailPlanner.plan(input)
        let visible = result.presentations[0].isVisible
        if let wake = result.nextWakeAt {
            #expect(visible && wake > now && wake == 100)
        } else {
            #expect(!visible && now >= 100)
        }
    }
}

/// 可见性规则的边界用例。
struct VisibilityRulesEdgeCaseTests {
    private let pilotA = Fixtures.character(Fixtures.pilotAlpha, id: 1, pid: Fixtures.pidA)
    private let unknown = Fixtures.client(2, pid: Fixtures.pidB, .unknown)

    /// 构造输入：默认前台是其他应用，lastEVEContextAt = 99，now = 100。
    private func input(frontmost: FrontmostContext = .other, now: Double = 100, last: Double = 99,
                       profile edit: (inout Profile) -> Void = { _ in },
                       session sessionEdit: (inout SessionState) -> Void = { _ in }) -> PlannerInput {
        var profile = Profile(name: "T")
        edit(&profile)
        var session = SessionState(lastEVEContextAt: last)
        sessionEdit(&session)
        return Fixtures.plannerInput(clients: [pilotA, unknown], profile: profile, frontmost: frontmost,
                                     session: session, now: now)
    }

    /// 延迟为 0：离开 EVE 的同一刻就隐藏，不需要定时重算。
    @Test func zeroDelayHidesImmediately() {
        let i = input(now: 99, profile: {
            $0.behavior.hideWhenEVENotFrontmost = true
            $0.behavior.hideDelaySeconds = 0
        })
        #expect(!VisibilityRules.isVisible(client: pilotA, input: i))
        #expect(VisibilityRules.hideDeadline(input: i) == nil)
    }

    /// now 早于 lastEVEContextAt（时钟异常）时不隐藏，到期时刻是 lastEVEContextAt + 延迟。
    @Test func nowBeforeLastContext() {
        let i = input(now: 100, last: 200, profile: { $0.behavior.hideWhenEVENotFrontmost = true })
        #expect(VisibilityRules.isVisible(client: pilotA, input: i))
        #expect(VisibilityRules.hideDeadline(input: i) == 201)
    }

    /// 规则 2 只管角色名：未知客户端的显示标题 `EVE (<pid>)` 写进隐藏名单也不起作用。
    @Test func unknownClientIgnoresHiddenList() {
        let i = input(profile: { $0.hiddenCharacters = ["EVE (\(Fixtures.pidB))", "EVE", ""] })
        #expect(VisibilityRules.isVisible(client: unknown, input: i))
    }

    /// 规则 1 不受前台影响：本应用在前台时「全部隐藏」照样生效。
    @Test func hideAllWinsOverSelfApp() {
        let i = input(frontmost: .selfApp, session: { $0.hideAll = true })
        #expect(!VisibilityRules.isVisible(client: pilotA, input: i))
    }

    /// 规则 3 只看前台：本应用在前台、lastActivePID 指向该客户端时，缩略图仍可见。
    @Test func hideActiveIgnoresSelfApp() {
        let i = input(frontmost: .selfApp, profile: { $0.behavior.hideActiveClientThumbnail = true },
                      session: { $0.lastActivePID = Fixtures.pidA })
        #expect(VisibilityRules.isVisible(client: pilotA, input: i))
    }

    /// 规则 4 关闭时，即使前台是其他应用、延迟未到，也没有定时重算。
    @Test func noDeadlineWhenRuleDisabled() {
        #expect(VisibilityRules.hideDeadline(input: input(now: 99.2)) == nil)
    }

    /// 最大延迟 10 秒：第 9.999 秒仍可见，第 10 秒隐藏。
    @Test func maximumDelayBoundary() {
        let edit: (inout Profile) -> Void = {
            $0.behavior.hideWhenEVENotFrontmost = true
            $0.behavior.hideDelaySeconds = 10
        }
        let before = input(now: 108.999, profile: edit)
        #expect(VisibilityRules.isVisible(client: pilotA, input: before))
        #expect(VisibilityRules.hideDeadline(input: before) == 109)
        #expect(!VisibilityRules.isVisible(client: pilotA, input: input(now: 109, profile: edit)))
    }
}
