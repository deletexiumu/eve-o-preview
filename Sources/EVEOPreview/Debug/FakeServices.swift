// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的假平台服务（架构文档 7.1 节）。环境变量 `EVEO_FAKE=1` 时由 AppDelegate 使用，
// 让界面在没有 EVE 客户端、没有任何权限的机器上也能完整操作。
//
// 假世界里有 3 个客户端：两个已选角色，第三个先停在登录界面，约 10 秒后「选角色」改名，
// 用来走一遍登录客户端 → 角色客户端的流程。切换与最小化只改假世界的状态，不碰真实窗口。
//
// 可选的环境变量：
// - `EVEO_FAKE_DENY=screen,ax`：假装缺少屏幕录制或辅助功能权限，用来查看占位与置灰的菜单项。
// - `EVEO_FAKE_STOP_AFTER=<秒>`：到时把第二个客户端的捕获置为「用户已停止」，用来查看「恢复捕获」。
// 捕获服务的假实现在 FakeCaptureService.swift，游戏日志服务的假实现在 FakeCombatLogMonitor.swift，
// 问题报告与更新服务的假实现在 FakeDiagnosticsService.swift、FakeUpdateService.swift（v1.1）。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform
import os

/// 演示模式的入口。
@MainActor
enum FakeServices {
    /// 是否启用演示模式（环境变量 `EVEO_FAKE=1`）。
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVEO_FAKE"] == "1"
    }

    /// 组装一套假服务。各服务共享同一个 `FakeWorld`。
    static func make() -> PlatformServices {
        let world = FakeWorld()
        let workspace = FakeWorkspaceObserver(world: world)
        let deny = Set((ProcessInfo.processInfo.environment["EVEO_FAKE_DENY"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let permissions = FakePermissionService(status: PermissionStatus(
            screenRecording: !deny.contains("screen"), accessibility: !deny.contains("ax")))
        let stopAfter = ProcessInfo.processInfo.environment["EVEO_FAKE_STOP_AFTER"].flatMap(Double.init)
        return PlatformServices(
            windows: FakeWindowProvider(world: world), workspace: workspace,
            activator: FakeWindowActivator(world: world, workspace: workspace, permissions: permissions),
            hotkeys: FakeHotkeyRegistrar(), permissions: permissions,
            capture: FakeCaptureService(world: world, stopSecondClientAfter: stopAfter),
            combatLog: FakeCombatLogMonitor(world: world),
            diagnostics: FakeDiagnosticsService(), updates: FakeUpdateService())
    }
}

// MARK: - 假世界

/// 一个假客户端的状态。
struct FakeClientState: Sendable {
    /// 进程 PID（取一个不会与真实进程混淆的大数）。
    var pid: Int32
    /// 主窗口的窗口 ID。
    var windowID: WindowID
    /// 当前标题；登录界面是 `EVE`。
    var title: String
    /// 选角色后的标题；nil 表示一开始就是角色客户端。
    var titleAfterLogin: String?
    /// 主窗口范围，Core 坐标。
    var frame: ScreenRect
    /// 是否已最小化。
    var isMinimized: Bool
    /// 画面的主色调，0～1 的色相。
    var hue: Double
}

/// 假世界：全部假服务共享的状态，用锁保护，可以在任意线程读写。
final class FakeWorld: Sendable {
    /// 锁内的状态。
    struct State: Sendable {
        /// 全部假客户端。
        var clients: [FakeClientState]
        /// 假的前台客户端 PID；nil 表示前台是别的应用。
        var frontmostPID: Int32?
    }

    /// 假客户端约在启动后多少秒完成登录（标题从 `EVE` 变成角色名）。
    static let loginDelay: TimeInterval = 10

    /// 状态与锁。
    let state: OSAllocatedUnfairLock<State>
    /// 创建时刻，用来计算登录延迟与画面动画。
    let startedAt = Date()

    /// 建 3 个客户端，窗口尺寸取 1280×754（与真实客户端 1728×1018 同宽高比）。
    init() {
        let size = ScreenSize(width: 1280, height: 754)
        let names: [(String, String?, Double)] = [
            ("EVE - Fake Alpha", nil, 0.58), ("EVE - Fake Bravo", nil, 0.08), ("EVE", "EVE - Fake Gamma", 0.33),
        ]
        let clients = names.enumerated().map { index, entry in
            FakeClientState(pid: Int32(90_001 + index), windowID: WindowID(rawValue: UInt32(70_001 + index)),
                            title: entry.0, titleAfterLogin: entry.1,
                            frame: ScreenRect(origin: ScreenPoint(x: 200 + 60 * Double(index), y: 120 + 40 * Double(index)),
                                              size: size),
                            isMinimized: false, hue: entry.2)
        }
        state = OSAllocatedUnfairLock(initialState: State(clients: clients, frontmostPID: nil))
    }

    /// 取全部客户端的快照；到了登录时刻的客户端先改名。
    func snapshot() -> [FakeClientState] {
        let loggedIn = Date().timeIntervalSince(startedAt) >= FakeWorld.loginDelay
        return state.withLock { state in
            if loggedIn {
                for index in state.clients.indices {
                    if let next = state.clients[index].titleAfterLogin {
                        state.clients[index].title = next
                        state.clients[index].titleAfterLogin = nil
                    }
                }
            }
            return state.clients
        }
    }

    /// 按窗口 ID 找客户端。
    func client(withWindowID id: WindowID) -> FakeClientState? {
        snapshot().first { $0.windowID == id }
    }

    /// 修改指定 PID 的客户端。
    func updateClient(pid: Int32, _ body: @Sendable (inout FakeClientState) -> Void) {
        state.withLock { state in
            if let index = state.clients.firstIndex(where: { $0.pid == pid }) {
                body(&state.clients[index])
            }
        }
    }
}

// MARK: - 窗口枚举

/// 假的窗口枚举。每个客户端除主窗口外再给一个 1280×33 的无标题辅助窗口，
/// 让 Core 的主窗口选择规则也参与演示（E6）。
struct FakeWindowProvider: WindowProvider {
    /// 假世界。
    let world: FakeWorld

    /// 每个客户端返回主窗口与一个辅助窗口；最小化的主窗口记为不在屏上，与真实窗口一致。
    func candidateWindows() async -> [WindowInfo] {
        world.snapshot().flatMap { client -> [WindowInfo] in
            let main = WindowInfo(windowID: client.windowID, pid: client.pid, title: client.title,
                                  frame: client.frame, isOnScreen: !client.isMinimized,
                                  isMinimized: client.isMinimized)
            let strip = WindowInfo(windowID: WindowID(rawValue: client.windowID.rawValue + 1_000), pid: client.pid,
                                   title: nil, frame: ScreenRect(origin: client.frame.origin,
                                                                 size: ScreenSize(width: client.frame.width, height: 33)),
                                   isOnScreen: true, isMinimized: nil)
            return [main, strip]
        }
    }
}

// MARK: - 前台与屏幕

/// 假的前台观察者。屏幕取真实的 `NSScreen`；前台客户端取假世界的记录。
/// 真实的其他应用被激活时，把假的前台清掉，使「离开 EVE 时隐藏」可以演示。
@MainActor
final class FakeWorkspaceObserver: WorkspaceObserver {
    /// 假世界。
    private let world: FakeWorld
    /// 协调器的事件回调。
    private var handler: (@MainActor (WorkspaceEvent) -> Void)?
    /// 通知订阅的句柄，stop() 时注销。
    private var tokens: [NSObjectProtocol] = []

    init(world: FakeWorld) {
        self.world = world
    }

    func start(handler: @escaping @MainActor (WorkspaceEvent) -> Void) {
        self.handler = handler
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSelf = app == NSRunningApplication.current
            MainActor.assumeIsolated { self?.otherApplicationActivated(isSelf: isSelf) }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.screensChanged) }
        })
    }

    func stop() {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        handler = nil
    }

    /// 本应用在前台（设置窗口）时是 selfApp；否则看假世界记录的前台客户端。
    func frontmost(among clientPIDs: [Int32]) -> FrontmostContext {
        if NSApp.isActive { return .selfApp }
        let pid = world.state.withLock { $0.frontmostPID }
        if let pid, clientPIDs.contains(pid) { return .client(pid: pid) }
        return .other
    }

    func screens() -> [ScreenInfo] {
        NSScreen.screens.enumerated().map { CoordinateConversion.screenInfo($1, isMain: $0 == 0) }
    }

    /// 发出一个事件，供假激活器在「切换」后通知协调器。
    func emit(_ event: WorkspaceEvent) {
        handler?(event)
    }

    /// 真实应用被激活：不是本应用时，假的前台客户端失效。
    private func otherApplicationActivated(isSelf: Bool) {
        if !isSelf {
            world.state.withLock { $0.frontmostPID = nil }
        }
        emit(.frontmostChanged)
    }
}

