// SPDX-License-Identifier: GPL-3.0-or-later
//
// 平台协议（架构文档 6.1 节）。协议只含 Core 的值类型，由 EVEOPreviewPlatform 实现，
// App 只通过这些协议使用平台能力，便于用 FakeServices 替换。
// 带 IOSurface 的捕获协议定义在 Platform 的 Capture/CaptureTypes.swift。

import Foundation

/// 窗口枚举：返回 EVE 客户端进程的候选窗口。
public protocol WindowProvider: Sendable {
    /// 返回 EVE 客户端进程的全部 layer 0 窗口。出错时返回空数组并记日志，不抛错。
    ///
    /// 有辅助功能权限时，结果里的 `title` 与 `isMinimized` 已用 AX 读到的值补全。
    func candidateWindows() async -> [WindowInfo]
}

/// `WorkspaceObserver` 上报的系统事件。
public enum WorkspaceEvent: Sendable, Equatable {
    /// 前台应用变了。
    case frontmostChanged
    /// 有应用启动或退出。App 收到后立即加调一次窗口轮询。
    case applicationsChanged
    /// 显示器的数量、排列或缩放变了。
    case screensChanged
    /// 当前空间（Space）变了。
    case activeSpaceChanged
    /// 系统从睡眠中唤醒。App 收到后让捕获服务重新对账。
    case didWake
}

/// 前台应用与屏幕的观察者。全部方法在主线程调用。
@MainActor public protocol WorkspaceObserver: AnyObject {
    /// 开始订阅系统通知，事件在主线程交给 handler。重复调用时以最后一次的 handler 为准。
    func start(handler: @escaping @MainActor (WorkspaceEvent) -> Void)
    /// 停止订阅。
    func stop()
    /// 判断前台是哪个客户端、本应用还是其他应用。
    ///
    /// - Parameter clientPIDs: 已知客户端的 PID。前台进程不在其中时返回 `.other`。
    func frontmost(among clientPIDs: [Int32]) -> FrontmostContext
    /// 当前全部屏幕，已换算成 Core 的全局屏幕坐标。
    func screens() -> [ScreenInfo]
}

/// 切换或最小化失败的原因。
public enum ActivationError: Error, Sendable, Equatable {
    /// 目标进程已退出。
    case processGone
    /// 在 AX 里找不到目标窗口。
    case windowNotFound
    /// 没有辅助功能权限。
    case accessibilityDenied
    /// 发出激活请求后，核对时目标仍不在前台。
    case notFrontmostAfterTimeout
    /// AX 调用返回错误，关联值是 `AXError` 的原始值。
    case axFailure(code: Int32)
}

/// 一次切换的结果。
public enum ActivationOutcome: Sendable, Equatable {
    /// 目标已到前台。
    case activated
    /// 进程已激活，但窗口没能还原或提升，关联值是原因。
    case activatedAppOnly(ActivationError)
    /// 切换失败，关联值是原因。
    case failed(ActivationError)
}

/// 窗口切换与最小化。
@MainActor public protocol WindowActivator: AnyObject {
    /// 把目标客户端带到前台；已最小化时（有辅助功能权限）先还原。
    func activate(_ target: ClientTarget) async -> ActivationOutcome
    /// 最小化目标客户端的窗口；没有辅助功能权限时返回 `.failure(.accessibilityDenied)`。
    func minimize(_ target: ClientTarget) async -> Result<Void, ActivationError>
}

/// 系统设置里的隐私面板。
public enum PermissionPane: Sendable {
    /// 「屏幕与系统录音」面板。
    case screenRecording
    /// 「辅助功能」面板。
    case accessibility
    /// 「文件与文件夹」面板。战斗提醒读「文稿」里的游戏日志时用到（反馈文档 7.9 节）。
    case filesAndFolders
}

/// 权限查询与引导。
@MainActor public protocol PermissionService: AnyObject {
    /// 当前两项权限的状态。
    func status() -> PermissionStatus
    /// 请求屏幕录制权限，返回调用时是否已授权。授权后通常要重启应用才生效。
    @discardableResult func requestScreenRecording() -> Bool
    /// 请求辅助功能权限（弹出系统提示）。授权后立即生效。
    func requestAccessibility()
    /// 打开系统设置的对应面板。
    func openSystemSettings(_ pane: PermissionPane)
    /// 以新实例重新打开本应用，然后退出当前进程。
    ///
    /// - Parameter activates: 是否把新实例带到前台。用户点的「重新启动」为真；
    ///   自动更新后的重新启动为假，不抢焦点。
    func relaunch(activates: Bool)
}

/// 一个热键绑定不能生效的原因（反馈文档 6.4 节）。
public enum HotkeyFailureReason: Sendable, Equatable {
    /// Carbon 的 `RegisterEventHotKey` 返回错误，关联值是 `OSStatus`，如 -9878 表示同进程内已注册。
    case registrationRejected(status: Int32)
    /// 鼠标绑定：没有辅助功能权限。
    case accessibilityRequired
    /// 鼠标绑定：有权限，但系统没有建出事件监听。
    case eventTapUnavailable
}

