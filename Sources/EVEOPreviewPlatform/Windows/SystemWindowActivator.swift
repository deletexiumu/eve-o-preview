// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口切换与最小化（架构文档 6.4 节）。macOS 14 起应用激活是协作式的，
// 后台应用发出的激活请求可能被系统忽略，所以按「AppKit 激活 + AX 提升 + 核对 + 重试 + 私有接口后备」
// 的顺序做，每一步都记进 lastTrace，供探针打印和排查。

import AppKit
import EVEOPreviewCore
import os

/// 激活过程中的一步记录。
public struct ActivationTraceEntry: Sendable, Equatable {
    /// 步骤名，如 `activate(from:)`、`AXRaise`、`verify`。
    public var step: String
    /// 从 `activate(_:)` 开始到这一步结束经过的毫秒数。
    public var elapsedMilliseconds: Double
    /// 这一步的结果说明。
    public var detail: String
}

/// 基于 AppKit、AX 与私有接口后备的窗口激活器。
@MainActor public final class SystemWindowActivator: WindowActivator {
    /// 激活时启用哪些手段。默认全部启用；探针用它单独测试每种手段。
    public struct Mechanisms: OptionSet, Sendable {
        /// 位集合的原始值。
        public let rawValue: UInt8
        /// 用原始值建一个集合。
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// 第 3 步：`NSRunningApplication.activate`。
        public static let appKit = Mechanisms(rawValue: 1)
        /// 第 4 步：AX 还原、提升、设主窗口、设前台。
        public static let accessibility = Mechanisms(rawValue: 2)
        /// 核对失败后的私有接口后备。
        public static let privateFallback = Mechanisms(rawValue: 4)
        /// 全部手段。
        public static let all: Mechanisms = [.appKit, .accessibility, .privateFallback]
    }

    /// 第一次核对前最多等待的秒数。
    static let firstCheckTimeout = 0.1
    /// 重试后最多等待的秒数。
    static let retryCheckTimeout = 0.3
    /// 核对时轮询前台的间隔，单位是秒。
    static let pollInterval = 0.02

    /// 启用的手段。
    public var mechanisms: Mechanisms
    /// 最近一次 `activate(_:)` 的逐步记录。
    public private(set) var lastTrace: [ActivationTraceEntry] = []

