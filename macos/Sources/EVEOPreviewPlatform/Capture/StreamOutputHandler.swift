// SPDX-License-Identifier: GPL-3.0-or-later
//
// 单条流的帧回调（架构文档 6.3 节「帧的处理」）。在流自己的串行队列上运行：
// 读帧状态、取 IOSurface、放进「最新一帧」槽位；槽位原本为空时通知主线程来取。
// 主线程忙时，中间的帧被后来的帧覆盖，只交付最新一帧。

@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import os

/// 一条流的回调统计，供探针打印与看门狗判断。
public struct CaptureStatistics: Sendable, Equatable {
    /// 带画面的帧（`SCFrameStatus.complete`）。
    public var complete = 0
    /// 画面没变化的回调（`.idle`）。
    public var idle = 0
    /// 空白帧（`.blank`）。
    public var blank = 0
    /// 窗口暂停输出（`.suspended`，例如最小化）。
    public var suspended = 0
    /// 流开始（`.started`）。
    public var started = 0
    /// 流停止（`.stopped`）。
    public var stopped = 0
    /// 读不到状态或其他状态。
    public var other = 0
    /// 最近一次任何回调的时刻；还没有回调时为 nil。
    public var lastCallbackAt: ContinuousClock.Instant?
    /// 相邻两次回调（任何状态）之间最长的间隔，用来判断看门狗的阈值是否会误触发（V5）。
    public var longestCallbackGap: Duration = .zero
    /// 最近一帧的 `SCStreamFrameInfo.contentRect` 原始值（单位见 `CapturedFrame.contentRect` 的换算）。
    public var lastRawContentRect: CGRect?
    /// 最近一帧的 `contentScale`（源内容缩放到输出画面的比例）。
    public var lastContentScale: Double?
    /// 最近一帧的 `scaleFactor`（源所在屏幕的点到像素比例）。
    public var lastScaleFactor: Double?

    /// 建一个全零的统计。
    public init() {}

    /// 全部回调的次数。
    public var total: Int { complete + idle + blank + suspended + started + stopped + other }
}

/// `SCStream` 的输出与代理。每条流一个实例，在 `queue` 上接收帧。
final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 槽位与统计，由锁保护；帧在流的队列上写入，在主线程取走。
    private struct Shared {
        var latest: CapturedFrame?
        var statistics = CaptureStatistics()
    }

    /// 这条流的样本队列（串行）。
    let queue: DispatchQueue
    /// 槽位从空变为有帧时调用（在流的队列上），由会话负责切到主线程。
    private let onFrameAvailable: @Sendable () -> Void
    /// 流因错误停止时调用（在系统的任意队列上）。
    private let onStop: @Sendable (any Error) -> Void
    /// 受锁保护的共享状态。
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// 建一个处理器。
    ///
    /// - Parameters:
    ///   - label: 队列名，便于在调试器里辨认。
    ///   - onFrameAvailable: 槽位从空变为有帧时调用。
    ///   - onStop: 流因错误停止时调用。
    init(label: String, onFrameAvailable: @escaping @Sendable () -> Void,
         onStop: @escaping @Sendable (any Error) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        self.onFrameAvailable = onFrameAvailable
        self.onStop = onStop
    }

    /// 取走槽位里的帧（主线程调用）。槽位为空时返回 nil。
    func takeLatest() -> CapturedFrame? {
        shared.withLock { state in
            defer { state.latest = nil }
            return state.latest
        }
    }

    /// 当前统计的副本。
    func statistics() -> CaptureStatistics {
        shared.withLock { $0.statistics }
    }

    // MARK: - SCStreamOutput

    /// 收到一个样本。只有 `.complete` 的帧带画面；其他状态只更新统计与最近回调时刻。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let info = Self.frameInfo(sampleBuffer)
        let frame = Self.capturedFrame(sampleBuffer, info: info)
        let shouldNotify = shared.withLock { state -> Bool in
            let now = ContinuousClock.now
            state.statistics.count(info.status)
            if let last = state.statistics.lastCallbackAt {
                state.statistics.longestCallbackGap = max(state.statistics.longestCallbackGap, now - last)
            }
            state.statistics.lastCallbackAt = now
            state.statistics.lastRawContentRect = info.contentRect ?? state.statistics.lastRawContentRect
            state.statistics.lastContentScale = info.contentScale ?? state.statistics.lastContentScale
            state.statistics.lastScaleFactor = info.scaleFactor ?? state.statistics.lastScaleFactor
            guard let frame else { return false }
            let wasEmpty = state.latest == nil
            state.latest = frame
            return wasEmpty
        }
        if shouldNotify { onFrameAvailable() }
    }

    /// 只有 `.complete` 的帧带画面：取出 IOSurface 与像素范围；其他状态返回 nil。
    private static func capturedFrame(_ sampleBuffer: CMSampleBuffer, info: FrameInfo) -> CapturedFrame? {
        guard info.status == .complete, let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        // IOSurfaceRef 与 IOSurface 是免费桥接的同一对象。
        return CapturedFrame(surface: unsafeBitCast(surface, to: IOSurface.self),
                             contentRect: pixelRect(info: info, surface: surface))
    }

    // MARK: - SCStreamDelegate

    /// 流因错误停止（包括用户在录制指示器里点了停止）。
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
    }

    // MARK: - 帧信息

    /// 从样本附件里读出的帧信息。
    private struct FrameInfo {
        var status: SCFrameStatus?
        var contentRect: CGRect?
        var contentScale: Double?
        var scaleFactor: Double?
    }

    /// 读 `SCStreamFrameInfo` 附件。
    private static func frameInfo(_ sampleBuffer: CMSampleBuffer) -> FrameInfo {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let attachments = array.first else { return FrameInfo() }
        var info = FrameInfo()
        if let raw = attachments[.status] as? Int { info.status = SCFrameStatus(rawValue: raw) }
        if let dict = attachments[.contentRect] as? NSDictionary {
            info.contentRect = CGRect(dictionaryRepresentation: dict as CFDictionary)
        }
        info.contentScale = (attachments[.contentScale] as? NSNumber)?.doubleValue
        info.scaleFactor = (attachments[.scaleFactor] as? NSNumber)?.doubleValue
        return info
    }

    /// 画面在 surface 里的位置，单位是像素。
    ///
    /// `contentRect` 的单位是输出画面的点，乘以 `scaleFactor` 即得输出画面的像素。
    /// 2026-11-20 实测：源窗口 1728×1019 点、输出 768×454 像素时，contentRect 是 384×226.4，
    /// scaleFactor 2.0，contentScale 0.222；384×2 = 768 与 surface 宽度一致。
    /// contentScale 是源到输出的缩放比例，这里用不到。缺附件时取整个 surface。
    private static func pixelRect(info: FrameInfo, surface: IOSurfaceRef) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
        guard let rect = info.contentRect, let factor = info.scaleFactor, factor > 0 else { return full }
        let pixels = CGRect(x: rect.origin.x * factor, y: rect.origin.y * factor,
                            width: rect.width * factor, height: rect.height * factor)
        // 浮点误差可能让结果略超出 surface，夹回 surface 内。
        let clamped = pixels.intersection(full)
        return clamped.isNull ? full : clamped
    }
}

extension CaptureStatistics {
    /// 按帧状态计数一次。
    mutating func count(_ status: SCFrameStatus?) {
        switch status {
        case .complete: complete += 1
        case .idle: idle += 1
        case .blank: blank += 1
        case .suspended: suspended += 1
        case .started: started += 1
        case .stopped: stopped += 1
        default: other += 1
        }
    }
}
