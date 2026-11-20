// SPDX-License-Identifier: GPL-3.0-or-later
//
// 窗口枚举（架构文档 6.2 节）。用 CGWindowList 找出 EVE 客户端进程的全部 layer 0 窗口，
// 再用 AX 补全标题与最小化状态。actor 隔离，查询不占主线程。
// PID 一律取自 kCGWindowOwnerPID：NSRunningApplication.processIdentifier 对 EVE 进程返回 -1（事实 E5）。

import AppKit
import EVEOPreviewCore
import os

/// 基于 `CGWindowListCopyWindowInfo` 与 AX 的窗口枚举。
public actor CGWindowProvider: WindowProvider {
    /// EVE 客户端的 bundle id（事实 E4）。启动器的 bundle id 不同，自然被排除。
    public static let eveBundleIdentifier = "com.ccpgames.eveonline"

    /// 要枚举的应用的 bundle id。
    private let bundleIdentifier: String
    /// 读标题与最小化状态的 AX 执行者。
    private let ax: AXWorker
    /// 已确认属于目标 bundle id 的 PID。PID 从窗口列表消失时清除，防止 PID 复用后判断错误。
    private var targetPIDs: Set<Int32> = []
    /// 已确认不属于目标的 PID → 确认的时刻。否定结果过期后重新判断：
    /// 进程刚启动时 NSRunningApplication 可能还没登记，如果永久记住否定结果，这个客户端就再也认不出来。
    private var nonTargetCheckedAt: [Int32: ContinuousClock.Instant] = [:]
    /// 否定结果的有效期。
    static let nonTargetCacheLifetime: Duration = .seconds(30)
    /// PID → 上一轮 AX 读到的窗口状态。AX 超时或失败时沿用。
    private var lastAXStates: [Int32: [AXWindowState]] = [:]
    /// 日志。
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "CGWindowProvider")

    /// 建一个窗口枚举器。
    ///
    /// - Parameters:
    ///   - ax: 共用的 AX 执行者。
    ///   - bundleIdentifier: 要枚举的应用，默认是 EVE 客户端。
    public init(ax: AXWorker, bundleIdentifier: String = CGWindowProvider.eveBundleIdentifier) {
        self.ax = ax
        self.bundleIdentifier = bundleIdentifier
    }

    /// 返回 EVE 客户端进程的全部 layer 0 窗口，有辅助功能权限时已用 AX 补全标题与最小化状态。
    /// 出错时返回空数组并记日志，不抛错。
    public func candidateWindows() async -> [WindowInfo] {
        var windows = cgWindows()
        if AXWorker.isTrusted {
            for pid in Set(windows.map(\.pid)).sorted() {
                await applyAXState(pid: pid, to: &windows)
            }
        }
        return windows
    }

    // MARK: - CGWindowList

    /// 第 1～3 步：枚举、按 layer 与 bundle id 过滤、填字段。
    private func cgWindows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            log.error("CGWindowListCopyWindowInfo 返回空")
            return []
        }
        var seenPIDs = Set<Int32>()
        var result: [WindowInfo] = []
        for entry in raw {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            seenPIDs.insert(pid)
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  isTargetProcess(pid), let window = windowInfo(from: entry, pid: pid) else { continue }
            result.append(window)
        }
        // 进程退出后清掉它的缓存；PID 以后被别的进程复用时会重新判断。
        targetPIDs.formIntersection(seenPIDs)
        nonTargetCheckedAt = nonTargetCheckedAt.filter { seenPIDs.contains($0.key) }
        lastAXStates = lastAXStates.filter { seenPIDs.contains($0.key) }
        return result
    }

    /// 判断 PID 是否属于目标 bundle id。
    ///
    /// 肯定结果一直缓存到 PID 消失；明确的否定结果（取到了别的 bundle id）缓存 30 秒；
    /// 取不到进程或 bundle id 时不缓存，下一轮再判断。
    private func isTargetProcess(_ pid: Int32) -> Bool {
        if targetPIDs.contains(pid) { return true }
        let now = ContinuousClock.now
        if let checkedAt = nonTargetCheckedAt[pid], now - checkedAt < Self.nonTargetCacheLifetime { return false }
        // NSRunningApplication(processIdentifier:) 对 EVE 的真实 PID 能取到对象（事实 E5）。
        guard let found = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            nonTargetCheckedAt[pid] = nil
            return false
        }
        if found == bundleIdentifier {
            targetPIDs.insert(pid)
            nonTargetCheckedAt[pid] = nil
            return true
        }
        nonTargetCheckedAt[pid] = now
        return false
    }

    /// 把一条 CGWindowList 记录换成 `WindowInfo`。缺窗口 ID 或范围时返回 nil。
    private func windowInfo(from entry: [String: Any], pid: Int32) -> WindowInfo? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        let name = entry[kCGWindowName as String] as? String
        return WindowInfo(windowID: WindowID(rawValue: number), pid: pid,
                          title: (name?.isEmpty ?? true) ? nil : name,
                          frame: CoordinateConversion.screenRect(bounds),
                          isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                          isMinimized: nil)
    }

    // MARK: - AX 补全

    /// 第 4 步：把该 PID 的 AX 窗口状态写到对应的 CG 窗口上。
    ///
    /// 标题相同的窗口优先；没有时写到该 PID 面积最大的窗口（补上标题）。
    /// AX 失败时沿用上一轮的值；上一轮也没有时，`isMinimized` 保持 nil。
    private func applyAXState(pid: Int32, to windows: inout [WindowInfo]) async {
        let states: [AXWindowState]
        if let fresh = await ax.windowStates(pid: pid) {
            states = fresh
            lastAXStates[pid] = fresh
        } else if let previous = lastAXStates[pid] {
            states = previous
        } else {
            return
        }
        for state in states {
            guard let index = targetIndex(for: state, pid: pid, in: windows) else { continue }
            if windows[index].title == nil { windows[index].title = state.title }
            windows[index].isMinimized = state.isMinimized
        }
    }

    /// AX 窗口对应的 CG 窗口下标：先按标题匹配，再取面积最大者。
    private func targetIndex(for state: AXWindowState, pid: Int32, in windows: [WindowInfo]) -> Int? {
        if let title = state.title,
           let index = windows.firstIndex(where: { $0.pid == pid && $0.title == title }) {
            return index
        }
        let indices = windows.indices.filter { windows[$0].pid == pid }
        return indices.max { windows[$0].frame.area < windows[$1].frame.area }
    }
}
