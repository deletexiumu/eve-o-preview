// SPDX-License-Identifier: GPL-3.0-or-later
//
// 辅助功能（AX）读写的 actor（架构文档 3.2 节、6.2 节、6.4 节）。
// AX 调用是同步的进程间调用，客户端卡住时会阻塞调用方，所以不放在主线程。
// 第一次建 AXWorker 时对系统级元素设 0.25 秒的消息超时，对全部 AX 元素生效（风险 R5）；
// 应用元素另外再设一次，作为保险。
// 实测每个 EVE 进程在 AX 里只有 1 个 AXStandardWindow（事实 E7），所以按 PID 取窗口，
// 不依赖私有接口 _AXUIElementGetWindow。

import ApplicationServices
import Foundation
import EVEOPreviewCore
import os

/// AX 读到的一个窗口的状态。
public struct AXWindowState: Sendable, Equatable {
    /// `kAXTitleAttribute`；读不到或为空串时为 nil。
    public var title: String?
    /// `kAXMinimizedAttribute`；读不到时为 nil。
    public var isMinimized: Bool?

    /// 用标题与最小化状态建一个值。
    public init(title: String?, isMinimized: Bool?) {
        self.title = title
        self.isMinimized = isMinimized
    }
}

/// 提升窗口（激活第 4 步）各子步骤的结果，供激活器判断与探针打印。
public struct AXRaiseReport: Sendable, Equatable {
    /// 窗口原本是否已最小化；读不到时为 nil。
    public var wasMinimized: Bool?
    /// 取消最小化的结果；窗口没有最小化时为 nil。
    public var unminimize: AXError?
    /// `kAXRaiseAction` 的结果。
    public var raise: AXError
    /// 设置窗口 `kAXMainAttribute` 的结果。
    public var setMain: AXError
    /// 设置应用 `kAXFrontmostAttribute` 的结果。
    public var setFrontmost: AXError

    /// 窗口已还原（或本来没最小化）并且 `AXRaise` 成功时为真。
    /// `kAXMainAttribute` 与 `kAXFrontmostAttribute` 的失败不计入：前台由激活器另行核对。
    public var succeeded: Bool {
        (unminimize ?? .success) == .success && raise == .success
    }

    /// 第一个失败的子步骤的错误码；全部成功时为 nil。
    public var firstFailure: AXError? {
        [unminimize ?? .success, raise, setMain, setFrontmost].first { $0 != .success }
    }
}

/// 一次 AX 提升（激活第 4 步）的结果。
public enum AXRaiseResult: Sendable, Equatable {
    /// 各子步骤都已执行，关联值是每一步的结果。
    case completed(AXRaiseReport)
    /// 没有权限或找不到窗口。
    case failed(ActivationError)
    /// 执行前或执行中发现已有更新的激活请求，剩下的写操作没有执行。
    case superseded
}

