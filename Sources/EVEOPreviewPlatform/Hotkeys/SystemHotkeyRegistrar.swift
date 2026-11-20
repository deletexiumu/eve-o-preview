// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键注册器的总入口（反馈文档 6.5 节）。持有绑定表、isGameFrontmost、isSuspended，
// 把键盘绑定交给 CarbonHotkeyRegistrar，把鼠标绑定交给 MouseEventTap，并按作用范围启用或停用。
//
// 键盘绑定：「应启用」= 没有暂停，且作用范围是 global，或作用范围是 game 且前台是 EVE 客户端。
// 作用范围是 game 的键盘热键在前台不是 EVE 时没有注册，按键照常传给前台应用。
// 鼠标绑定：没有鼠标绑定时不建事件监听，也不查辅助功能权限；有时先查权限，再建监听。
// 监听的开关、吞掉的规则由 MouseEventTap 与 Core 的 MouseHotkeyMatcher 负责。
//
// onHotkey 存在本类，两个后端触发时都经 self 转上来（在触发的时刻读 onHotkey），
// 所以 onHotkey 在 init 之后才设置也能收到，不会出现「后端找不到上层、全部热键静默失效」。

import EVEOPreviewCore
import Foundation
import os

/// 键盘与鼠标热键的注册器。全部方法在主线程调用。
@MainActor public final class SystemHotkeyRegistrar: HotkeyRegistrar {
    /// 热键触发时在主线程调用，参数是 `HotkeyBinding.id`。
    public var onHotkey: (@MainActor (HotkeyBinding.ID) -> Void)?
    /// 鼠标事件监听被系统关掉、监听线程没能重新打开时在主线程调用，上层随后调 `checkHealth()`。
    public var onStateChange: (@MainActor () -> Void)?