// MARK: - 切换与最小化

/// 假的窗口激活器：只改假世界的前台与最小化状态，然后发出前台变化事件。
@MainActor
final class FakeWindowActivator: WindowActivator {
    private let world: FakeWorld
    private let workspace: FakeWorkspaceObserver
    private let permissions: FakePermissionService
    private let log = AppLog.logger("Fake")

    init(world: FakeWorld, workspace: FakeWorkspaceObserver, permissions: FakePermissionService) {
        self.world = world
        self.workspace = workspace
        self.permissions = permissions
    }

    /// 假切换：把目标记为前台；有辅助功能权限时顺便还原最小化。没有权限时与真实实现一样只「激活进程」。
    func activate(_ target: ClientTarget) async -> ActivationOutcome {
        guard world.snapshot().contains(where: { $0.pid == target.pid }) else { return .failed(.processGone) }
        let canRestore = permissions.status().accessibility
        world.updateClient(pid: target.pid) { client in
            if canRestore { client.isMinimized = false }
        }
        world.state.withLock { $0.frontmostPID = target.pid }
        log.debug("假切换到 PID \(target.pid)")
        workspace.emit(.frontmostChanged)
        return canRestore ? .activated : .activatedAppOnly(.accessibilityDenied)
    }

    /// 假最小化：没有辅助功能权限时失败；最小化的客户端不再是前台。
    func minimize(_ target: ClientTarget) async -> Result<Void, ActivationError> {
        guard permissions.status().accessibility else { return .failure(.accessibilityDenied) }
        world.updateClient(pid: target.pid) { $0.isMinimized = true }
        world.state.withLock { state in
            if state.frontmostPID == target.pid { state.frontmostPID = nil }
        }
        workspace.emit(.frontmostChanged)
        return .success(())
    }
}