/// AX 读写的执行者。全部方法在本 actor 上串行执行，不占主线程。
public actor AXWorker {
    /// AX 消息超时，单位是秒。客户端卡顿时 AX 调用最多阻塞这么久。
    public static let messagingTimeout: Float = 0.25

    /// 对系统级元素设消息超时的结果。静态常量只初始化一次，所以整个进程只设一次（架构文档 3.2 节）。
    private static let systemWideTimeoutStatus: AXError =
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)

    /// 提升请求的序号。激活器每发起一次激活就领一个新序号（`beginRaiseRequest()`）。
    /// 按住循环热键时，旧激活的提升会在本 actor 上排队；它们在每次写操作前核对序号，
    /// 发现自己已不是最新的请求就停下，不再还原或提升旧目标。用锁保护，任何线程都能读写。
    private nonisolated let latestRaiseRequest = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// 日志，角色名按 `.private` 记录。
    private let log = PlatformLog.logger("AXWorker")

    /// 建一个 AX 执行者。第一次调用时设置系统级的消息超时。
    public init() {
        let status = AXWorker.systemWideTimeoutStatus
        if status != .success {
            log.error("设置系统级 AX 消息超时失败：错误码 \(status.rawValue)")
        }
    }

    /// 当前进程是否有辅助功能权限。
    public nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - 读

    /// 读该进程全部 AX 窗口的标题与最小化状态。没有权限或 AX 失败时返回 nil。
    public func windowStates(pid: Int32) -> [AXWindowState]? {
        guard AXWorker.isTrusted, let windows = windows(of: pid) else { return nil }
        return windows.map(windowState)
    }

    /// 读应用元素的 `kAXFrontmostAttribute`。没有权限或读不到时返回 nil。
    public func isFrontmost(pid: Int32) -> Bool? {
        guard AXWorker.isTrusted else { return nil }
        return boolAttribute(applicationElement(pid), kAXFrontmostAttribute)
    }

    // MARK: - 写

    /// 领一个新的提升序号，之前领到的序号全部作废。激活器在每次激活开始时调用，不必等 actor。
    public nonisolated func beginRaiseRequest() -> UInt64 {
        latestRaiseRequest.withLock { value in
            value += 1
            return value
        }
    }

    /// 序号是否仍是最新的请求。nil 表示调用方不参与取消，总是返回真。
    private nonisolated func isLatest(_ request: UInt64?) -> Bool {
        guard let request else { return true }
        return latestRaiseRequest.withLock { $0 == request }
    }

    /// 激活第 4 步：还原、`AXRaise`、设为主窗口、把应用设为前台。
    ///
    /// - Parameters:
    ///   - pid: 目标进程。
    ///   - title: 目标窗口标题，进程有多个 AX 窗口时用来匹配；nil 时不按标题匹配。
    ///   - request: `beginRaiseRequest()` 领到的序号。开始前和每次写操作前核对，
    ///     已不是最新的请求时返回 `.superseded`；nil 时不核对。
    /// - Returns: 各子步骤的结果；没有权限或找不到窗口时返回对应的错误。
    public func raise(pid: Int32, title: String?, request: UInt64? = nil) -> AXRaiseResult {
        guard AXWorker.isTrusted else { return .failed(.accessibilityDenied) }
        guard isLatest(request) else { return .superseded }
        let app = applicationElement(pid)
        guard let window = window(of: pid, app: app, title: title) else { return .failed(.windowNotFound) }
        let wasMinimized = boolAttribute(window, kAXMinimizedAttribute)
        var unminimize: AXError?
        if wasMinimized == true {
            guard isLatest(request) else { return .superseded }
            unminimize = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // 每次写操作都是一条进程间消息（实测每条 15～20 毫秒），所以每一步前都核对一次。
        guard isLatest(request) else { return .superseded }
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard isLatest(request) else { return .superseded }
        let setMain = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard isLatest(request) else { return .superseded }
        let setFrontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let report = AXRaiseReport(wasMinimized: wasMinimized, unminimize: unminimize, raise: raise,
                                   setMain: setMain, setFrontmost: setFrontmost)
        if let failure = report.firstFailure {
            log.debug("AX 提升部分失败：pid \(pid) 错误码 \(failure.rawValue)")
        }
        return .completed(report)
    }

    /// 最小化目标窗口（`kAXMinimizedAttribute` 设为真）。
    public func minimize(pid: Int32, title: String?) -> Result<Void, ActivationError> {
        guard AXWorker.isTrusted else { return .failure(.accessibilityDenied) }
        guard let window = window(of: pid, app: applicationElement(pid), title: title) else {
            return .failure(.windowNotFound)
        }
        let status = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        return status == .success ? .success(()) : .failure(.axFailure(code: status.rawValue))
    }

    // MARK: - 私有

    /// 建应用元素并设消息超时。元素很轻，每次新建，不缓存（进程退出后旧元素也会失效）。
    private func applicationElement(_ pid: Int32) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXWorker.messagingTimeout)
        return app
    }

    /// 该进程的全部 AX 窗口；读不到时返回 nil。
    private func windows(of pid: Int32, app: AXUIElement? = nil) -> [AXUIElement]? {
        let element = app ?? applicationElement(pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let list = value as? [AXUIElement] else {
            log.debug("读 AX 窗口列表失败：pid \(pid) 错误码 \(status.rawValue)")
            return nil
        }
        return list
    }

    /// 按 4.1 节选目标窗口：先按标题匹配，再取第一个 `AXStandardWindow`，最后取第一个窗口。
    private func window(of pid: Int32, app: AXUIElement, title: String?) -> AXUIElement? {
        guard let list = windows(of: pid, app: app), !list.isEmpty else { return nil }
        if let title, let match = list.first(where: { stringAttribute($0, kAXTitleAttribute) == title }) {
            return match
        }
        let standard = list.first { stringAttribute($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        return standard ?? list.first
    }

    /// 一次消息读出窗口的标题与最小化状态。
    ///
    /// 实测 EVE 每条 AX 消息要 15～20 毫秒（大约一帧），一个进程读一轮要 40～70 毫秒，
    /// 所以用 `AXUIElementCopyMultipleAttributeValues` 把两个属性合进一条消息。
    private func windowState(_ window: AXUIElement) -> AXWindowState {
        let names = [kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, names, AXCopyMultipleAttributeOptions(), &values) == .success,
              let list = values as? [Any], list.count == 2 else {
            return AXWindowState(title: nil, isMinimized: nil)
        }
        // 某个属性读不到时，对应位置是一个 AXValue 错误值而不是字符串或数字，按读不到处理。
        let title = list[0] as? String
        return AXWindowState(title: (title?.isEmpty ?? true) ? nil : title,
                             isMinimized: (list[1] as? NSNumber)?.boolValue)
    }

    /// 读字符串属性；类型不符或失败时返回 nil。
    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 读布尔属性；类型不符或失败时返回 nil。
    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
