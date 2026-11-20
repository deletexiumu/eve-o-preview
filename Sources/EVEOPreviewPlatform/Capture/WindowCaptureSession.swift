// SPDX-License-Identifier: GPL-3.0-or-later
//
// 单个窗口的捕获会话（架构文档 6.3 节）：建流、更新规格、宽限期停流、出错重试、看门狗。
// 会话只在主线程使用。异步步骤完成后用 generation 判断是否已过时（期间被停止或重建），过时的结果丢弃。
//
// 状态转换：
//   idle → starting：ensureRunning 或 restart 建流。
//   starting → running：第一帧 complete 到达（不是 startCapture 返回时）。
//   starting / running → retrying：建流失败、流因其他错误停止、更新配置失败、看门狗判定停滞；
//     按 RetryPolicy 等待后回到 starting。
//   任何状态 → permissionDenied：收到 userDeclined；之后由服务决定何时 restart。
//   任何状态 → stoppedByUser：收到 userStopped；只有 restart 能恢复。
//   starting / running / retrying → idle：隐藏后宽限期满，停流。
// 最小化不改变状态（V4）：流保持 running，只是不再出帧，还原后自动恢复出帧。

@preconcurrency import ScreenCaptureKit
import EVEOPreviewCore
import os

/// 一个窗口的捕获会话，持有至多一条 `SCStream`。
@MainActor final class WindowCaptureSession {
    /// 隐藏后停流前的宽限期。
    static let stopGracePeriod: Duration = .seconds(3)
    /// 规格变化后合并更新的等待时间。
    static let updateDebounce: Duration = .milliseconds(150)
    /// 连续运行这么久后，重试计数清零。
    static let retryResetAfter: Duration = .seconds(30)
    /// 看门狗：运行中超过这么久没有任何回调，且窗口在屏幕上时重建（V5）。
    static let watchdogTimeout: Duration = .seconds(5)

    /// 捕获的窗口。
    let windowID: WindowID
    /// 最近一次期望的规格；还没应用到流上的也算。
    private(set) var desiredSpec: CaptureSpec
    /// 当前状态。
    private(set) var state: CaptureState = .idle
    /// 收到新帧时调用。
    var onFrame: ((CapturedFrame) -> Void)?
    /// 状态变化时调用。
    var onStateChange: ((CaptureState) -> Void)?
    /// 是否启用看门狗。
    var watchdogEnabled: Bool

