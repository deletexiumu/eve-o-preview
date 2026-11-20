// SPDX-License-Identifier: GPL-3.0-or-later
//
// 基于 ScreenCaptureKit 的捕获服务（架构文档 6.3 节）。按规划器给出的期望对账：
// 新窗口建会话，规格变化延迟更新，隐藏的窗口宽限 3 秒后停流，消失的窗口立即销毁。
// 收到 userDeclined 后进入「权限被拒」状态，权限恢复前不再建会话。

@preconcurrency import ScreenCaptureKit
import EVEOPreviewCore
import os

/// 基于 `SCStream` 的捕获服务。全部方法在主线程调用。
@MainActor public final class SCKCaptureService: CaptureService {
    /// 收到新画面时在主线程调用。
    public var onFrame: (@MainActor (WindowID, CapturedFrame) -> Void)?
    /// 某个窗口的捕获状态变化时在主线程调用。
    public var onStateChange: (@MainActor (WindowID, CaptureState) -> Void)?

    /// 是否启用「5 秒无回调就重建」的看门狗（V5）。只影响之后新建的会话。
    public var watchdogEnabled: Bool

    /// 窗口 ID → 会话。
    private var sessions: [WindowID: WindowCaptureSession] = [:]
    /// 共用的 SCWindow 缓存。
    private let cache = ShareableContentCache()
    /// 是否处于「权限被拒」状态。
    private var permissionBlocked = false
    /// 进入「权限被拒」时 `CGPreflightScreenCaptureAccess()` 的值。
    /// 只有它当时为假、后来变为真，才认为用户重新授了权；当时就为真说明要重启应用才生效。
    private var preflightAtDenial = false
    /// `stopAll()` 已调用（应用正在退出）。之后的对账、恢复、重建都不再建流。
    private var isStopped = false
    /// 日志。
    private let log = PlatformLog.logger("Capture")

    /// 建一个捕获服务。
    ///
    /// - Parameter watchdogEnabled: 是否启用看门狗，默认见 `defaultWatchdogEnabled`。
    public init(watchdogEnabled: Bool = SCKCaptureService.defaultWatchdogEnabled) {
        self.watchdogEnabled = watchdogEnabled
    }

    /// 看门狗的默认开关，由 V5 的实测决定：开。
    ///
    /// 2026-11-20 实测 3 个客户端（在前台的与被遮挡的都测了）：EVE 一直在渲染，15 帧每秒的流每秒有
    /// 15～16 个 complete 回调，没有 idle 回调，相邻回调最长间隔 75～89 毫秒，远低于 5 秒的阈值。
    /// 唯一的长间隔出现在最小化期间（6.9～9.4 秒），此时窗口不在屏幕上，看门狗不计时，实测没有误触发。
    public static let defaultWatchdogEnabled = true

    /// 声明式对账。desired 是要捕获的窗口及规格；liveWindows 是仍然存在的窗口。
    public func reconcile(_ desired: [WindowID: CaptureSpec], liveWindows: Set<WindowID>) {
        guard !isStopped else { return }
        refreshPermissionBlock()
        // 不在 liveWindows 的窗口：立即销毁。
        for (id, session) in sessions where !liveWindows.contains(id) {
            sessions[id] = nil
            Task { await session.shutdown() }
            onStateChange?(id, .windowGone)
        }
        // 在 desired 里的窗口：没有会话就建，有就更新规格并取消宽限期停流。
        for (id, spec) in desired where liveWindows.contains(id) {
            let session = sessions[id] ?? makeSession(id, spec: spec)
            session.ensureRunning(spec: spec, permissionBlocked: permissionBlocked)
        }
        // 仍存在但不在 desired 里的窗口（缩略图被隐藏）：宽限期后停流。
        for (id, session) in sessions where desired[id] == nil {
            session.scheduleStop()
        }
    }

    /// 用户在菜单里选「恢复捕获」后调用，清除 stoppedByUser 或 permissionDenied 并重启。
    public func resume(_ window: WindowID) {
        guard !isStopped, let session = sessions[window] else { return }
        if session.state == .permissionDenied { permissionBlocked = false }
        if session.state == .stoppedByUser || session.state == .permissionDenied {
            session.restart()
        }
    }

    /// 系统唤醒后调用：重建正在运行或即将重建的会话（架构文档 6.6 节）。
    ///
    /// 睡眠期间流可能已失效却不报错；看门狗只在窗口在屏幕上时计时，所以这里主动重建。
    /// 用户停止的、权限被拒的、因隐藏而停流的会话不动。
    public func restartActiveSessions() {
        guard !isStopped else { return }
        for session in sessions.values where session.isActive {
            session.restart()
        }
    }

    /// 停止全部流，退出前调用。会话全部销毁，不再上报状态；之后的对账不再建流。
    /// 各会话的停流并行等待，一个卡住的流不会拖住其他流。
    public func stopAll() async {
        isStopped = true
        let all = Array(sessions.values)
        sessions.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for session in all {
                group.addTask { await session.shutdown() }
            }
        }
    }

    /// 某个窗口当前流的回调统计；没有会话或没有流时返回 nil。供探针与诊断使用。
    public func statistics(for window: WindowID) -> CaptureStatistics? {
        sessions[window]?.statistics
    }

    /// 某个窗口的当前状态；没有会话时返回 nil。
    public func state(for window: WindowID) -> CaptureState? {
        sessions[window]?.state
    }

    // MARK: - 私有

    /// 建会话并接上回调。
    private func makeSession(_ id: WindowID, spec: CaptureSpec) -> WindowCaptureSession {
        let session = WindowCaptureSession(windowID: id, spec: spec, cache: cache, watchdogEnabled: watchdogEnabled)
        session.onFrame = { [weak self] frame in
            self?.onFrame?(id, frame)
        }
        session.onStateChange = { [weak self] state in
            self?.sessionStateChanged(id, state)
        }
        sessions[id] = session
        return session
    }

    /// 会话状态变化：转给上层；遇到 permissionDenied 时进入「权限被拒」状态。
    private func sessionStateChanged(_ id: WindowID, _ state: CaptureState) {
        if state == .permissionDenied, !permissionBlocked {
            permissionBlocked = true
            preflightAtDenial = CGPreflightScreenCaptureAccess()
            log.error("屏幕录制被拒，权限恢复前不再建流")
        }
        onStateChange?(id, state)
    }

    /// 权限从无到有时解除「权限被拒」状态，之后的对账会重建会话。
    private func refreshPermissionBlock() {
        guard permissionBlocked, !preflightAtDenial, CGPreflightScreenCaptureAccess() else { return }
        permissionBlocked = false
        log.info("屏幕录制权限已恢复")
    }
}
