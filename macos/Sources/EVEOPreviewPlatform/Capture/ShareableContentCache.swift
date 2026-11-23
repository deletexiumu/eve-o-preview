// SPDX-License-Identifier: GPL-3.0-or-later
//
// SCWindow 查找（架构文档 6.3 节第 1 步）。SCShareableContent 一次要约 108 毫秒（事实 E8），
// 所以不拿它轮询：只在缓存里没有某个窗口 ID 时才查询，并发的请求合并成一次，两次查询至少间隔 1 秒。

@preconcurrency import ScreenCaptureKit
import EVEOPreviewCore
import os

/// `SCWindow` 的缓存与合并查询。只在主线程使用。
@MainActor final class ShareableContentCache {
    /// 查找失败的原因。
    enum LookupError: Error, Equatable {
        /// 系统拒绝列出可共享内容（缺屏幕录制权限）。
        case permissionDenied
        /// 查询成功，但结果里没有这个窗口（窗口已关闭，或还没出现在列表里）。
        case notFound
        /// 查询本身失败，关联值是错误说明。
        case queryFailed(String)
    }

    /// 两次查询之间的最小间隔。
    static let minimumInterval: Duration = .seconds(1)

    /// 最近一次查询得到的窗口，按 `CGWindowID` 索引。
    private var windows: [UInt32: SCWindow] = [:]
    /// 进行中的查询；新的请求等它完成，不另发查询。
    private var inflight: Task<Void, Never>?
    /// 最近一次查询完成的时刻。
    private var lastFetchAt: ContinuousClock.Instant?
    /// 最近一次查询的错误；成功时为 nil。
    private var lastError: LookupError?
    /// 日志。
    private let log = PlatformLog.logger("ShareableContent")

    /// 取窗口 ID 对应的 `SCWindow`。缓存里没有时查询一次（与其他请求合并）。
    func window(for id: WindowID) async -> Result<SCWindow, LookupError> {
        if let cached = windows[id.rawValue] { return .success(cached) }
        await refresh()
        if let fresh = windows[id.rawValue] { return .success(fresh) }
        return .failure(lastError ?? .notFound)
    }

    /// 让某个窗口的缓存失效。流建立失败后调用，下次查找时重新查询，避免一直用已关闭窗口的旧对象。
    func invalidate(_ id: WindowID) {
        windows[id.rawValue] = nil
    }

    /// 查询一次可共享内容；已有查询进行中时等它完成。距上次查询不足 1 秒时先等够。
    private func refresh() async {
        if let inflight {
            await inflight.value
            return
        }
        let task = Task { @MainActor in
            if let last = lastFetchAt {
                let wait = last + Self.minimumInterval - ContinuousClock.now
                if wait > .zero { try? await Task.sleep(for: wait) }
            }
            await fetch()
            lastFetchAt = .now
            inflight = nil
        }
        inflight = task
        await task.value
    }

    /// 实际的查询。结果整体替换缓存，已关闭窗口的旧对象随之丢弃。
    private func fetch() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            lastError = nil
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == SCStreamErrorDomain, code == SCStreamError.Code.userDeclined.rawValue {
                lastError = .permissionDenied
            } else {
                lastError = .queryFailed(error.localizedDescription)
            }
            log.error("查询可共享内容失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
