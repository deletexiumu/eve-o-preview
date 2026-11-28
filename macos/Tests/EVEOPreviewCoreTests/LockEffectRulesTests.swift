// SPDX-License-Identifier: GPL-3.0-or-later
//
// 锁定布局视觉特效规则与规划器叠层的单元测试。

import Testing
@testable import EVEOPreviewCore

/// 锁定布局特效规则测试。
struct LockEffectRulesTests {
    /// 构造测试用的呈现：可指定高亮边框、中性边框与锁定状态。
    private static func makePresentation(highlightColor: String?, highlightThickness: Double = 3,
                                         borderColor: String? = "#C0C0C0", borderThickness: Double = 2,
                                         isLocked: Bool = true) -> ThumbnailPresentation {
        ThumbnailPresentation(
            id: WindowID(rawValue: 1), pid: 100, frame: ScreenRect(x: 0, y: 0, width: 384, height: 216),
            isVisible: true, title: "Alpha", showsTitle: true, titleFontSize: 12, titleColor: "#FFFFFF",
            opacity: 0.5, highlightColor: highlightColor, highlightThickness: highlightThickness,
            isActive: highlightColor != nil, isSkipped: false, isAlwaysOnTop: true, isZoomed: false,
            contentsRect: .full, placeholder: .none, borderColor: borderColor,
            borderThickness: borderThickness, alert: nil, isOverFullScreen: false, isLocked: isLocked)
    }

    /// 活动高亮开启时，内缩宽度严格等于高亮边框粗细，确保活动边框不被覆盖。
    @Test func borderInsetMatchesActiveHighlight() {
        let active = Self.makePresentation(highlightColor: "#ADFF2F", highlightThickness: 4,
                                           borderColor: "#C0C0C0", borderThickness: 2)
        #expect(LockEffectRules.borderInset(for: active) == 4)
    }

    /// 非活动窗口带中性边框时，内缩宽度等于中性边框粗细；两者皆无时为 0。
    @Test func borderInsetFallsBackToNeutralOrZero() {
        let neutral = Self.makePresentation(highlightColor: nil, borderColor: "#C0C0C0", borderThickness: 2)
        #expect(LockEffectRules.borderInset(for: neutral) == 2)
        let plain = Self.makePresentation(highlightColor: nil, borderColor: nil, borderThickness: 2)
        #expect(LockEffectRules.borderInset(for: plain) == 0)
        // 非法色串时回退到下一种边框。
        let invalid = Self.makePresentation(highlightColor: "not-a-color", highlightThickness: 5,
                                            borderColor: "#C0C0C0", borderThickness: 2)
        #expect(LockEffectRules.borderInset(for: invalid) == 2)
    }

    /// 角标臂长随尺寸缩放并受上下限和最小安全空间约束。
    @Test func cornerArmLengthClampsSafely() {
        #expect(LockEffectRules.cornerArmLength(innerWidth: 378, innerHeight: 210) == 18.0)
        #expect(abs(LockEffectRules.cornerArmLength(innerWidth: 160, innerHeight: 90) - 12.6) < 1e-9)
        #expect(LockEffectRules.cornerArmLength(innerWidth: 80, innerHeight: 50) == 10.0)
        #expect(LockEffectRules.cornerArmLength(innerWidth: 20, innerHeight: 20) == 7.0)
        #expect(LockEffectRules.cornerArmLength(innerWidth: 0, innerHeight: 100) == 0.0)
    }

    /// 仅从已存在的未锁定状态切到锁定状态时触发开启瞬间动画。
    @Test func engageTriggerCondition() {
        #expect(LockEffectRules.shouldTriggerEngage(previousLocked: false, newLocked: true))
        #expect(!LockEffectRules.shouldTriggerEngage(previousLocked: nil, newLocked: true))
        #expect(!LockEffectRules.shouldTriggerEngage(previousLocked: true, newLocked: true))
        #expect(!LockEffectRules.shouldTriggerEngage(previousLocked: true, newLocked: false))
        #expect(!LockEffectRules.shouldTriggerEngage(previousLocked: false, newLocked: false))
    }

    /// 锁定布局开启时，规划器输出同时保留 isLocked 与活动窗口 highlightColor，互不覆盖。
    @Test func plannerPreservesHighlightWhenLocked() {
        var profile = Profile(id: "default", name: "Default")
        profile.behavior.lockLayout = true
        profile.overlay.highlightEnabled = true
        profile.overlay.highlightColor = "#ADFF2F"
        profile.overlay.highlightThickness = 4
        let clients = [
            Fixtures.character("Alpha", id: 1, pid: 100),
            Fixtures.character("Bravo", id: 2, pid: 200),
        ]
        let screens = [ScreenInfo(frame: ScreenRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: ScreenRect(x: 0, y: 0, width: 1920, height: 1040),
                                  scale: 1, isMain: true)]
        let input = PlannerInput(clients: clients, frontmost: .client(pid: 100), profile: profile,
                                 session: SessionState(), screens: screens, permissions: .granted,
                                 captureStates: [:], now: 10)
        let plan = ThumbnailPlanner.plan(input)
        #expect(plan.presentations.count == 2)
        // 活动客户端同时具备锁定标记与活动高亮。
        #expect(plan.presentations[0].isLocked)
        #expect(plan.presentations[0].isActive)
        #expect(plan.presentations[0].highlightColor == "#ADFF2F")
        #expect(LockEffectRules.borderInset(for: plan.presentations[0]) == 4)
        // 非活动客户端具备锁定标记与中性边框。
        #expect(plan.presentations[1].isLocked)
        #expect(!plan.presentations[1].isActive)
        #expect(plan.presentations[1].highlightColor == nil)
        #expect(plan.presentations[1].borderColor == "#C0C0C0")
    }
}
