// SPDX-License-Identifier: GPL-3.0-or-later
//
// 鼠标热键的事件监听（反馈文档 6.6 节）。只在 Platform 内部使用，由 SystemHotkeyRegistrar 持有。
//
// 建立：CGEvent.tapCreate(会话级, 插在最前面, .defaultTap)，事件掩码只含 otherMouseDown、otherMouseUp、
// otherMouseDragged，键盘、左键、右键、滚轮与鼠标移动都不经过本应用。事件源挂在专用线程
// EVEOPreview.MouseTap 的运行循环上：没匹配的中键、侧键也要等回调返回才继续传给游戏，
// 主线程忙时不能拖慢它们。回调只读一次加锁的状态，不等主线程。
//
// 判断规则在 Core 的 MouseHotkeyMatcher 里；本类负责系统资源的建立、开关与拆除。
// 一次按下被吞掉后，监听要开到它的松开到来（或到期）为止，开关统一由主线程上的 `reevaluate()` 决定。
//
// 线程安全：
// - `state` 与 `resources` 各用一把锁，任何代码都不同时持有两把锁，不会互相等待。
// - 监听线程的线程体强引用本对象，线程结束前本对象不会释放，所以回调里的非持有指针一直有效。
// - 触发热键时切回主线程再调 onFire；切换期间绑定表可能已被替换（编号从 1 起重排），
//   所以带上判断时的代数，主线程上代数不同就丢弃，不会执行错的动作。
// - 监听线程上不调 `shutdown()`：它要等监听线程自己结束，会卡住回调。需要拆除时切回主线程再做。

import ApplicationServices
import CoreGraphics
import EVEOPreviewCore
import Foundation
import os

/// 鼠标热键的事件监听。全部公开方法在主线程调用；`handle` 与 `tapWasDisabled` 在监听线程上调用。
final class MouseEventTap: Sendable {
    /// `update` 与 `checkHealth` 的结果。
    enum StartResult: Sendable, Equatable {
        /// 没有鼠标绑定，不需要监听（已拆除，或等最后一次松开后拆除）。
        case notNeeded
        /// 监听已建成（是否打开取决于暂停与前台状态）。
        case running
        /// 没有辅助功能权限，没有调用 tapCreate，或已拆除。
        case accessibilityRequired
        /// 有权限，但 tapCreate 返回 nil，或监听被关掉后打不开（已拆除）。
        case unavailable
    }

    /// 加锁保护的匹配状态。
    struct State: Sendable {
        /// 绑定表、前台、暂停与 swallowedButtons。
        var matcher = MouseHotkeyMatcher()
        /// 代数：绑定表被替换或进入暂停时加 1，用来丢弃切回主线程前已过期的触发。
        var generation: UInt64 = 0
        /// 已安排的截止检查时刻（见 `MouseHotkeyMatcher.releaseDeadline`），避免重复安排。
        var scheduledCheck: Double?
    }

    /// 事件监听的系统资源。CoreFoundation 的引用不是 Sendable，单独放一个盒子，只在持锁时读写。
    struct Resources: @unchecked Sendable {
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var thread: Thread?
        /// 线程结束时发信号，`shutdown` 等它。
        var finished: DispatchSemaphore?
    }

