// SPDX-License-Identifier: GPL-3.0-or-later
//
// 捕获服务的类型（架构文档 6.1 节）。因为带 IOSurface，所以定义在 Platform 而不在 Core。
// 实现见 SCKCaptureService.swift（WP-B）。

import AppKit
import IOSurface
import EVEOPreviewCore

/// 捕获到的一帧画面。
///
/// IOSurface 本身可跨线程传递，但 Swift 不知道这一点，所以标为 `@unchecked Sendable`；
/// 帧只在流的队列上创建，然后整体交给主线程，不再修改。
public struct CapturedFrame: @unchecked Sendable {
    /// 画面所在的 IOSurface，直接设给 `CALayer.contents`。
    public let surface: IOSurface
    /// 画面在 surface 里的位置，单位是像素（取自 `SCStreamFrameInfo.contentRect`）。
    public let contentRect: CGRect

    /// 用 surface 与画面位置建一帧。
    public init(surface: IOSurface, contentRect: CGRect) {
        self.surface = surface
        self.contentRect = contentRect
    }
}

/// 捕获服务：按规划器给出的期望对账，管理每个窗口的捕获流。全部方法在主线程调用。
@MainActor public protocol CaptureService: AnyObject {
    /// 收到新画面时在主线程调用。主线程忙时中间的帧会被丢弃，只交付最新一帧。
    var onFrame: (@MainActor (WindowID, CapturedFrame) -> Void)? { get set }
    /// 某个窗口的捕获状态变化时在主线程调用。
    var onStateChange: (@MainActor (WindowID, CaptureState) -> Void)? { get set }
    /// 声明式对账。desired 是要捕获的窗口及规格；liveWindows 是仍然存在的窗口。
    ///
    /// 不在 desired 但仍存在的窗口 3 秒后停流；不在 liveWindows 的窗口立即销毁会话（见 6.3 节）。
    func reconcile(_ desired: [WindowID: CaptureSpec], liveWindows: Set<WindowID>)
    /// 用户在菜单里选「恢复捕获」后调用，清除 stoppedByUser 状态并重启。
    func resume(_ window: WindowID)
    /// 系统唤醒后调用：重建正在运行或即将重建的会话（6.6 节）。用户停止、权限被拒、已停流的会话不动。
    func restartActiveSessions()
    /// 停止全部流，退出前调用。之后的 `reconcile` 不再建流。
    func stopAll() async
}