/// 一个热键注册失败的记录。
public struct HotkeyRegistrationFailure: Sendable, Equatable {
    /// 注册失败的绑定。
    public var binding: HotkeyBinding
    /// 失败的原因；设置窗口按它显示提示。
    public var reason: HotkeyFailureReason

    /// 用绑定与原因建一条失败记录。
    public init(binding: HotkeyBinding, reason: HotkeyFailureReason) {
        self.binding = binding
        self.reason = reason
    }
}

/// 全局热键注册器。键盘热键用 Carbon，鼠标热键用事件监听（反馈文档 6.5 节）。
@MainActor public protocol HotkeyRegistrar: AnyObject {
    /// 热键触发时在主线程调用，参数是 `HotkeyBinding.id`。
    var onHotkey: (@MainActor (HotkeyBinding.ID) -> Void)? { get set }
    /// 先停用全部旧绑定，再按当前的前台状态启用新绑定。返回失败的项。
    @discardableResult func replaceAll(with bindings: [HotkeyBinding]) -> [HotkeyRegistrationFailure]
    /// 告知前台是不是 EVE 客户端。值变化时启用或停用作用范围是 game 的绑定，返回当前全部失败的项。
    @discardableResult func setGameFrontmost(_ isFrontmost: Bool) -> [HotkeyRegistrationFailure]
    /// 暂停：注销全部热键但保留绑定表。录制热键期间调用，否则组合键被自己吞掉；应用退出时也调用，
    /// 等待退出期间不再吞新的点击。鼠标事件监听等已吞掉按下的按钮松开（或 10 秒到期）后才关闭。
    func suspend()
    /// 恢复：按保留的绑定表重新注册，返回注册失败的项（设置窗口据此提示）。没有暂停时返回当前的失败项。
    @discardableResult func resume() -> [HotkeyRegistrationFailure]
    /// 注册器自己发现失败项可能变了时在主线程调用（如鼠标事件监听被系统关掉、没能重新打开）。
    /// 协调器随后重新读权限并调用 `checkHealth()`。
    var onStateChange: (@MainActor () -> Void)? { get set }
    /// 巡检：检查后端是否仍按预期工作（如鼠标事件监听应打开却是关的），必要时拆除并记为失败；
    /// 监听不可用的失败项由巡检定时重试。返回当前全部失败的项。协调器每个轮询周期调用一次。
    @discardableResult func checkHealth() -> [HotkeyRegistrationFailure]
}

/// 游戏日志的跟踪服务（反馈文档 7.2 节～7.4 节）。全部方法在主线程调用。
@MainActor public protocol CombatLogMonitor: AnyObject {
    /// 一批受击事件，每个角色至多两条（伤害最大的一条与未命中各一条）。在主线程调用。
    var onEvents: (@MainActor ([CombatLogEvent]) -> Void)? { get set }
    /// 状态变化时在主线程调用。
    var onStatusChange: (@MainActor (CombatLogStatus) -> Void)? { get set }
    /// 当前状态。
    var status: CombatLogStatus { get }
    /// 开始跟踪。directory 为 nil 时自动查找。目录与上次相同时不做任何事，不同时切换目录。
    func start(directory: String?)
    /// 停止跟踪，关闭全部文件描述符，状态变成 `stopped`。
    func stop()
}

/// 聊天日志的跟踪服务（docs/macos/design-intel-translate.md 5.2 节～5.6 节）。全部方法在主线程调用。
/// 只读日志文件，不写、不改、不删 EVE 目录下的任何内容。
@MainActor public protocol ChatLogMonitor: AnyObject {
    /// 一批事件，按日志里的先后顺序。在主线程调用。
    var onEvents: (@MainActor ([ChatLogEvent]) -> Void)? { get set }
    /// 状态变化时在主线程调用。
    var onStatusChange: (@MainActor (ChatLogStatus) -> Void)? { get set }
    /// 当前状态。
    var status: ChatLogStatus { get }
    /// 正在跟踪的聊天日志文件的收听者与频道；还没扫描完或没有在跟踪时为 nil。
    var followedChannels: [FollowedChatChannel]? { get }
    /// followedChannels 变化时在主线程调用。
    var onFollowedChannelsChange: (@MainActor ([FollowedChatChannel]?) -> Void)? { get set }
    /// 开始跟踪。请求与上次相同时不做任何事，不同时按新请求重建并重新补读。
    func start(_ request: ChatLogRequest)
    /// 停止跟踪，关闭全部文件描述符，状态变成 `stopped`。
    func stop()
    /// 列出日志目录里最近 24 小时出现过的频道，给设置界面与翻译浮窗挑选。可在未跟踪时调用。
    /// 私聊频道与文件头不完整的文件不列出，结果按 `lastModified` 从新到旧排序。
    func discoverChannels(logDirectory: String?) async -> [DiscoveredChannel]
}
