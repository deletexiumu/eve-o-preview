// SPDX-License-Identifier: GPL-3.0-or-later
//
// 会话标记与异常退出检测（v1.1 设计 5.5 节、6.1～6.3 节）。
//
// `start()` 的步骤：
// 1. 读 `session.json`，用 `SessionMarkerRules.decode` 解码；读不到或解不出时上一次的标记为 nil。
// 2. 判断上一次的进程是否还在：PID 不是本进程，且能取到同 bundle id、没有终止的应用。
// 3. 用 `SessionMarkerRules.outcome` 归类，存进 `previousRun`，写一条 info 日志。
// 4. 以原子方式写入本次运行的标记（endedCleanly 为假）。
// 5. 给 SIGTERM 与 SIGINT 各建一个 DispatchSource（先 SIG_IGN），收到后调 `NSApp.terminate(nil)`：
//    `kill <PID>` 与终端里的 Ctrl-C 也走正常的退出流程，不被记成异常结束。
// 6. 上一次异常结束时，在启动后 5 秒扫描崩溃报告，没找到时在 30 秒再扫描一次。列目录与读文件在后台任务里做。
//
// 找到报告、且会话编号不在 `dismissedSessionIDs` 里时：写 `pendingCrash`，调 `onCrashDetected`。
// 没找到时只写一条 info 日志，不提示用户：断电和强制退出不应换来一个报告窗口。
//
// state.json 里已有上次留下的 `pendingCrash`（用户选了「以后再说」）时，也经 `onCrashDetected` 交给问题报告，
// 由它亮起圆点和菜单项。每次运行最多调一次 `onCrashDetected`：上一次也异常结束时，等扫描结束再决定交哪一份。
//
// 演示模式用 `session-fake.json`。界面调试入口（13.1 节第 5 项）：`EVEO_FAKE=1` 且 `EVEO_FAKE_CRASH=1` 时，
// `start()` 写完标记后用一份样例 `PendingCrash` 调 `onCrashDetected`，不扫描，也不写 `pendingCrash`。

import AppKit
import EVEOPreviewCore

/// 会话标记与崩溃检测。全部方法在主线程调用。
@MainActor final class SessionTracker {
    /// 本进程的会话编号，启动时生成一次。文件日志的会话头（`LogBootstrap`）早于本对象建立，也用它。
    nonisolated static let currentSessionID = UUID().uuidString

    /// 第一次与第二次扫描崩溃报告的时刻（距 `start()` 的秒数）。
    static let scanDelays: [Duration] = [.seconds(5), .seconds(30)]

    /// 上一次运行的归类，`start()` 之后才有意义。
    private(set) var previousRun: PreviousRunOutcome
    /// 检测到上一次运行崩溃时调用，由 AppDelegate 接到 `ProblemReportController.crashDetected(_:)`。
    var onCrashDetected: (@MainActor (PendingCrash) -> Void)?

    /// 启动时读到的运行环境。
    let environment: AppEnvironment
    /// state.json 的持有者，写 `pendingCrash` 用。
    let state: StateController
    /// 崩溃报告的列出与读取。
    let diagnostics: any DiagnosticsService
    /// 是否为演示模式；演示模式用 `session-fake.json`。
    let isFakeMode: Bool

    /// 本次运行写下的标记；`start()` 之前是 nil。
    private var currentMarker: SessionMarker?
    /// SIGTERM 与 SIGINT 的信号源。要一直持有，释放后信号源就停了。
    private var signalSources: [any DispatchSourceSignal] = []
    /// 崩溃报告的扫描任务。
    private var scanTask: Task<Void, Never>?
    /// 本次运行已调过 `onCrashDetected`。
    private var didReportCrash = false
    private let log = AppLog.logger("Session")

    /// 建检测器；调用 `start()` 后才开始工作。
    init(environment: AppEnvironment, state: StateController, diagnostics: any DiagnosticsService, isFakeMode: Bool) {
        self.environment = environment
        self.state = state
        self.diagnostics = diagnostics
        self.isFakeMode = isFakeMode
        previousRun = .noRecord
    }

