// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的规划（docs/design-intel-translate.md 8.6 节）：由客户端、前台、配置与屏幕算出每个已启用浮窗的
// 可见性、位置、层级与外观，以及活动角色。纯函数，由协调器在每次重算时调用。
// 类型与 activeCharacter 由 WP-0 写完整；plan 的可见性规则与 clampedFrame 由 WP-A 完成。
// 可见性只有两条（8.6 节）：没有任何客户端时不可见；「离开 EVE 时隐藏」到期后不可见，开关与延迟与缩略图共用。
// 「全部隐藏」（session.hideAll）只管缩略图，不影响浮窗（Q23）。

import Foundation

/// 规划的输入。
public struct OverlayPlannerInput: Sendable {
    /// 已发现的客户端。
    public var clients: [EVEClient]
    /// 当前前台。
    public var frontmost: FrontmostContext
    /// 当前配置方案。
    public var profile: Profile
    /// 会话状态（最近活动的客户端、离开 EVE 的时刻）。
    public var session: SessionState
    /// 当前屏幕。
    public var screens: [ScreenInfo]
    /// 单调时钟的秒数，与 SessionState 同一时钟。
    public var now: Double

    /// 用各字段建输入。
    public init(clients: [EVEClient], frontmost: FrontmostContext, profile: Profile, session: SessionState,
                screens: [ScreenInfo], now: Double) {
        self.clients = clients
        self.frontmost = frontmost
        self.profile = profile
        self.session = session
        self.screens = screens
        self.now = now
    }
}

/// 一个浮窗的呈现。
public struct OverlayPresentation: Sendable, Equatable, Identifiable {
    /// 浮窗的种类。
    public var kind: OverlayKind
    /// 以种类为身份。
    public var id: OverlayKind { kind }
    /// 是否可见。
    public var isVisible: Bool
    /// 全局屏幕坐标的位置与尺寸。
    public var frame: ScreenRect
    /// 背景的不透明度。
    public var opacity: Double
    /// 第一行的字号。
    public var fontSize: Double
    /// 是否置顶（面板层级为 floating）。
    public var isAlwaysOnTop: Bool
    /// 是否盖在原生全屏的客户端上。
    public var isOverFullScreen: Bool
    /// 布局已锁定：忽略移动与缩放。
    public var isLocked: Bool

    /// 用各字段建呈现。
    public init(kind: OverlayKind, isVisible: Bool, frame: ScreenRect, opacity: Double, fontSize: Double,
                isAlwaysOnTop: Bool, isOverFullScreen: Bool, isLocked: Bool) {
        self.kind = kind
        self.isVisible = isVisible
        self.frame = frame
        self.opacity = opacity
        self.fontSize = fontSize
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isOverFullScreen = isOverFullScreen
        self.isLocked = isLocked
    }
}

/// 规划的结果。
public struct OverlayPlan: Sendable, Equatable {
    /// 只含已启用的浮窗。
    public var presentations: [OverlayPresentation]
    /// 活动角色；不论浮窗是否启用都算出来。
    public var activeCharacter: String?
    /// 下一次要重算的时刻（隐藏延迟到期），单调时钟；不用时为 nil。
    public var nextWakeAt: Double?

    /// 用各字段建结果。
    public init(presentations: [OverlayPresentation], activeCharacter: String?, nextWakeAt: Double?) {
        self.presentations = presentations
        self.activeCharacter = activeCharacter
        self.nextWakeAt = nextWakeAt
    }
}

/// 浮窗的规划器。
public enum OverlayPlanner {
    /// 浮窗尺寸的下限。
    public static let minimumSize = ScreenSize(width: 220, height: 120)
    /// 浮窗尺寸的上限。
    public static let maximumSize = ScreenSize(width: 900, height: 900)
    /// 浮窗的默认尺寸。
    public static let defaultSize = ScreenSize(width: 380, height: 260)