// MARK: - 热键与权限

/// 假的热键注册器：只记录绑定，不注册系统热键，避免演示时吞掉真实按键。
@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistrar {
    var onHotkey: (@MainActor (HotkeyBinding.ID) -> Void)?
    /// 假注册器没有会出故障的后端，从不调用。
    var onStateChange: (@MainActor () -> Void)?
    /// 当前绑定表。
    private(set) var bindings: [HotkeyBinding] = []
    private let log = AppLog.logger("Fake")

    func replaceAll(with bindings: [HotkeyBinding]) -> [HotkeyRegistrationFailure] {
        self.bindings = bindings
        log.debug("假注册 \(bindings.count) 个热键")
        return []
    }

    /// 假世界里没有作用范围，只返回空的失败项。
    func setGameFrontmost(_ isFrontmost: Bool) -> [HotkeyRegistrationFailure] { [] }

    func suspend() { log.debug("假热键暂停") }
    func resume() -> [HotkeyRegistrationFailure] {
        log.debug("假热键恢复")
        return []
    }

    /// 假世界里没有事件监听，巡检总是没有失败项。
    func checkHealth() -> [HotkeyRegistrationFailure] { [] }
}

/// 假的权限服务：初始状态由 `EVEO_FAKE_DENY` 决定，「请求」立即视为授权。
@MainActor
final class FakePermissionService: PermissionService {
    private var current: PermissionStatus
    private let log = AppLog.logger("Fake")

    init(status: PermissionStatus) {
        current = status
    }

    func status() -> PermissionStatus { current }

    func requestScreenRecording() -> Bool {
        let had = current.screenRecording
        current.screenRecording = true
        return had
    }

    func requestAccessibility() {
        current.accessibility = true
    }

    func openSystemSettings(_ pane: PermissionPane) {
        log.info("演示模式不打开系统设置：\(String(describing: pane), privacy: .public)")
    }

    func relaunch(activates: Bool) {
        log.info("演示模式不重新启动")
    }
}