    /// `session.json` 的位置（`EVEO_STATE_DIR` 与演示模式的规则同 state.json）。
    var markerURL: URL {
        StateController.fileURL(baseName: "session", isFakeMode: isFakeMode)
    }

    /// 读上一次的标记、写本次的标记、装信号处理，并安排崩溃报告的扫描。
    func start() {
        guard currentMarker == nil else { return }
        let previous = readMarker()
        let alive = previous.map(isProcessAlive) ?? false
        previousRun = SessionMarkerRules.outcome(previous: previous, isPreviousProcessAlive: alive)
        log.info("上一次运行：\(SessionTracker.describe(previousRun), privacy: .public)")
        let marker = SessionMarker(sessionID: SessionTracker.currentSessionID, pid: getpid(),
                                   appVersion: environment.version, buildLabel: environment.buildLabel,
                                   startedAt: Date(), endedCleanly: false)
        currentMarker = marker
        writeMarker(marker)
        installSignalSources()

        if isFakeMode, ProcessInfo.processInfo.environment["EVEO_FAKE_CRASH"] == "1" {
            let crash = SessionTracker.sampleCrash(environment: environment)
            previousRun = .abnormal(SessionMarker(sessionID: crash.sessionID, pid: 90_000,
                                                  appVersion: crash.appVersion, buildLabel: environment.buildLabel,
                                                  startedAt: crash.startedAt, endedCleanly: false))
            reportCrash(crash)
            return
        }
        if case .abnormal(let previous) = previousRun {
            scheduleScan(for: previous)
        } else {
            reportStoredCrashIfAny()
        }
    }

    /// 把本次运行记为正常结束。只在 AppDelegate.replyToTerminate 里调。
    ///
    /// 文件里已是别的实例的标记时不写：重新启动的交接超时后，新实例已经覆盖了 session.json，
    /// 旧实例这时写回会把新实例的记录改成「已结束」。
    func markEndedCleanly() {
        guard var marker = currentMarker, !marker.endedCleanly else { return }
        scanTask?.cancel()
        if let onDisk = readMarker(), onDisk.sessionID != marker.sessionID {
            log.info("会话标记已被另一个实例覆盖，不再写回")
            return
        }
        marker.endedCleanly = true
        currentMarker = marker
        writeMarker(marker)
    }

    // MARK: - 标记文件