    /// SCWindow 的缓存，由服务共用。
    private let cache: ShareableContentCache
    /// 当前的流与处理器；没有流时都为 nil。
    private var stream: SCStream?
    private var handler: StreamOutputHandler?
    /// 每次建流或停流加 1，异步步骤据此丢弃过时的结果。
    fileprivate var generation = 0
    /// 已连续失败的次数，从 1 起计。
    private var attempt = 0
    /// 最近一次建流成功的时刻。
    private var runningSince: ContinuousClock.Instant?
    /// 待执行的重试、规格更新、宽限期停流、看门狗。
    private var retryTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    fileprivate var watchdogTask: Task<Void, Never>?
    /// 日志。
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "CaptureSession")

    /// 建一个会话，不立即建流。
    init(windowID: WindowID, spec: CaptureSpec, cache: ShareableContentCache, watchdogEnabled: Bool) {
        self.windowID = windowID
        desiredSpec = spec
        self.cache = cache
        self.watchdogEnabled = watchdogEnabled
    }

    /// 当前流的回调统计；没有流时返回 nil。
    var statistics: CaptureStatistics? { handler?.statistics() }

    // MARK: - 对账入口

    /// 窗口在期望里：更新规格，必要时（重新）建流。
    ///
    /// - Parameter permissionBlocked: 服务处于「权限被拒」状态时为真，此时不建流。
    func ensureRunning(spec: CaptureSpec, permissionBlocked: Bool) {
        cancelScheduledStop()
        if spec != desiredSpec {
            desiredSpec = spec
            if stream != nil { scheduleUpdate() }
        }
        switch state {
        case .idle, .permissionDenied, .windowGone:
            if permissionBlocked {
                setState(.permissionDenied)
            } else {
                start()
            }
        case .starting, .running, .retrying, .stoppedByUser:
            break
        }
    }

    /// 窗口不在期望里但仍存在：宽限期后停流，最后一帧留在图层上。已安排时不重复安排。
    func scheduleStop() {
        guard stopTask == nil, state != .idle, state != .stoppedByUser, state != .permissionDenied else { return }
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stopGracePeriod)
            guard !Task.isCancelled, let self else { return }
            self.stopTask = nil
            self.tearDown()
            self.setState(.idle)
        }
    }

    /// 取消宽限期停流。
    func cancelScheduledStop() {
        stopTask?.cancel()
        stopTask = nil
    }

    /// 用户选「恢复捕获」或权限恢复后调用：清零重试计数并重建。
    func restart() {
        attempt = 0
        start()
    }

    /// 是否有流在运行或即将重建（starting、running、retrying）。系统唤醒后只重建这些会话；
    /// idle、stoppedByUser、permissionDenied 的会话保持原状，否则会绕过用户的停止或权限判断。
    var isActive: Bool {
        switch state {
        case .starting, .running, .retrying: return true
        case .idle, .stoppedByUser, .permissionDenied, .windowGone: return false
        }
    }

    /// 停流并取消全部待执行的任务，状态不再变化。窗口消失或服务退出时调用。
    func shutdown() async {
        cancelScheduledStop()
        let oldStream = stream
        // 这里自己等停流完成，所以 tearDown 不再另发一次停流请求（重复停流会立即报错返回）。
        tearDown(stopsStream: false)
        try? await oldStream?.stopCapture()
    }

    // MARK: - 建流

    /// 开始建流：状态变为 starting，异步完成。
    private func start() {
        tearDown()
        let current = generation
        setState(.starting)
        Task { @MainActor [weak self] in
            await self?.establish(generation: current)
        }
    }

    /// 6.3 节「流的建立」第 1～4 步。
    private func establish(generation current: Int) async {
        let lookup = await cache.window(for: windowID)
        guard current == generation else { return }
        let window: SCWindow
        switch lookup {
        case .success(let found): window = found
        case .failure(.permissionDenied): return setState(.permissionDenied)
        case .failure(let error): return fail("查找 SCWindow 失败：\(error)", userStopped: false)
        }
        let handler = makeHandler()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let newStream = SCStream(filter: filter, configuration: Self.configuration(desiredSpec), delegate: handler)
        do {
            try newStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: handler.queue)
            self.stream = newStream
            self.handler = handler
            try await newStream.startCapture()
        } catch {
            guard current == generation else { return }
            cache.invalidate(windowID)
            return handleStop(error)
        }
        guard current == generation else {
            // startCapture 进行中会话被停止或重建了：tearDown 当时发出的停流请求早于建流完成，
            // 可能被系统忽略，流会在后台继续运行。这里等建流完成后再停一次。
            // 重复停流只会报错返回，用 try? 忽略。
            try? await newStream.stopCapture()
            return
        }
        runningSince = .now
        startWatchdog(generation: current)
    }

    /// 建一个处理器：帧到达时切回主线程取帧，流停止时切回主线程处理错误。
    /// 两个回调都核对处理器是否仍是当前的，过时流的回调直接丢弃。
    private func makeHandler() -> StreamOutputHandler {
        nonisolated(unsafe) weak var weakHandler: StreamOutputHandler?
        let handler = StreamOutputHandler(
            label: "eveopreview.capture.\(windowID.rawValue)",
            onFrameAvailable: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.drainFrame(from: weakHandler) }
                }
            },
            onStop: { [weak self] error in
                // 错误不是 Sendable，先取出域、错误码与说明再切回主线程；域要保留，
                // 否则别的域里恰好同号的错误会被误判成 userDeclined 或 userStopped。
                let nsError = error as NSError
                let domain = nsError.domain
                let code = nsError.code
                let description = nsError.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.streamStopped(from: weakHandler, domain: domain, code: code, description: description)
                    }
                }
            })
        weakHandler = handler
        return handler
    }

    /// 主线程取走槽位里的帧并交给上层。第一帧到达时状态变为 running。
    private func drainFrame(from source: StreamOutputHandler?) {
        guard let source, source === handler, let frame = source.takeLatest() else { return }
        if state != .running { setState(.running) }
        onFrame?(frame)
    }

    /// 流因错误停止（在主线程）。按原来的域与错误码重建错误，再交给 handleStop 分类。
    private func streamStopped(from source: StreamOutputHandler?, domain: String, code: Int, description: String) {
        guard let source, source === handler else { return }
        handleStop(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: description]))
    }

    /// 按错误码分类：拒绝授权、用户停止、其他（重试）。
    private func handleStop(_ error: any Error) {
        let nsError = error as NSError
        let isSCKError = nsError.domain == SCStreamErrorDomain
        if isSCKError, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            tearDown()
            setState(.permissionDenied)
        } else if isSCKError, nsError.code == SCStreamError.Code.userStopped.rawValue {
            fail("用户停止了捕获", userStopped: true)
        } else {
            fail("流停止：\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)", userStopped: false)
        }
    }

    /// 失败处理：用户停止时等 `restart()`；其余按 `RetryPolicy` 安排重建。
    private func fail(_ reason: String, userStopped: Bool) {
        tearDown()
        log.error("窗口 \(self.windowID.rawValue) 捕获失败：\(reason, privacy: .public)")
        if userStopped { return setState(.stoppedByUser) }
        if let since = runningSince, ContinuousClock.now - since >= Self.retryResetAfter { attempt = 0 }
        runningSince = nil
        attempt += 1
        let delay = RetryPolicy.delay(forAttempt: attempt)
        setState(.retrying(attempt: attempt, delay: delay))
        let current = generation
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled, let self, current == self.generation else { return }
            self.start()
        }
    }

    // MARK: - 更新与停止

    /// 规格变化后等 150 毫秒再更新，期间的多次变化合并成一次。
    private func scheduleUpdate() {
        updateTask?.cancel()
        let current = generation
        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.updateDebounce)
            guard !Task.isCancelled, let self, current == self.generation, let stream = self.stream else { return }
            do {
                try await stream.updateConfiguration(Self.configuration(self.desiredSpec))
            } catch {
                guard current == self.generation else { return }
                self.handleStop(error)
            }
        }
    }

    /// 丢掉当前的流和待执行任务，generation 加 1 让进行中的异步步骤失效。
    ///
    /// - Parameter stopsStream: 为真时异步发出停流请求，不等它完成；调用方自己等停流时传假。
    private func tearDown(stopsStream: Bool = true) {
        generation += 1
        retryTask?.cancel()
        updateTask?.cancel()
        watchdogTask?.cancel()
        retryTask = nil
        updateTask = nil
        watchdogTask = nil
        if stopsStream, let old = stream {
            Task { try? await old.stopCapture() }
        }
        stream = nil
        handler = nil
    }

    /// 看门狗判定停滞：按可重试的错误重建。
    fileprivate func watchdogFired() {
        fail("超过 5 秒没有回调", userStopped: false)
    }

    /// 状态有变化时记下并通知。
    private func setState(_ newState: CaptureState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}