    /// 匹配状态。
    let state = OSAllocatedUnfairLock(initialState: State())
    /// 系统资源。
    let resources = OSAllocatedUnfairLock(initialState: Resources())
    /// 热键触发时在主线程调用，参数是绑定 id。
    private let onFire: @MainActor @Sendable (UInt32) -> Void
    /// 监听被系统关掉、且监听线程没能重新打开时（没有权限或打开失败），在主线程调用。
    /// 上层随后重新读权限并调 `checkHealth()`，把失败显示到设置窗口。
    private let onProblem: @MainActor @Sendable () -> Void
    /// 日志。
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "MouseTap")

    /// 等监听线程启动或结束的最长时间。超时只记日志，不让主线程一直卡住。
    private static let threadTimeout: DispatchTimeInterval = .seconds(1)
    /// 触发从监听线程排到主线程，最多等多久仍执行。主线程卡住更久时，前台与作用范围可能已经变了，丢弃。
    static let maxFireAge: Double = 0.5

    /// 建一个监听对象。此时不建系统资源，第一次 `update` 有绑定时才建。
    init(onFire: @escaping @MainActor @Sendable (UInt32) -> Void,
         onProblem: @escaping @MainActor @Sendable () -> Void) {
        self.onFire = onFire
        self.onProblem = onProblem
    }

    /// 监听是否已建成。
    var isRunning: Bool {
        resources.withLock { $0.port != nil }
    }

    /// 单调时钟的秒数。
    private static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// 替换绑定表。没有辅助功能权限时拆掉监听；没有绑定时等按着的按钮松开后拆掉；
    /// 否则确保监听已建成，再按状态打开或关闭。
    func update(bindings: [MouseHotkeyMatcher.Binding]) -> StartResult {
        state.withLock { state in
            state.matcher.replaceBindings(bindings)
            state.generation &+= 1
        }
        // 先查权限：没有权限时不调 tapCreate（反馈文档 6.5 节），撤销权限后也拆掉已有的监听（R13）。
        guard AXIsProcessTrusted() else {
            shutdown()
            return bindings.isEmpty ? .notNeeded : .accessibilityRequired
        }
        guard !bindings.isEmpty else {
            // 还按着已吞掉的按钮时先留着监听，松开或到期后由 reevaluate 拆除。
            reevaluate()
            return .notNeeded
        }
        if !isRunning {
            guard start() else { return .unavailable }
        }
        reevaluate()
        return .running
    }

    /// 更新前台状态，并按新状态打开或关闭监听。
    func setGameFrontmost(_ isFrontmost: Bool) {
        state.withLock { $0.matcher.setGameFrontmost(isFrontmost) }
        reevaluate()
    }

    /// 更新暂停状态，并按新状态打开或关闭监听。进入暂停时代数加 1，已排队的触发作废。
    func setSuspended(_ isSuspended: Bool) {
        state.withLock { state in
            state.matcher.setSuspended(isSuspended)
            if isSuspended { state.generation &+= 1 }
        }
        reevaluate()
    }

    /// 按匹配状态决定监听的去留，在主线程调用。
    ///
    /// - 没有绑定、也没有按着的按钮：拆除。
    /// - 其余情况按 `shouldListen` 打开或关闭。
    /// - 只因按着按钮而开着时，在截止时刻再调一次本方法，到期后关闭（反馈文档 6.6 节）。
    func reevaluate() {
        let now = Self.uptime
        let (shouldListen, hasBindings, check) = state.withLock { state -> (Bool, Bool, Double?) in
            let deadline = state.matcher.refreshReleaseDeadline(now: now)
            var check: Double?
            if deadline != state.scheduledCheck {
                state.scheduledCheck = deadline
                check = deadline
            }
            return (state.matcher.shouldListen, !state.matcher.bindings.isEmpty, check)
        }
        if !hasBindings && !shouldListen {
            shutdown()
            return
        }
        setEnabled(shouldListen)
        if let check {
            // 多等 50 毫秒，保证到点时 refreshReleaseDeadline 看到的时刻已过截止时刻。
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, check - now) + 0.05) { [weak self] in
                self?.reevaluate()
            }
        }
    }

    /// 巡检，在主线程调用（协调器每个轮询周期一次，监听线程报告问题后也调一次）。
    ///
    /// 监听此刻应打开、实际却是关的：没有辅助功能权限时拆掉，返回 `.accessibilityRequired`；
    /// 有权限时重新打开一次，确认打开了返回 nil，仍是关的就拆掉，返回 `.unavailable`。
    /// 拆掉后没有端口，之后的巡检直接返回 nil。失败状态由上层保留：`.unavailable` 由上层定时调 `update` 重建，
    /// `.accessibilityRequired` 等权限变化后上层重新调 `update`。
    func checkHealth() -> StartResult? {
        guard let port = resources.withLock({ PortBox(port: $0.port) }).port,
              state.withLock({ $0.matcher.shouldListen }), !CGEvent.tapIsEnabled(tap: port) else { return nil }
        // 关着的这段时间里松开可能丢了，清掉按钮号；清掉后不再应打开时交给 reevaluate。
        let stillListen = state.withLock { state -> Bool in
            state.matcher.tapWasDisabled()
            return state.matcher.shouldListen
        }
        guard stillListen else {
            reevaluate()
            return nil
        }
        guard AXIsProcessTrusted() else {
            log.error("巡检：鼠标事件监听是关的，且没有辅助功能权限，拆除监听")
            shutdown()
            return .accessibilityRequired
        }
        CGEvent.tapEnable(tap: port, enable: true)
        if CGEvent.tapIsEnabled(tap: port) {
            log.error("巡检：鼠标事件监听是关的，已重新打开")
            return nil
        }
        log.error("巡检：鼠标事件监听重新打开失败，拆除监听")
        shutdown()
        return .unavailable
    }

    /// 拆掉监听并结束线程。没有建过时什么也不做。只在主线程调用。
    ///
    /// 顺序：关掉监听，作废端口（同时作废事件源），从运行循环移除事件源，停下运行循环，等线程结束。
    /// 线程还没进入 CFRunLoopRun 时停止请求会丢，但事件源已移除，运行循环没有事件源会立即返回，线程照样结束。
    func shutdown() {
        let taken = resources.withLock { resources -> Resources in
            let taken = resources
            resources = Resources()
            return taken
        }
        guard let port = taken.port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop = taken.runLoop {
            if let source = taken.source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        if taken.finished?.wait(timeout: .now() + Self.threadTimeout) == .timedOut {
            log.error("鼠标监听线程没有在 1 秒内结束")
        }
        // 监听没了，之后的松开事件收不到，清掉残留的按钮号。
        state.withLock { $0.matcher.tapWasDisabled() }
        log.info("鼠标事件监听已拆除")
    }

    /// 在监听线程上判断一个事件，返回 true 表示吞掉。
    func handle(type: CGEventType, button: Int, flags: CGEventFlags) -> Bool {
        let kind: MouseButtonEventKind
        switch type {
        case .otherMouseDown: kind = .down
        case .otherMouseUp: kind = .up
        case .otherMouseDragged: kind = .dragged
        default: return false
        }
        let modifiers = Self.modifiers(from: flags)
        let (decision, generation, released) = state.withLock { state in
            let decision = state.matcher.handle(kind, button: button, modifiers: modifiers)
            // 吞掉的是最后一个按着的按钮，且已没有生效的绑定：监听可以关了。
            let released = kind == .up && decision == .swallow && !state.matcher.shouldListen
            return (decision, state.generation, released)
        }
        switch decision {
        case .pass:
            return false
        case .swallow:
            // 开关与拆除只在主线程做（拆除要等本线程结束，不能在这里做）。
            if released {
                DispatchQueue.main.async { [self] in reevaluate() }
            }
            return true
        case .fire(let id):
            let onFire = self.onFire
            let firedAt = Self.uptime
            DispatchQueue.main.async { [self] in
                // 切回主线程期间绑定表被替换或进入暂停时，这次触发作废。
                guard isCurrent(generation) else { return }
                // 主线程卡住太久时前台与作用范围可能已经变了，这次触发作废。
                let age = Self.uptime - firedAt
                guard age <= Self.maxFireAge else {
                    log.error("鼠标热键触发排队 \(age, format: .fixed(precision: 2)) 秒才到主线程，已丢弃")
                    return
                }
                MainActor.assumeIsolated { onFire(id) }
            }
            return true
        }
    }

    /// 回调收到 `tapDisabledByTimeout` 或 `tapDisabledByUserInput` 时在监听线程上调用。
    ///
    /// 本应用自己调 `tapEnable(false)` 关监听时，回调也会收到 `tapDisabledByUserInput`（2026-11-20 在 macOS 27
    /// 上用探针看到），这类通知不算故障。只有监听此刻应打开、实际却是关的，才算被系统关掉：
    /// - 清掉残留的按钮号（期间的松开可能丢了）。清掉后不再应打开时，切回主线程重新判断。
    /// - 没有辅助功能权限时不重新打开，切回主线程报告问题，由上层拆除监听并显示「需要辅助功能权限」。
    /// - 有权限时重新打开，确认真的打开了才记「已重新打开」；仍是关的就切回主线程报告问题。
    func tapWasDisabled(_ type: CGEventType) {
        guard let port = resources.withLock({ PortBox(port: $0.port) }).port,
              !CGEvent.tapIsEnabled(tap: port), state.withLock({ $0.matcher.shouldListen }) else { return }
        let stillListen = state.withLock { state -> Bool in
            state.matcher.tapWasDisabled()
            return state.matcher.shouldListen
        }
        guard stillListen else {
            DispatchQueue.main.async { [self] in reevaluate() }
            return
        }
        guard AXIsProcessTrusted() else {
            log.error("鼠标事件监听被系统关闭（类型 \(type.rawValue, privacy: .public)），没有辅助功能权限，不重新打开")
            reportProblem()
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            log.error("鼠标事件监听被系统关闭（类型 \(type.rawValue, privacy: .public)），重新打开失败")
            reportProblem()
            return
        }
        log.error("鼠标事件监听被系统关闭（类型 \(type.rawValue, privacy: .public)），已重新打开")
    }

    // MARK: - 私有

    /// 切回主线程调 onProblem。
    private func reportProblem() {
        let onProblem = self.onProblem
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onProblem() }
        }
    }

    /// 判断时的代数是否仍是当前代数，且没有暂停。
    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation && !$0.matcher.isSuspended }
    }

    /// 把监听打开或关闭；已是目标状态时不动。
    private func setEnabled(_ shouldListen: Bool) {
        guard let port = resources.withLock({ PortBox(port: $0.port) }).port else { return }
        if CGEvent.tapIsEnabled(tap: port) != shouldListen {
            CGEvent.tapEnable(tap: port, enable: shouldListen)
            log.info("鼠标事件监听\(shouldListen ? "打开" : "关闭", privacy: .public)")
        }
    }

    /// 建事件监听与它的线程，成功时返回 true。之后由 reevaluate 按状态打开或关闭。
    private func start() -> Bool {
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: mouseEventTapCallback, userInfo: pointer) else {
            // 记 info：上层每 10 秒重试一次，失败项变化时由 SystemHotkeyRegistrar 记一条 error。
            log.info("CGEvent.tapCreate 返回 nil，鼠标热键不可用")
            return false
        }
        // tapCreate 建出的监听默认是打开的，这里不先关上：关上会让回调收到一条 tapDisabledByUserInput，
        // 此时绑定表已就位，会被当成系统关闭而误记错误。线程就绪前到达的事件排在端口里，
        // 线程起来后照常判断；随后 reevaluate 按状态决定开关。
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            log.info("CFMachPortCreateRunLoopSource 返回 nil，鼠标热键不可用")
            return false
        }
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let sourceBox = SourceBox(source: source)
        // 线程体强引用 self：线程结束前本对象不会释放，回调里的非持有指针一直有效。
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, sourceBox.source, .commonModes)
            resources.withLockUnchecked { $0.runLoop = runLoop }
            ready.signal()
            // 停止请求或事件源被移除时返回。
            CFRunLoopRun()
            finished.signal()
        }
        thread.name = "EVEOPreview.MouseTap"
        thread.qualityOfService = .userInteractive
        // CoreFoundation 的引用不是 Sendable，用 withLockUnchecked 写入；Resources 只在持锁时读写。
        resources.withLockUnchecked { resources in
            resources.port = port
            resources.source = source
            resources.thread = thread
            resources.finished = finished
        }
        thread.start()
        if ready.wait(timeout: .now() + Self.threadTimeout) == .timedOut {
            log.error("鼠标监听线程没有在 1 秒内就绪")
        }
        log.info("鼠标事件监听已建成")
        return true
    }

    /// CGEvent 的修饰键 → Core 的修饰键。只看 Command、Option、Control、Shift，大写锁定、fn、小键盘位忽略。
    static func modifiers(from flags: CGEventFlags) -> HotkeyModifiers {
        var result = HotkeyModifiers()
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}

/// 端口的盒子，用来把端口从锁里带出来。端口本身线程安全，只是没有标 Sendable。
private struct PortBox: @unchecked Sendable {
    let port: CFMachPort?
}

/// 事件源的盒子，用来把事件源交给监听线程。CFRunLoopAddSource 可以在任何线程调用。
private struct SourceBox: @unchecked Sendable {
    let source: CFRunLoopSource
}

/// 事件监听的 C 回调，在监听线程上调用。userInfo 是 MouseEventTap 的非持有指针，线程存活期间一直有效。
private func mouseEventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                   _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // 放行这个事件；确实被系统关掉时按权限决定是否重新打开，本应用自己关的不处理。
        tap.tapWasDisabled(type)
        return Unmanaged.passUnretained(event)
    case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        return tap.handle(type: type, button: button, flags: event.flags) ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}