    /// 共用的 AX 执行者。
    private let ax: AXWorker
    /// 用来核对前台的观察者，与 App 判断活动客户端用同一办法（4.3 节）。
    private let workspace: any WorkspaceObserver
    /// 本次激活的起始时刻，用来算每一步的耗时。
    private var startedAt = ContinuousClock.now
    /// 激活的序号，每次调用 `activate(_:)` 加 1。按住热键连续循环时前一次激活还没结束，
    /// 新的一次就开始了；旧的一次据此发现自己已被取代，不再重试、不再用后备，也不再写 lastTrace，
    /// 避免把前台抢回旧目标。
    private var latestToken = 0
    /// 日志。
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "Activator")

    /// 建一个激活器。
    ///
    /// - Parameters:
    ///   - ax: 共用的 AX 执行者。
    ///   - workspace: 核对前台用的观察者。
    ///   - mechanisms: 启用的手段，默认全部。
    public init(ax: AXWorker, workspace: any WorkspaceObserver, mechanisms: Mechanisms = .all) {
        self.ax = ax
        self.workspace = workspace
        self.mechanisms = mechanisms
    }

    /// 把目标客户端带到前台；已最小化时（有辅助功能权限）先还原。
    ///
    /// 结果：目标在前台且 AX 提升成功返回 `.activated`；在前台但 AX 失败或没有权限返回
    /// `.activatedAppOnly`；仍不在前台返回 `.failed(.notFrontmostAfterTimeout)`。
    /// 「在前台」只按 `frontmost(among:)` 判断（应用级），不核对窗口叠放顺序。
    ///
    /// 可以重入：本次还没返回时又调用了 `activate(_:)`，本次就被取代，跳过剩下的重试与后备，
    /// 按当时的核对结果返回（通常是 `.failed(.notFrontmostAfterTimeout)`），调用方应忽略被取代的结果。
    public func activate(_ target: ClientTarget) async -> ActivationOutcome {
        latestToken += 1
        let token = latestToken
        // 同时作废旧激活还在 AXWorker 上排队或执行中的提升（它们在每次写操作前核对这个序号）。
        let raiseRequest = ax.beginRaiseRequest()
        startedAt = .now
        lastTrace = []
        // 第 1 步：进程已退出时直接失败。
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            record("lookup", "进程不存在")
            return .failed(.processGone)
        }
        // 第 2 步：本应用在前台时把激活权让给目标，否则系统可能拒绝后面的请求。
        if NSApp?.isActive == true {
            NSApp.yieldActivation(to: app)
            record("yieldActivation", "本应用在前台，已让出")
        }
        // 第 3 步：主线程立即发出，不等 AX。
        if mechanisms.contains(.appKit) { requestActivation(app) }
        // 第 4 步：AX 与核对并行进行。
        let axTask = startAXRaise(target, token: token, request: raiseRequest)
        // 第 5 步：核对，失败时重做第 3 步一次，再失败时用私有接口后备。被取代后两者都跳过。
        var isFront = await waitForFront(target.pid, timeout: Self.firstCheckTimeout, token: token)
        if !isFront, token == latestToken, mechanisms.contains(.appKit) {
            requestActivation(app)
            isFront = await waitForFront(target.pid, timeout: Self.retryCheckTimeout, token: token)
        }
        if !isFront, token == latestToken, mechanisms.contains(.privateFallback) {
            let result = PrivateActivation.bringToFront(pid: target.pid, windowID: target.windowID.rawValue)
            record("SLPSSetFrontProcess", "\(result)")
            if result == .requested {
                isFront = await waitForFront(target.pid, timeout: Self.retryCheckTimeout, token: token)
            }
        }
        let axError = await axTask?.value
        return outcome(isFront: isFront, axError: axError, axAttempted: axTask != nil, pid: target.pid,
                       superseded: token != latestToken)
    }

    /// 最小化目标客户端的窗口；没有辅助功能权限时返回 `.failure(.accessibilityDenied)`。
    public func minimize(_ target: ClientTarget) async -> Result<Void, ActivationError> {
        let result = await ax.minimize(pid: target.pid, title: target.title)
        if case .failure(let error) = result {
            log.error("最小化失败：pid \(target.pid) \(String(describing: error), privacy: .public)")
        }
        return result
    }

    // MARK: - 步骤

    /// 第 3 步：按系统版本选激活接口。
    private func requestActivation(_ app: NSRunningApplication) {
        let accepted: Bool
        if #available(macOS 15, *) {
            accepted = app.activate(from: NSRunningApplication.current, options: [])
        } else {
            accepted = app.activate(options: [])
        }
        record("activate", accepted ? "请求已接受" : "请求被拒绝")
    }

    /// 第 4 步：有权限且启用了 AX 时在 `AXWorker` 上提升窗口，返回结果的任务。
    /// 任务的值是失败原因；成功或被新的激活取代时为 nil（被取代的结果调用方会忽略）。
    private func startAXRaise(_ target: ClientTarget, token: Int,
                              request: UInt64) -> Task<ActivationError?, Never>? {
        guard mechanisms.contains(.accessibility) else { return nil }
        guard AXWorker.isTrusted else {
            record("AXRaise", "没有辅助功能权限，跳过")
            return Task { .accessibilityDenied }
        }
        let ax = self.ax
        return Task { @MainActor [weak self] in
            let result = await ax.raise(pid: target.pid, title: target.title, request: request)
            switch result {
            case .completed(let report):
                self?.record("AXRaise", Self.describe(report), token: token)
                return report.succeeded ? nil : .axFailure(code: (report.firstFailure ?? .failure).rawValue)
            case .failed(let error):
                self?.record("AXRaise", "失败：\(error)", token: token)
                return error
            case .superseded:
                // 已有新的激活：剩下的写操作没有执行，lastTrace 属于新激活，不记。
                return nil
            }
        }
    }

    /// 在 timeout 秒内轮询前台，目标到前台立即返回真；被取代时立即返回假。
    private func waitForFront(_ pid: Int32, timeout: Double, token: Int) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while token == latestToken {
            if workspace.frontmost(among: [pid]) == .client(pid: pid) {
                record("verify", "已在前台")
                return true
            }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(Int(Self.pollInterval * 1000)))
        }
        record("verify", token == latestToken ? "\(Int(timeout * 1000)) 毫秒内未到前台" : "已被新的激活取代",
               token: token)
        return false
    }

    /// 第 6 步：由前台核对与 AX 结果得出最终结果。
    ///
    /// 被新的激活取代时同样返回 `.failed(.notFrontmostAfterTimeout)`，但只记调试日志：
    /// 按住循环热键时这是正常情况，不是错误。
    private func outcome(isFront: Bool, axError: ActivationError??, axAttempted: Bool,
                         pid: Int32, superseded: Bool) -> ActivationOutcome {
        guard isFront else {
            if superseded {
                log.debug("激活已被取代：pid \(pid)")
            } else {
                log.error("激活失败：pid \(pid) 未到前台")
            }
            return .failed(.notFrontmostAfterTimeout)
        }
        // 没有启用 AX（探针单测某种手段时）不算 AX 失败。
        guard axAttempted else { return .activated }
        if let error = axError ?? nil { return .activatedAppOnly(error) }
        return .activated
    }

    /// 记一步。token 不是最新的激活时不记，旧激活的异步步骤不会混进新激活的记录。
    private func record(_ step: String, _ detail: String, token: Int? = nil) {
        if let token, token != latestToken { return }
        let elapsed = ContinuousClock.now - startedAt
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        lastTrace.append(ActivationTraceEntry(step: step, elapsedMilliseconds: ms, detail: detail))
    }

    /// 把 AX 提升的子步骤结果写成一行说明。
    private static func describe(_ report: AXRaiseReport) -> String {
        let minimized = report.wasMinimized.map { $0 ? "是" : "否" } ?? "未知"
        let unminimize = report.unminimize.map { "\($0.rawValue)" } ?? "-"
        return "原本最小化：\(minimized)，还原 \(unminimize)，raise \(report.raise.rawValue)，"
            + "main \(report.setMain.rawValue)，frontmost \(report.setFrontmost.rawValue)"
    }
}
