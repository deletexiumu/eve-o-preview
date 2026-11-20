// SPDX-License-Identifier: GPL-3.0-or-later
//
// 运行时模型（架构文档 5.1 节）：前台、权限、捕获规格与状态、会话状态。
// 这些值都不持久化，应用重启后重新得到。

import Foundation

/// 当前前台应用相对于 EVE 客户端的情况。
public enum FrontmostContext: Sendable, Equatable {
    /// 前台是某个已知客户端，关联值是它的 PID。
    case client(pid: Int32)
    /// 前台是本应用（例如设置窗口），按「仍在 EVE 环境内」处理。
    case selfApp
    /// 前台是其他应用。
    case other
}

/// 两项系统权限的授权状态。
public struct PermissionStatus: Sendable, Equatable {
    /// 是否有屏幕录制权限；没有时读不到画面，`kCGWindowName` 也为空。
    public var screenRecording: Bool
    /// 是否有辅助功能权限；没有时不能还原、最小化窗口，也读不到 AX 标题。
    public var accessibility: Bool

    /// 用两项权限的状态建一个值。
    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    /// 两项权限都有。
    public static let granted = PermissionStatus(screenRecording: true, accessibility: true)
    /// 两项权限都没有。
    public static let denied = PermissionStatus(screenRecording: false, accessibility: false)
}

/// 一条捕获流的规格。像素尺寸已乘过屏幕的 scale，且都是偶数。
public struct CaptureSpec: Sendable, Hashable {
    /// 输出画面的宽，单位是像素。
    public var pixelWidth: Int
    /// 输出画面的高，单位是像素。
    public var pixelHeight: Int
    /// 帧率上限，单位是帧每秒，范围 1～60。
    public var framesPerSecond: Int

    /// 用像素宽高与帧率建一个规格。
    public init(pixelWidth: Int, pixelHeight: Int, framesPerSecond: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.framesPerSecond = framesPerSecond
    }
}

/// 一条捕获流的状态，由 `CaptureService` 通过 `onStateChange` 上报。
public enum CaptureState: Sendable, Equatable {
    /// 没有会话，或会话已因隐藏而停流。
    case idle
    /// 已建会话，还没收到第一帧。
    case starting
    /// 正在出帧。
    case running
    /// 出错后等待重建。attempt 从 1 起计数，delay 是本次等待的秒数（见 `RetryPolicy`）。
    case retrying(attempt: Int, delay: Double)
    /// 用户在系统的录制指示器里停止了捕获，等用户在菜单里恢复。
    case stoppedByUser
    /// 系统拒绝捕获（缺屏幕录制权限），权限恢复前不再重试。
    case permissionDenied
    /// 窗口已不存在，会话已销毁。
    case windowGone
}

/// 不持久化的会话状态，由 `AppCoordinator` 持有。时间都是单调时钟的秒数。
public struct SessionState: Sendable, Equatable {
    /// 「全部隐藏」开关。
    public var hideAll: Bool
    /// 本次会话内被跳过、不参与循环的角色名；切换配置方案或重启后清空。
    public var skippedCharacters: Set<String>
    /// 鼠标悬停的缩略图对应的窗口；nil 表示没有悬停。
    public var hoveredWindow: WindowID?
    /// 正在拖动的缩略图对应的窗口；规划器不放大它们，App 不改它们的 frame。
    public var interactingWindows: Set<WindowID>
    /// 最近一次前台是 EVE 客户端或本应用的时刻，用于「离开 EVE 时隐藏」的延迟。
    public var lastEVEContextAt: Double
    /// 最近一次处于前台的客户端 PID；前台离开 EVE 后高亮仍留在它上面。
    public var lastActivePID: Int32?
    /// 战斗提醒，按窗口 ID 存放（反馈文档 7.7 节）。到期的项由协调器在每次重算开头删掉，
    /// 客户端消失时随之删除；规划器只认未到期的项（见 `hasActiveCombatAlert`）。
    public var combatAlerts: [WindowID: CombatAlertWindow]

    /// 用各字段建一个会话状态，默认值表示刚启动：不隐藏、没有跳过、没有悬停与拖动、没有提醒。
    public init(hideAll: Bool = false, skippedCharacters: Set<String> = [],
                hoveredWindow: WindowID? = nil, interactingWindows: Set<WindowID> = [],
                lastEVEContextAt: Double = 0, lastActivePID: Int32? = nil,
                combatAlerts: [WindowID: CombatAlertWindow] = [:]) {
        self.hideAll = hideAll
        self.skippedCharacters = skippedCharacters
        self.hoveredWindow = hoveredWindow
        self.interactingWindows = interactingWindows
        self.lastEVEContextAt = lastEVEContextAt
        self.lastActivePID = lastActivePID
        self.combatAlerts = combatAlerts
    }

    /// 窗口在 `now` 时刻是否有未到期的战斗提醒（`now < until`）。
    ///
    /// 可见性、呈现的 `alert`、不透明度与 `nextWakeAt` 都用这一个判断，保证四处对「到期」的理解一致。
    public func hasActiveCombatAlert(_ id: WindowID, now: Double) -> Bool {
        guard let alert = combatAlerts[id] else { return false }
        return alert.isActive(at: now)
    }

    /// 全部未到期提醒里最早的到期时刻；没有未到期的提醒时返回 nil。规划器用它安排 `nextWakeAt`。
    public func earliestCombatAlertExpiry(now: Double) -> Double? {
        combatAlerts.values.lazy.filter { $0.isActive(at: now) }.map(\.until).min()
    }
}

/// 一个窗口的战斗提醒时段，时间是单调时钟的秒数（反馈文档 7.7 节）。
///
/// 持续受击时 `until` 一直延长，`startedAt` 不变（见 `CombatAlertRules.extended`）。
public struct CombatAlertWindow: Sendable, Equatable {
    /// 本次提醒开始的时刻。
    public var startedAt: Double
    /// 提醒到期的时刻；`now >= until` 时视为已到期。
    public var until: Double

    /// 用开始与到期时刻建一个提醒时段。
    public init(startedAt: Double, until: Double) {
        self.startedAt = startedAt
        self.until = until
    }

    /// 在 `now` 时刻是否仍未到期。
    public func isActive(at now: Double) -> Bool {
        now < until
    }
}