    /// 键盘后端。
    private let keyboard = CarbonHotkeyRegistrar()
    /// 鼠标后端。第一次出现鼠标绑定时才建。
    private var mouseTap: MouseEventTap?
    /// 当前的绑定表（规划给出的全部绑定，含键盘与鼠标）。
    private var bindings: [HotkeyBinding] = []
    /// 前台是不是 EVE 客户端。
    private var isGameFrontmost = false
    /// 是否暂停（录制热键期间、应用退出期间）。
    private var isSuspended = false
    /// 键盘绑定最近一次注册失败的记录，按绑定 id 索引；注册成功时移除。
    private var keyboardFailures: [UInt32: HotkeyRegistrationFailure] = [:]
    /// 鼠标绑定的失败记录（没有权限或建不出监听时每条鼠标绑定一条）。
    private var mouseFailures: [HotkeyRegistrationFailure] = []
    /// 最近一次确认鼠标事件监听不可用（`eventTapUnavailable`）的时刻，单调时钟的秒数；
    /// 其余情况为 nil。巡检据此每隔 `MouseTapRetry.interval` 秒重建一次监听。
    private var mouseTapFailedAt: Double?
    /// 日志。
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "Hotkeys")

    /// 建一个注册器。键盘后端在这时安装 Carbon 事件处理器；鼠标后端等有鼠标绑定时再建。
    public init() {
        keyboard.onHotkey = { [weak self] id in self?.onHotkey?(id) }
    }

    /// 先停用全部旧绑定，再按当前的前台状态与暂停状态启用新绑定。返回当前全部失败的项。
    @discardableResult
    public func replaceAll(with bindings: [HotkeyBinding]) -> [HotkeyRegistrationFailure] {
        // 编号会从 1 起重排：开始新的一代，已排队的旧热键事件不会被当成新绑定执行。
        keyboard.beginNewGeneration()
        keyboardFailures = [:]
        self.bindings = bindings
        registerActiveKeyboardBindings()
        updateMouseBindings()
        return currentFailures
    }

    /// 告知前台是不是 EVE 客户端。值没变时不做任何事；变了只注册或注销作用范围是 game 的键盘热键，
    /// global 的不动，并让鼠标后端按新状态开关监听。返回当前全部失败的项。
    @discardableResult
    public func setGameFrontmost(_ isFrontmost: Bool) -> [HotkeyRegistrationFailure] {
        guard isFrontmost != isGameFrontmost else { return currentFailures }
        isGameFrontmost = isFrontmost
        if !isSuspended {
            if isFrontmost {
                // 只动 game 这一组：global 的失败项不在每次切进游戏时重试（反馈文档 6.5 节）。
                registerActiveKeyboardBindings(scope: .game)
            } else {
                let gameIDs = keyboardBindings.filter { $0.scope == .game }.map(\.id)
                keyboard.unregister(ids: gameIDs)
            }
        }
        mouseTap?.setGameFrontmost(isFrontmost)
        return currentFailures
    }

    /// 暂停全部热键（录制热键期间、应用退出期间）：注销全部 Carbon 热键，鼠标后端进入暂停，绑定表保留。
    ///
    /// 暂停期间新的按下一律放行。还有按下已被吞掉、没等到松开的按钮时，监听等它松开（或 10 秒到期）后再关。
    public func suspend() {
        isSuspended = true
        keyboard.unregisterAll()
        mouseTap?.setSuspended(true)
    }

    /// 恢复暂停前的绑定，返回当前全部失败的项。没有暂停时不重新注册。
    ///
    /// 录制期间别的应用可能占用了某个组合，所以恢复时的失败项要交给设置窗口显示，不能只记日志。
    @discardableResult
    public func resume() -> [HotkeyRegistrationFailure] {
        guard isSuspended else { return currentFailures }
        isSuspended = false
        registerActiveKeyboardBindings()
        mouseTap?.setSuspended(false)
        let failures = currentFailures
        if !failures.isEmpty {
            log.error("恢复热键时有 \(failures.count) 项不能生效")
        }
        return failures
    }

    /// 巡检鼠标事件监听（协调器每个轮询周期一次，`onStateChange` 之后也调一次）。
    ///
    /// - 监听应打开却是关的、又没能重新打开时，监听已被拆除，每条鼠标绑定记一条失败项。
    /// - 失败原因是 `eventTapUnavailable` 时，没有暂停且距上次失败满 `MouseTapRetry.interval` 秒，
    ///   就重新建一次监听：建成后失败项清除，仍建不成就重新计时。
    /// - 失败原因是 `accessibilityRequired` 时不重试，失败项保留到下一次 `replaceAll`（辅助功能权限变化时）。
    @discardableResult
    public func checkHealth() -> [HotkeyRegistrationFailure] {
        if let problem = mouseTap?.checkHealth() {
            recordMouseFailure(problem, previous: mouseFailures)
        } else if MouseTapRetry.isDue(failedAt: mouseTapFailedAt, now: ProcessInfo.processInfo.systemUptime,
                                      isSuspended: isSuspended) {
            log.info("重新建立鼠标事件监听")
            updateMouseBindings()
        }
        return currentFailures
    }

    // MARK: - 私有

    /// 绑定表里的键盘绑定。
    private var keyboardBindings: [HotkeyBinding] {
        bindings.filter { !$0.hotkey.isMouse }
    }

    /// 当前全部失败的项，按绑定 id 排序。
    private var currentFailures: [HotkeyRegistrationFailure] {
        (Array(keyboardFailures.values) + mouseFailures).sorted { $0.binding.id < $1.binding.id }
    }

    /// 注册此刻应启用、还没注册的键盘绑定，更新失败记录。scope 不为 nil 时只看这个作用范围的绑定。
    ///
    /// 没有注册过的 game 范围热键不产生失败项，等前台第一次变成 EVE 时才知道（反馈文档 6.5 节）。
    private func registerActiveKeyboardBindings(scope: HotkeyScope? = nil) {
        let registered = keyboard.registeredIDs
        for binding in keyboardBindings where !registered.contains(binding.id) {
            if let scope, binding.scope != scope { continue }
            guard HotkeyActivation.isActive(scope: binding.scope, isGameFrontmost: isGameFrontmost,
                                            isSuspended: isSuspended) else { continue }
            keyboardFailures[binding.id] = keyboard.register(binding)
        }
    }

    /// 把鼠标绑定交给鼠标后端，按结果更新失败记录。`replaceAll` 与巡检的重试都经过这里。
    private func updateMouseBindings() {
        let mouse = bindings.compactMap { binding -> MouseHotkeyMatcher.Binding? in
            guard let button = binding.hotkey.mouseButton else { return nil }
            return MouseHotkeyMatcher.Binding(id: binding.id, button: button, modifiers: binding.hotkey.modifiers,
                                              scope: binding.scope)
        }
        let previous = mouseFailures
        mouseFailures = []
        mouseTapFailedAt = nil
        guard !mouse.isEmpty || mouseTap != nil else { return }
        let tap = mouseTap ?? makeMouseTap()
        recordMouseFailure(tap.update(bindings: mouse), previous: previous)
    }

    /// 按鼠标后端的结果记失败项：没有权限或监听不可用时，每条鼠标绑定一条；其余结果不改失败项。
    ///
    /// 监听不可用时记下时刻，供巡检定时重试。失败项与 `previous` 相同时（重试仍失败）不再记错误日志，
    /// 持续失败时日志不会每 10 秒多一条。
    private func recordMouseFailure(_ result: MouseEventTap.StartResult, previous: [HotkeyRegistrationFailure]) {
        let reason: HotkeyFailureReason
        switch result {
        case .notNeeded, .running:
            return
        case .accessibilityRequired:
            reason = .accessibilityRequired
            mouseTapFailedAt = nil
        case .unavailable:
            reason = .eventTapUnavailable
            mouseTapFailedAt = ProcessInfo.processInfo.systemUptime
        }
        let mouse = bindings.filter(\.hotkey.isMouse)
        mouseFailures = mouse.map { HotkeyRegistrationFailure(binding: $0, reason: reason) }
        if mouseFailures != previous {
            log.error("鼠标热键不能生效：\(String(describing: result), privacy: .public)，共 \(mouse.count) 条")
        }
    }

    /// 建鼠标后端，并同步当前的前台与暂停状态。
    private func makeMouseTap() -> MouseEventTap {
        let tap = MouseEventTap(onFire: { [weak self] id in self?.onHotkey?(id) },
                                onProblem: { [weak self] in self?.onStateChange?() })
        tap.setGameFrontmost(isGameFrontmost)
        tap.setSuspended(isSuspended)
        mouseTap = tap
        return tap
    }

    // 注册器与应用同生命周期，不实现 deinit：deinit 不在主 actor 上，不能安全地访问两个后端。
}
