// SPDX-License-Identifier: GPL-3.0-or-later
//
// 规划器的输入与输出（架构文档 5.6 节）。规划器是纯函数：
// AppCoordinator 收集状态成 PlannerInput，得到 ThumbnailPlan 后分发给面板、捕获服务与配置。

import Foundation

/// 规划器的输入：一次重算所需的全部状态。
public struct PlannerInput: Sendable {
    /// 当前客户端，顺序即呈现的顺序（通常是 `ClientRegistry.clients`）。
    public var clients: [EVEClient]
    /// 当前前台。
    public var frontmost: FrontmostContext
    /// 当前配置方案。
    public var profile: Profile
    /// 会话状态。
    public var session: SessionState
    /// 当前全部屏幕。
    public var screens: [ScreenInfo]
    /// 权限状态。
    public var permissions: PermissionStatus
    /// 各窗口的捕获状态；没有记录的窗口按 `.idle` 处理。
    public var captureStates: [WindowID: CaptureState]
    /// 当前时刻，单调时钟的秒数，与 `SessionState.lastEVEContextAt` 同一时钟。
    public var now: Double

    /// 用各字段建一次规划的输入。
    public init(clients: [EVEClient], frontmost: FrontmostContext, profile: Profile, session: SessionState,
                screens: [ScreenInfo], permissions: PermissionStatus, captureStates: [WindowID: CaptureState],
                now: Double) {
        self.clients = clients
        self.frontmost = frontmost
        self.profile = profile
        self.session = session
        self.screens = screens
        self.permissions = permissions
        self.captureStates = captureStates
        self.now = now
    }
}

/// 没有画面时缩略图显示的占位。
public enum ThumbnailPlaceholder: Sendable, Equatable {
    /// 不显示占位。
    case none
    /// 等待第一帧。面板已有画面时，App 不用它遮住画面。
    case waitingForFrame
    /// 缺少屏幕录制权限，或系统拒绝了捕获。
    case needsScreenRecording
    /// 用户在系统的录制指示器里停止了捕获。
    case captureStopped
    /// 客户端窗口已最小化。
    case minimized
}

/// 一个缩略图在某一时刻应有的全部外观属性。
public struct ThumbnailPresentation: Sendable, Equatable, Identifiable {
    /// 客户端主窗口的窗口 ID。
    public var id: WindowID
    /// 客户端进程的 PID。
    public var pid: Int32
    /// 面板的 frame，全局屏幕坐标，已含悬停放大。
    /// 窗口在 `SessionState.interactingWindows` 里时是基准 frame，App 应保留拖动中的实际位置。
    public var frame: ScreenRect
    /// 是否显示面板。
    public var isVisible: Bool
    /// 标题文字（角色名、`EVE` 或 `EVE (<pid>)`）。
    public var title: String
    /// 是否显示标题。
    public var showsTitle: Bool
    /// 标题字号，单位是点。
    public var titleFontSize: Double
    /// 标题颜色，`#RRGGBB`。
    public var titleColor: String
    /// 面板不透明度，0～1。
    public var opacity: Double
    /// 高亮边框颜色 `#RRGGBB`；nil 表示不画高亮。
    public var highlightColor: String?
    /// 高亮边框粗细，单位是点。
    public var highlightThickness: Double
    /// 中性边框颜色 `#RRGGBB`；nil 表示不画中性边框。不看是否活动，视图先用高亮、没有高亮时用它（反馈文档 4.1 节）。
    public var borderColor: String?
    /// 中性边框粗细，单位是点。
    public var borderThickness: Double
    /// 战斗提醒；nil 表示没有未到期的提醒（反馈文档 7.7 节）。不含时间，提醒延长时呈现不变。
    public var alert: ThumbnailAlert?
    /// 是否为活动客户端（前台客户端；前台不是 EVE 时为最后活动的客户端）。
    public var isActive: Bool
    /// 角色是否在本次会话内被跳过，显示跳过标记。
    public var isSkipped: Bool
    /// 面板是否置顶。
    public var isAlwaysOnTop: Bool
    /// 置顶时是否要盖过原生全屏的客户端（v1.1.1）：有客户端是原生全屏时为真。全屏客户端的窗口在
    /// 状态栏层级（25），面板这时要用更高的层级；窗口模式下保持 `.floating`，不盖住 Dock、菜单栏与系统对话框。
    public var isOverFullScreen: Bool
    /// frame 是否为悬停放大后的尺寸。
    public var isZoomed: Bool
    /// 画面的显示范围（已裁掉标题栏），原点在左上角、y 轴向下。
    public var contentsRect: UnitRect
    /// 占位。
    public var placeholder: ThumbnailPlaceholder

    /// 用全部字段建一个呈现。第一轮反馈新增的边框与提醒字段放在最后，带默认值（不画、没有提醒）。
    public init(id: WindowID, pid: Int32, frame: ScreenRect, isVisible: Bool, title: String, showsTitle: Bool,
                titleFontSize: Double, titleColor: String, opacity: Double, highlightColor: String?,
                highlightThickness: Double, isActive: Bool, isSkipped: Bool, isAlwaysOnTop: Bool,
                isZoomed: Bool, contentsRect: UnitRect, placeholder: ThumbnailPlaceholder,
                borderColor: String? = nil, borderThickness: Double = 0, alert: ThumbnailAlert? = nil,
                isOverFullScreen: Bool = false) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.isVisible = isVisible
        self.title = title
        self.showsTitle = showsTitle
        self.titleFontSize = titleFontSize
        self.titleColor = titleColor
        self.opacity = opacity
        self.highlightColor = highlightColor
        self.highlightThickness = highlightThickness
        self.isActive = isActive
        self.isSkipped = isSkipped
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isOverFullScreen = isOverFullScreen
        self.isZoomed = isZoomed
        self.contentsRect = contentsRect
        self.placeholder = placeholder
        self.borderColor = borderColor
        self.borderThickness = borderThickness
        self.alert = alert
    }
}

/// 一个缩略图的战斗提醒外观：颜色与样式（反馈文档 7.7 节、7.8 节）。闪烁的动画由 App 的提醒层负责。
public struct ThumbnailAlert: Sendable, Equatable {
    /// 闪烁颜色，`#RRGGBB`。
    public var color: String
    /// 闪烁样式。
    public var style: CombatAlertStyle

    /// 用颜色与样式建一个提醒外观。
    public init(color: String, style: CombatAlertStyle) {
        self.color = color
        self.style = style
    }
}

/// 规划器的输出。
public struct ThumbnailPlan: Sendable, Equatable {
    /// 每个客户端一个呈现，顺序同 `PlannerInput.clients`。
    public var presentations: [ThumbnailPresentation]
    /// 要捕获的窗口及规格；只含可见的缩略图，没有屏幕录制权限时为空。
    public var captures: [WindowID: CaptureSpec]
    /// 要写进当前配置方案 `layouts` 的布局，只含本轮自动排位的角色。
    public var layoutsToPersist: [String: ThumbnailLayout]
    /// 下一次需要重算的时刻（单调时钟的秒数），取隐藏延迟到期与最早的战斗提醒到期中较早的一个；
    /// nil 表示不需要定时重算。
    public var nextWakeAt: Double?

    /// 用各字段建一个规划结果。
    public init(presentations: [ThumbnailPresentation], captures: [WindowID: CaptureSpec],
                layoutsToPersist: [String: ThumbnailLayout], nextWakeAt: Double?) {
        self.presentations = presentations
        self.captures = captures
        self.layoutsToPersist = layoutsToPersist
        self.nextWakeAt = nextWakeAt
    }
}