    /// 读 session.json；不存在或解不出时返回 nil。
    private func readMarker() -> SessionMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return SessionMarkerRules.decode(data)
    }

    /// 以原子方式写 session.json，需要时建目录。失败只记日志。
    private func writeMarker(_ marker: SessionMarker) {
        let url = markerURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SessionMarkerRules.encode(marker).write(to: url, options: .atomic)
        } catch {
            log.error("写会话标记失败：\(url.path, privacy: .public)，\(String(describing: error), privacy: .public)")
        }
    }

    /// 标记里的进程是否仍在运行，且是本应用（PID 可能已被别的进程复用）。
    private func isProcessAlive(_ marker: SessionMarker) -> Bool {
        guard marker.pid != getpid(), let app = NSRunningApplication(processIdentifier: marker.pid) else { return false }
        return app.bundleIdentifier == environment.bundleIdentifier && !app.isTerminated
    }

    // MARK: - 信号

    /// SIGTERM 与 SIGINT 改由主队列上的信号源处理：调 `NSApp.terminate(nil)`，走正常的退出流程。
    private func installSignalSources() {
        for signalNumber in [SIGTERM, SIGINT] {
            // 先忽略默认动作（直接终止进程），信号源才收得到。
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppLog.logger("Session").info("收到信号 \(signalNumber)，按正常流程退出")
                }
                // 不在这个主队列任务里直接调 terminate：terminate 会开嵌套事件循环等
                // applicationShouldTerminate 的回复，而回复靠主线程 Task 发出；主队列是串行的，
                // 当前任务不返回，那些 Task 和超时都轮不到，进程卡死（v1.1 手工测试发现）。
                // 交给运行循环执行，嵌套循环里主队列照常排空。
                RunLoop.main.perform {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - 崩溃报告

    /// 上一次异常结束：在启动后 5 秒与 30 秒各扫描一次，找到就停。两次都没找到时交出 state.json 里已有的待报告崩溃。
    private func scheduleScan(for previous: SessionMarker) {
        let diagnostics = self.diagnostics
        let executableName = environment.executableName
        let bundleID = environment.bundleIdentifier
        let clock = ContinuousClock()
        let begin = clock.now
        scanTask = Task { [weak self] in
            for delay in SessionTracker.scanDelays {
                do { try await clock.sleep(until: begin + delay) } catch { return }
                // 列目录、读第一行在后台做，不占主线程。
                let found = await Task.detached(priority: .utility) {
                    CrashReportMatcher.select(from: diagnostics.crashReportCandidates(executableName: executableName),
                                              executableName: executableName, bundleID: bundleID,
                                              window: CrashReportMatcher.window(startedAt: previous.startedAt,
                                                                                scannedAt: Date()))
                }.value
                guard !Task.isCancelled else { return }
                if !found.isEmpty {
                    self?.crashReportsFound(found, previous: previous)
                    return
                }
            }
            self?.noCrashReportFound(previous: previous)
        }
    }

    /// 找到了上一次运行的崩溃报告：会话编号没被用户忽略过时写 `pendingCrash` 并交给问题报告。
    private func crashReportsFound(_ reports: [CrashReportCandidate], previous: SessionMarker) {
        log.info("找到上一次运行的崩溃报告 \(reports.count) 个：\(reports.map(\.fileName).joined(separator: ", "), privacy: .public)")
        guard !state.state.diagnostics.dismissedSessionIDs.contains(previous.sessionID) else {
            log.info("这次崩溃用户已选过不报告，不再提示")
            reportStoredCrashIfAny()
            return
        }
        let crash = PendingCrash(sessionID: previous.sessionID, appVersion: previous.appVersion,
                                 startedAt: previous.startedAt, detectedAt: Date(),
                                 reportFileNames: reports.map(\.fileName))
        state.update { $0.diagnostics.pendingCrash = crash }
        reportCrash(crash)
    }

    /// 两次扫描都没找到崩溃报告：只记日志，不提示（6.3 节）。
    private func noCrashReportFound(previous: SessionMarker) {
        log.info("上一次运行异常结束，但没有找到崩溃报告（可能是强制退出或断电），不提示")
        reportStoredCrashIfAny()
    }

    /// state.json 里有上次留下、没被忽略的待报告崩溃时，交给问题报告。
    private func reportStoredCrashIfAny() {
        guard let stored = state.state.diagnostics.pendingCrash,
              !state.state.diagnostics.dismissedSessionIDs.contains(stored.sessionID) else { return }
        log.info("上次检测到的崩溃还没有处理，再次提示")
        reportCrash(stored)
    }

    /// 调 `onCrashDetected`，每次运行最多一次。
    private func reportCrash(_ crash: PendingCrash) {
        guard !didReportCrash else { return }
        didReportCrash = true
        onCrashDetected?(crash)
    }

    /// 日志里上一次运行的写法：`noRecord`、`clean`、`stillRunning`、`abnormal`，后两种带会话编号的前 8 位与版本。
    static func describe(_ outcome: PreviousRunOutcome) -> String {
        switch outcome {
        case .noRecord: return "noRecord"
        case .clean: return "clean"
        case .stillRunning(let marker):
            return "stillRunning（会话 \(marker.sessionID.prefix(8).lowercased())，版本 \(marker.appVersion)，PID \(marker.pid)）"
        case .abnormal(let marker):
            return "abnormal（会话 \(marker.sessionID.prefix(8).lowercased())，版本 \(marker.appVersion)）"
        }
    }

    /// `EVEO_FAKE_CRASH` 用的样例：一小时前开始、刚检测到的崩溃，带两个报告文件名。
    /// 文件名不对应真实文件，演示模式的诊断服务按名字返回假内容。
    static func sampleCrash(environment: AppEnvironment) -> PendingCrash {
        let now = Date()
        return PendingCrash(sessionID: "00000000-0000-4000-8000-00000000FA4E", appVersion: environment.version,
                            startedAt: now.addingTimeInterval(-3600), detectedAt: now,
                            reportFileNames: ["EVEOPreview-2026-11-21-040506.ips", "EVEOPreview-2026-11-20-221100.ips"])
    }
}