    /// 规划全部浮窗：每个已启用的浮窗一个呈现，按 intel、translation 的顺序；没启用的不出现。
    ///
    /// - 可见：有客户端，且「离开 EVE 时隐藏」没有到期（前台是本应用时不算离开）。
    /// - frame：保存过时取 `clampedFrame` 的结果，否则取 `defaultFrame`。
    /// - 层级：`isAlwaysOnTop` 取 `behavior.alwaysOnTop`；置顶且前台是原生全屏的客户端时 `isOverFullScreen` 为真。
    /// - `nextWakeAt`：有启用的浮窗、有客户端、隐藏延迟还没到期时是到期时刻，否则为 nil。
    /// - `activeCharacter` 不论浮窗是否启用都算出来。
    public static func plan(_ input: OverlayPlannerInput) -> OverlayPlan {
        let active = activeCharacter(clients: input.clients, frontmost: input.frontmost,
                                     lastActivePID: input.session.lastActivePID)
        let behavior = input.profile.behavior
        let hidden = input.clients.isEmpty || isHiddenAwayFromEVE(input)
        let overFullScreen = behavior.alwaysOnTop && isFrontmostFullScreen(input)
        var presentations: [OverlayPresentation] = []
        for kind in OverlayKind.allCases {
            guard let settings = enabledSettings(kind, profile: input.profile) else { continue }
            let frame = resolvedFrame(settings.frame, kind: kind, screens: input.screens)
            presentations.append(OverlayPresentation(
                kind: kind, isVisible: !hidden, frame: frame,
                opacity: clamp(settings.opacity, to: OverlayPanelSettings.opacityRange, fallback: 0.75),
                fontSize: clamp(settings.fontSize, to: OverlayPanelSettings.fontSizeRange, fallback: 12),
                isAlwaysOnTop: behavior.alwaysOnTop, isOverFullScreen: overFullScreen,
                isLocked: behavior.lockLayout))
        }
        let wake = presentations.isEmpty || input.clients.isEmpty ? nil : hideDeadline(input)
        return OverlayPlan(presentations: presentations, activeCharacter: active, nextWakeAt: wake)
    }

    /// 活动客户端的角色名：前台是客户端时取它；否则取最后活动的客户端；都没有时取第一个有角色的客户端。
    ///
    /// 前台是登录界面的客户端时返回 nil（用户正看着登录界面）。最后活动的客户端停在登录界面或已不在时，
    /// 退到 clients 里第一个有角色名的客户端。
    public static func activeCharacter(clients: [EVEClient], frontmost: FrontmostContext,
                                       lastActivePID: Int32?) -> String? {
        if case .client(let pid) = frontmost, let client = clients.first(where: { $0.pid == pid }) {
            return client.characterName
        }
        if let lastActivePID, let name = clients.first(where: { $0.pid == lastActivePID })?.characterName {
            return name
        }
        return clients.lazy.compactMap(\.characterName).first
    }

    /// 默认位置：主屏可见区域的右上角。预警浮窗距右边 20 点、距顶边 60 点；翻译浮窗在它正下方，隔 12 点。
    /// 没有屏幕时以 (0, 0) 为主屏左上角。
    public static func defaultFrame(kind: OverlayKind, screens: [ScreenInfo]) -> ScreenRect {
        let visible = (screens.first(where: \.isMain) ?? screens.first)?.visibleFrame
            ?? ScreenRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.maxX - 20 - defaultSize.width
        let top = visible.minY + 60
        let y = kind == .intel ? top : top + defaultSize.height + 12
        return ScreenRect(x: x, y: y, width: defaultSize.width, height: defaultSize.height)
    }

    /// 把保存的 frame 收进屏幕至少要留下的长度，单位是点。
    public static let minimumVisibleLength = 40.0

    /// 把保存的 frame 收进屏幕：尺寸夹到上下限，至少 40 点留在某个屏幕的可见区域内。
    ///
    /// 与某个屏幕的可见区域在水平、垂直方向都重叠至少 40 点时只夹尺寸，位置不动（多屏时不把浮窗拉到主屏）。
    /// 否则移到离 frame 中心最近的那个屏幕：左右各至少留 40 点，上下各至少留 40 点。没有屏幕时只夹尺寸。
    public static func clampedFrame(_ frame: ScreenRect, screens: [ScreenInfo]) -> ScreenRect {
        let width = clamp(frame.width, to: minimumSize.width...maximumSize.width, fallback: defaultSize.width)
        let height = clamp(frame.height, to: minimumSize.height...maximumSize.height, fallback: defaultSize.height)
        let x = frame.x.isFinite ? frame.x : 0
        let y = frame.y.isFinite ? frame.y : 0
        var result = ScreenRect(x: x, y: y, width: width, height: height)
        let margin = minimumVisibleLength
        if screens.contains(where: { overlap(result, $0.visibleFrame) }) { return result }
        guard let target = nearestScreen(to: result.center, in: screens)?.visibleFrame else { return result }
        // 可见区域比 40 点还窄时（不会出现在真实屏幕上）以左上角对齐，免得上下界颠倒。
        result.x = min(max(result.x, target.minX - width + margin), max(target.minX, target.maxX - margin))
        result.y = min(max(result.y, target.minY - height + margin), max(target.minY, target.maxY - margin))
        return result
    }

