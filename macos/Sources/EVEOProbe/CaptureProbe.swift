// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 capture 命令：起一条流，每秒打印帧数与各状态的计数，结束时把最后一帧存成 PNG。
// 用来核对 V4（最小化时的流行为）、V5（静止画面的回调节奏）、V6（标题栏高度）。

import AppKit
import CoreImage
import EVEOPreviewCore
import EVEOPreviewPlatform
import ImageIO
import UniformTypeIdentifiers

/// capture 命令的实现。
@MainActor enum CaptureProbe {
    /// 执行 capture 命令。
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2, let rawID = UInt32(args[0]), let seconds = Int(args[1]), seconds > 0,
              let outPath = option("--out", in: args) else {
            return Probe.usage()
        }
        let id = WindowID(rawValue: rawID)
        let candidates = await Probe.windows.candidateWindows()
        guard let window = candidates.first(where: { $0.windowID == id }) else {
            print("找不到窗口 \(rawID)")
            return 1
        }
        let scale = Double(NSScreen.screens.first?.backingScaleFactor ?? 2)
        let spec = makeSpec(window: window, scale: scale, args: args)
        print("窗口 \(rawID) \(Probe.describe(window.frame))，规格 \(spec.pixelWidth)×\(spec.pixelHeight) @\(spec.framesPerSecond)")
        // 探针默认关掉看门狗：V5 要测的正是静止画面下回调的间隔，看门狗重建会打乱统计。
        // 带 --watchdog 时打开，用来核对最小化与还原期间看门狗不误判。
        let service = SCKCaptureService(watchdogEnabled: args.contains("--watchdog"))
        var lastFrame: CapturedFrame?
        var frameCount = 0
        service.onFrame = { _, frame in
            lastFrame = frame
            frameCount += 1
        }
        service.onStateChange = { _, state in
            print("  状态 → \(state)")
        }
        service.reconcile([id: spec], liveWindows: [id])
        var previous = CaptureStatistics()
        for second in 1...seconds {
            try? await Task.sleep(for: .seconds(1))
            let stats = service.statistics(for: id) ?? CaptureStatistics()
            print("第 \(second) 秒：交付 \(frameCount) 帧；回调 complete +\(stats.complete - previous.complete) "
                  + "idle +\(stats.idle - previous.idle) blank +\(stats.blank - previous.blank) "
                  + "suspended +\(stats.suspended - previous.suspended) started +\(stats.started - previous.started) "
                  + "stopped +\(stats.stopped - previous.stopped) other +\(stats.other - previous.other)"
                  + "；状态 \(service.state(for: id).map { "\($0)" } ?? "无会话")")
            previous = stats
            frameCount = 0
        }
        printFrameInfo(service.statistics(for: id), frame: lastFrame)
        await service.stopAll()
        if let lastFrame {
            save(lastFrame, to: URL(fileURLWithPath: outPath))
        } else {
            print("没有收到任何带画面的帧")
        }
        return 0
    }

    /// 按脚本走一遍对账，打印状态序列：
    /// 建流 → 2 秒后改规格 → 移出 desired 等 4 秒（应停流为 idle）→ 加回（应 starting、running）
    /// → 从 liveWindows 移除（应 windowGone）。
    static func reconcileScript(_ args: [String]) async -> Int32 {
        guard let rawID = args.first.flatMap(UInt32.init) else { return Probe.usage() }
        let id = WindowID(rawValue: rawID)
        let service = SCKCaptureService()
        let started = ContinuousClock.now
        var frames = 0
        service.onFrame = { _, _ in frames += 1 }
        service.onStateChange = { _, state in
            print("  第 \(Probe.milliseconds(since: started)) 毫秒 状态 → \(state)")
        }
        let small = CaptureSpec(pixelWidth: 384, pixelHeight: 226, framesPerSecond: 10)
        let large = CaptureSpec(pixelWidth: 768, pixelHeight: 454, framesPerSecond: 15)
        let steps: [(String, [WindowID: CaptureSpec], Set<WindowID>, Double)] = [
            ("建流 384×226@10", [id: small], [id], 2),
            ("改规格 768×454@15", [id: large], [id], 2),
            ("移出 desired（隐藏）", [:], [id], 4),
            ("加回 desired", [id: large], [id], 2),
            ("从 liveWindows 移除", [:], [], 1),
        ]
        for (name, desired, live, wait) in steps {
            print("步骤：\(name)")
            frames = 0
            service.reconcile(desired, liveWindows: live)
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            print("  这一步交付 \(frames) 帧，状态 \(service.state(for: id).map { "\($0)" } ?? "无会话")")
        }
        await service.stopAll()
        return 0
    }

    /// 由参数生成规格：默认取源窗口的全分辨率（量标题栏高度要用原始像素）。
    static func makeSpec(window: WindowInfo, scale: Double, args: [String]) -> CaptureSpec {
        let width = option("--width", in: args).flatMap(Double.init) ?? window.frame.width * scale
        let fps = option("--fps", in: args).flatMap(Int.init) ?? 15
        let thumbnail = ScreenSize(width: width / scale, height: width / scale)
        return CaptureMath.spec(thumbnailSize: thumbnail, sourceSize: window.frame.size, scale: scale, frameRate: fps)
    }

    /// 打印最后一帧的附件信息，用来核对 contentRect 的单位。
    static func printFrameInfo(_ stats: CaptureStatistics?, frame: CapturedFrame?) {
        guard let stats else { return }
        print("附件：contentRect \(String(describing: stats.lastRawContentRect)) contentScale "
              + "\(String(describing: stats.lastContentScale)) scaleFactor \(String(describing: stats.lastScaleFactor))")
        print("相邻回调的最长间隔 \(stats.longestCallbackGap)")
        guard let frame else { return }
        print("surface \(IOSurfaceGetWidth(frame.surface))×\(IOSurfaceGetHeight(frame.surface))，"
              + "处理器换算并夹取后的 contentRect（像素）\(frame.contentRect)")
        // 不夹取的两种候选换算，用来核对 contentRect 的单位。
        if let rect = stats.lastRawContentRect, let scale = stats.lastScaleFactor, let content = stats.lastContentScale {
            print("候选 A rect×scaleFactor = \(rect.width * scale)×\(rect.height * scale)；"
                  + "候选 B rect×scaleFactor÷contentScale = \(rect.width * scale / content)×\(rect.height * scale / content)")
        }
    }

    /// 取 `--名称 值` 形式的参数值。
    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// 把一帧的整个 surface 存成 PNG。
    static func save(_ frame: CapturedFrame, to url: URL) {
        let image = CIImage(ioSurface: frame.surface)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("PNG 生成失败")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        print(CGImageDestinationFinalize(destination) ? "已保存 \(url.path)" : "PNG 写入失败")
    }
}
