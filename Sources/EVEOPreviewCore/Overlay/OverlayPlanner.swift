// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的规划（docs/design-intel-translate.md 8.6 节）：由客户端、前台、配置与屏幕算出每个已启用浮窗的
// 可见性、位置、层级与外观，以及活动角色。纯函数，由协调器在每次重算时调用。
// 类型与 activeCharacter 由 WP-0 写完整；plan 的可见性规则与 clampedFrame 归 WP-A。
// WP-0 的空实现：plan 返回空的 presentations、算好的 activeCharacter，nextWakeAt 为 nil。

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

    /// 规划全部浮窗。WP-0 的空实现：没有呈现，只算活动角色。
    public static func plan(_ input: OverlayPlannerInput) -> OverlayPlan {
        let active = activeCharacter(clients: input.clients, frontmost: input.frontmost,
                                     lastActivePID: input.session.lastActivePID)
        return OverlayPlan(presentations: [], activeCharacter: active, nextWakeAt: nil)
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

    /// 把保存的 frame 收进屏幕：尺寸夹到上下限，至少 40 点留在某个屏幕的可见区域内。
    /// WP-0 的空实现只夹尺寸，屏幕内的收拢归 WP-A。
    public static func clampedFrame(_ frame: ScreenRect, screens: [ScreenInfo]) -> ScreenRect {
        let width = min(max(frame.width, minimumSize.width), maximumSize.width)
        let height = min(max(frame.height, minimumSize.height), maximumSize.height)
        return ScreenRect(x: frame.x, y: frame.y, width: width, height: height)
    }
}
