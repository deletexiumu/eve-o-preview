// SPDX-License-Identifier: GPL-3.0-or-later
//
// 前台应用与屏幕的观察者（架构文档 4.3 节、6.6 节）。
// 订阅 NSWorkspace 与 NSApplication 的通知，换算成 Core 的 WorkspaceEvent。
// EVE 进程的 NSRunningApplication.processIdentifier 是 -1（事实 E5），前台不能按 PID 读取，
// 只能按 PID 取 NSRunningApplication 对象，再与 frontmostApplication 比较对象是否相等。

import AppKit
import EVEOPreviewCore

/// 基于 `NSWorkspace` 通知的前台与屏幕观察者。
@MainActor public final class SystemWorkspaceObserver: WorkspaceObserver {
    /// 已注册的通知观察者，`stop()` 时逐个移除。
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    /// 事件处理器；`start` 重复调用时以最后一次为准。
    private var handler: (@MainActor (WorkspaceEvent) -> Void)?

    /// 建一个观察者。调用 `start(handler:)` 后才开始订阅。
    public init() {}

    /// 开始订阅系统通知，事件在主线程交给 handler。重复调用时只替换 handler，不重复订阅。
    public func start(handler: @escaping @MainActor (WorkspaceEvent) -> Void) {
        self.handler = handler
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        subscribe(workspace, NSWorkspace.didActivateApplicationNotification, .frontmostChanged)
        subscribe(workspace, NSWorkspace.didLaunchApplicationNotification, .applicationsChanged)
        subscribe(workspace, NSWorkspace.didTerminateApplicationNotification, .applicationsChanged)
        subscribe(workspace, NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceChanged)
        subscribe(workspace, NSWorkspace.didWakeNotification, .didWake)
        subscribe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .screensChanged)
    }

    /// 停止订阅并丢弃 handler。
    public func stop() {
        for entry in tokens {
            entry.center.removeObserver(entry.token)
        }
        tokens.removeAll()
        handler = nil
    }

    /// 判断前台是哪个客户端、本应用还是其他应用。
    ///
    /// 做法：取 `frontmostApplication`，是本进程时返回 `.selfApp`；否则对每个客户端 PID 取
    /// `NSRunningApplication(processIdentifier:)`，与前台对象用 `==` 比较。
    /// V8 于 2026-11-20 实测成立：EVE 在前台时 `frontmostApplication.processIdentifier` 是 -1，
    /// 但 `==` 能认出前台客户端。用 AppKit 激活后与稳定状态下，`==` 与 AX 的 `kAXFrontmostAttribute`、
    /// CG 屏上窗口的叠放顺序都一致；只用 AX 或私有接口激活时，`==` 可能先于窗口到最上层就报告在前台。
    /// 所以这里判断的是「哪个应用在前台」，不保证它的窗口已在最上层。
    /// 前台对象取不到时返回 `.other`。
    public func frontmost(among clientPIDs: [Int32]) -> FrontmostContext {
        guard let front = NSWorkspace.shared.frontmostApplication else { return .other }
        if front == NSRunningApplication.current { return .selfApp }
        for pid in clientPIDs where NSRunningApplication(processIdentifier: pid) == front {
            return .client(pid: pid)
        }
        return .other
    }

    /// 当前全部屏幕，已换算成 Core 的全局屏幕坐标。第一块是主屏。
    public func screens() -> [ScreenInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            CoordinateConversion.screenInfo(screen, isMain: index == 0)
        }
    }

    /// 订阅一条通知，收到时把对应事件交给 handler。
    private func subscribe(_ center: NotificationCenter, _ name: Notification.Name, _ event: WorkspaceEvent) {
        // queue 为 .main，回调必在主线程，所以可以 assumeIsolated 进入主 actor。
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handler?(event)
            }
        }
        tokens.append((center, token))
    }
}