    /// 浮窗实际使用的 frame：保存过时取 `clampedFrame` 的结果，否则取 `defaultFrame`。
    /// 规划与设置页的数字框共用它，设置页显示的数值与浮窗实际位置一致。
    public static func resolvedFrame(_ saved: ScreenRect?, kind: OverlayKind, screens: [ScreenInfo]) -> ScreenRect {
        saved.map { clampedFrame($0, screens: screens) } ?? defaultFrame(kind: kind, screens: screens)
    }

    /// 设置页可以手工填写的 frame 字段（v1.2.1）。
    public enum FrameField: Sendable, CaseIterable {
        /// 左边的 x 坐标。
        case x
        /// 上边的 y 坐标（y 轴向下）。
        case y
        /// 宽度。
        case width
        /// 高度。
        case height
    }

    /// 在设置页改了一个字段后的新 frame：取整后写进该字段，再经 `clampedFrame` 夹尺寸、拉回屏幕。
    ///
    /// - Parameters:
    ///   - base: 改之前的 frame，一般是 `resolvedFrame` 的结果（没保存过时就是默认位置，写入后即保存下来）。
    ///   - field: 改的字段。
    ///   - value: 用户填写的数值。
    ///   - screens: 当前屏幕。
    /// - Returns: 新 frame；数值不是有限值时为 nil，调用方不写配置。
    public static func editedFrame(_ base: ScreenRect, field: FrameField, value: Double,
                                   screens: [ScreenInfo]) -> ScreenRect? {
        guard value.isFinite else { return nil }
        var frame = base
        let rounded = value.rounded()
        switch field {
        case .x: frame.x = rounded
        case .y: frame.y = rounded
        case .width: frame.width = rounded
        case .height: frame.height = rounded
        }
        return clampedFrame(frame, screens: screens)
    }

    // MARK: - 内部

    /// 已启用的浮窗的设置；没启用时为 nil。
    private static func enabledSettings(_ kind: OverlayKind, profile: Profile) -> OverlayPanelSettings? {
        switch kind {
        case .intel: return profile.intel.enabled ? profile.intel.overlay : nil
        case .translation: return profile.translation.enabled ? profile.translation.overlay : nil
        }
    }

    /// 「离开 EVE 时隐藏」是否已到期：开关打开、前台是其他应用、离开的时长不小于延迟。
    /// 规则与缩略图的第 4 条相同（VisibilityRules），但浮窗不受战斗提醒的例外影响。
    private static func isHiddenAwayFromEVE(_ input: OverlayPlannerInput) -> Bool {
        let behavior = input.profile.behavior
        return behavior.hideWhenEVENotFrontmost && input.frontmost == .other
            && input.now - input.session.lastEVEContextAt >= behavior.hideDelaySeconds
    }

    /// 隐藏延迟还没到期时返回到期时刻，否则返回 nil。
    private static func hideDeadline(_ input: OverlayPlannerInput) -> Double? {
        let behavior = input.profile.behavior
        guard behavior.hideWhenEVENotFrontmost, input.frontmost == .other else { return nil }
        let deadline = input.session.lastEVEContextAt + behavior.hideDelaySeconds
        return input.now < deadline ? deadline : nil
    }

    /// 前台是否是原生全屏的客户端，规则与缩略图相同。
    private static func isFrontmostFullScreen(_ input: OverlayPlannerInput) -> Bool {
        guard case .client(let pid) = input.frontmost else { return false }
        return input.clients.contains { $0.pid == pid && $0.isFullScreen == true }
    }

    /// 两个矩形在水平、垂直方向是否都重叠至少 minimumVisibleLength 点。
    private static func overlap(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        let horizontal = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let vertical = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return horizontal >= minimumVisibleLength && vertical >= minimumVisibleLength
    }

    /// 可见区域离点最近的屏幕；点在某个可见区域内时距离为 0。距离相同时取靠前的屏幕。
    private static func nearestScreen(to point: ScreenPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        func distance(_ rect: ScreenRect) -> Double {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        var best: (screen: ScreenInfo, distance: Double)?
        for screen in screens {
            let d = distance(screen.visibleFrame)
            if let current = best, d >= current.distance { continue }
            best = (screen, d)
        }
        return best?.screen
    }

    /// 把数值夹进范围；不是有限值时取 fallback。配置已由 ConfigValidator 夹过，这里只作防御。
    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
