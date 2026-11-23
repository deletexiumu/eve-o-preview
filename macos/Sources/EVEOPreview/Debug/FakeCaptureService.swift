// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的假捕获服务。按 reconcile 给出的规格为每个窗口生成动画画面，
// 画面写进 IOSurface，与真实捕获服务交给 App 的帧格式相同（BGRA、像素尺寸、contentRect）。
//
// 每帧画面的顶部画一条红色横条，高度对应源窗口 28 点的标题栏。
// 缩略图的标题栏裁剪与 y 轴换算都正确时，这条红条不出现在缩略图里，可用截图核对。

import AppKit
import CoreVideo
import IOSurface
import EVEOPreviewCore
import EVEOPreviewPlatform
import os

/// 假的捕获服务。
@MainActor
final class FakeCaptureService: CaptureService {
    /// 新画面的回调（协调器转给面板）。
    var onFrame: (@MainActor (WindowID, CapturedFrame) -> Void)?
    /// 捕获状态变化的回调（协调器据此决定占位）。
    var onStateChange: (@MainActor (WindowID, CaptureState) -> Void)?

    /// 一个窗口的假捕获会话。
    private struct Session {
        /// 当前规格；变化时丢掉旧 surface，按新尺寸重建。
        var spec: CaptureSpec
        /// 上报过的状态：starting 直到第一帧，之后 running。
        var state: CaptureState
        /// 轮流使用的 surface。同一个 surface 重复赋给图层不会重绘，所以准备 3 个轮换。
        var surfaces: [IOSurface] = []
        /// 已出的帧数，画在画面上，也用来轮换 surface。
        var frameIndex = 0
        /// 下一帧的时刻（单调时钟秒数），按规格的帧率推算。
        var nextFrameAt: TimeInterval = 0
    }

    /// 假世界，提供客户端标题、色相与窗口尺寸。
    private let world: FakeWorld
    /// 模拟「用户停止捕获」的时刻（启动后的秒数）；nil 表示不模拟。
    private let stopSecondClientAfter: TimeInterval?
    /// 正在出帧的会话。
    private var sessions: [WindowID: Session] = [:]
    /// 被「用户停止」的窗口，`resume` 前不再出帧。
    private var stoppedWindows: Set<WindowID> = []
    /// 出帧循环；没有会话时退出，下次 reconcile 有会话时再启动。
    private var ticker: Task<Void, Never>?
    private let log = AppLog.logger("Fake")

    /// 用假世界建服务；stopSecondClientAfter 取自环境变量 `EVEO_FAKE_STOP_AFTER`。
    init(world: FakeWorld, stopSecondClientAfter: TimeInterval?) {
        self.world = world
        self.stopSecondClientAfter = stopSecondClientAfter
    }

    /// 对账：新窗口建会话，规格变了重建 surface，不再需要的会话停掉。被用户停止的窗口在恢复前不建会话。
    func reconcile(_ desired: [WindowID: CaptureSpec], liveWindows: Set<WindowID>) {
        for (id, spec) in desired {
            if var session = sessions[id] {
                if session.spec != spec {
                    session.spec = spec
                    session.surfaces = []
                    sessions[id] = session
                }
            } else if !stoppedWindows.contains(id) {
                sessions[id] = Session(spec: spec, state: .starting)
                onStateChange?(id, .starting)
            }
        }
        // 真实服务在隐藏 3 秒后才停流；演示模式直接停，状态回到 idle，最后一帧留在图层上。
        for id in sessions.keys where desired[id] == nil {
            sessions[id] = nil
            onStateChange?(id, liveWindows.contains(id) ? .idle : .windowGone)
        }
        stoppedWindows.formIntersection(liveWindows)
        startTickerIfNeeded()
    }

    /// 恢复：清掉「用户已停止」，状态回到 idle；下一次重算的 reconcile 会重新建会话。
    func resume(_ window: WindowID) {
        guard stoppedWindows.remove(window) != nil else { return }
        log.info("演示模式恢复捕获")
        onStateChange?(window, .idle)
    }

    /// 唤醒后重建：演示模式的会话不会失效，只记日志。
    func restartActiveSessions() {
        log.info("演示模式收到唤醒，会话保持不变")
    }

    /// 停止出帧并丢掉全部会话。
    func stopAll() async {
        ticker?.cancel()
        ticker = nil
        sessions.removeAll()
    }