// MARK: - 配置与看门狗

extension WindowCaptureSession {
    /// 按 6.3 节的表由规格生成流配置。
    static func configuration(_ spec: CaptureSpec) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = spec.pixelWidth
        configuration.height = spec.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(spec.framesPerSecond, 1)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        return configuration
    }

    /// 启动看门狗：每秒检查一次，窗口在屏幕上且连续 5 秒没有任何回调时按可重试的错误处理。
    ///
    /// 计时起点取「建流成功、最近一次回调、最近一次看到窗口不在屏幕上」三者中最晚的一个。
    /// 实测（V4）窗口最小化后流只发一次 suspended，之后完全没有回调，直到还原；
    /// 从不在屏幕上的时刻重新计时，还原后第一帧到达前的空档就不会被误判为停滞。
    func startWatchdog(generation current: Int) {
        guard watchdogEnabled else { return }
        let startedAt = ContinuousClock.now
        watchdogTask = Task { @MainActor [weak self] in
            var lastOffscreenAt = startedAt
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, current == self.generation else { return }
                guard Self.isOnScreen(self.windowID) else {
                    lastOffscreenAt = .now
                    continue
                }
                let lastCallback = self.statistics?.lastCallbackAt ?? startedAt
                if ContinuousClock.now - max(lastCallback, lastOffscreenAt) > Self.watchdogTimeout {
                    self.watchdogFired()
                    return
                }
            }
        }
    }

    /// 用 CGWindowList 单独查询一个窗口是否在屏幕上。查不到时按不在屏幕上处理。
    static func isOnScreen(_ id: WindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id.rawValue) as? [[String: Any]],
              let entry = list.first else { return false }
        return (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    }
}