    /// 有会话时启动出帧循环，约每 33 毫秒检查一次哪些会话到了出帧时刻。
    private func startTickerIfNeeded() {
        guard ticker == nil, !sessions.isEmpty else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !self.sessions.isEmpty else { break }
                self.tick()
            }
            self?.ticker = nil
        }
    }

    /// 给到时的会话各出一帧。
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = Date().timeIntervalSince(world.startedAt)
        // 遍历键的副本：循环里会增删会话。
        for id in Array(sessions.keys) {
            guard var session = sessions[id], now >= session.nextFrameAt else { continue }
            if shouldSimulateUserStop(id, elapsed: elapsed) {
                sessions[id] = nil
                stoppedWindows.insert(id)
                onStateChange?(id, .stoppedByUser)
                continue
            }
            // 演示模式最多 30 帧每秒：文字绘制走 CPU，更高的帧率只会多耗电。
            session.nextFrameAt = now + 1.0 / Double(max(1, min(session.spec.framesPerSecond, 30)))
            guard let frame = render(&session, id: id, elapsed: elapsed) else { continue }
            if session.state != .running {
                session.state = .running
                onStateChange?(id, .running)
            }
            sessions[id] = session
            onFrame?(id, frame)
        }
    }

    /// `EVEO_FAKE_STOP_AFTER` 到时，把第二个客户端当作被用户在录制指示器里停止。
    private func shouldSimulateUserStop(_ id: WindowID, elapsed: TimeInterval) -> Bool {
        guard let limit = stopSecondClientAfter, elapsed >= limit else { return false }
        let clients = world.snapshot()
        return clients.count > 1 && clients[1].windowID == id && !stoppedWindows.contains(id)
    }

    /// 画一帧：按需建 surface，轮换使用，画完包成 `CapturedFrame`。
    private func render(_ session: inout Session, id: WindowID, elapsed: TimeInterval) -> CapturedFrame? {
        guard let client = world.client(withWindowID: id) else { return nil }
        let width = max(2, session.spec.pixelWidth)
        let height = max(2, session.spec.pixelHeight)
        if session.surfaces.isEmpty {
            session.surfaces = (0..<3).compactMap { _ in FakeFrameRenderer.makeSurface(width: width, height: height) }
        }
        guard !session.surfaces.isEmpty else { return nil }
        let surface = session.surfaces[session.frameIndex % session.surfaces.count]
        session.frameIndex += 1
        FakeFrameRenderer.draw(into: surface, client: client, elapsed: elapsed, frameIndex: session.frameIndex)
        return CapturedFrame(surface: surface, contentRect: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// 假画面的绘制。只在主线程调用（文字绘制经过 NSGraphicsContext）。
@MainActor
enum FakeFrameRenderer {
    /// 建一个 BGRA 的 IOSurface。
    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        // 与 ScreenCaptureKit 的输出一致：32 位 BGRA，每像素 4 字节。
        IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ])
    }

    /// 在 surface 上画一帧：渐变底色、移动的竖条、顶部红色标题栏、居中的标题与计时。
    static func draw(into surface: IOSurface, client: FakeClientState, elapsed: TimeInterval, frameIndex: Int) {
        // 写像素前锁住 surface，防止图层同时读到半帧。
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let width = surface.width
        let height = surface.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let w = CGFloat(width)
        let h = CGFloat(height)
        // 底色：按客户端的色相，亮度随时间缓慢起伏。
        let pulse = 0.35 + 0.1 * sin(elapsed * 1.3)
        ctx.setFillColor(NSColor(hue: client.hue, saturation: 0.6, brightness: pulse, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 移动的竖条，确认画面在持续更新。
        let barX = CGFloat((elapsed * 0.25).truncatingRemainder(dividingBy: 1)) * w
        ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
        ctx.fill(CGRect(x: barX, y: 0, width: w * 0.06, height: h))
        // 顶部的「标题栏」：CGContext 的原点在左下角，所以画在 y = h - 栏高。
        let barHeight = h * CGFloat(28.0 / client.frame.height)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 0, y: h - barHeight, width: w, height: barHeight))
        drawLabels(in: ctx, size: CGSize(width: w, height: h), client: client, elapsed: elapsed, frameIndex: frameIndex)
    }

    /// 画居中的标题与计时文字。
    private static func drawLabels(in ctx: CGContext, size: CGSize, client: FakeClientState,
                                   elapsed: TimeInterval, frameIndex: Int) {
        // NSAttributedString 的绘制依赖当前的 NSGraphicsContext，借用 surface 的 CGContext 建一个。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let titleFont = NSFont.boldSystemFont(ofSize: max(12, size.height * 0.12))
        let infoFont = NSFont.monospacedDigitSystemFont(ofSize: max(10, size.height * 0.06), weight: .regular)
        let title = NSAttributedString(string: client.title, attributes: [
            .font: titleFont, .foregroundColor: NSColor.white,
        ])
        let state = client.isMinimized ? " (min)" : ""
        let info = NSAttributedString(string: String(format: "t=%.1fs  #%d%@", elapsed, frameIndex, state), attributes: [
            .font: infoFont, .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ])
        // 标题在中线上方，计时在下方；字号随画面高度缩放。
        let titleSize = title.size()
        title.draw(at: CGPoint(x: (size.width - titleSize.width) / 2, y: size.height * 0.5))
        let infoSize = info.size()
        info.draw(at: CGPoint(x: (size.width - infoSize.width) / 2, y: size.height * 0.5 - infoSize.height - 6))
    }
}
