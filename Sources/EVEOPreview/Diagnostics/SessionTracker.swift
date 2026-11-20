// SPDX-License-Identifier: GPL-3.0-or-later
//
// 会话标记与异常退出检测（v1.1 设计 5.5 节、6.1～6.3 节）。
// `start()` 读上一次的标记、写本次的标记、给 SIGTERM 与 SIGINT 装信号源，上一次异常结束时安排崩溃报告的扫描；
// 找到报告时写 `pendingCrash` 并调 `onCrashDetected`。`markEndedCleanly()` 只在 `AppDelegate.replyToTerminate` 里调。
//
// WP-0 只建骨架：不读也不写 `session.json`，`previousRun` 保持 `.noRecord`；WP-1 实现。
// 骨架带一个界面调试入口（13.1 节第 5 项）：`EVEO_FAKE=1` 且 `EVEO_FAKE_CRASH=1` 时，`start()` 用一份样例
// `PendingCrash` 调 `onCrashDetected`，供 WP-2 做崩溃情境的报告窗口。WP-1 实现时保留这个入口。
// `session.json` 的位置用 `StateController.fileURL(baseName: "session", isFakeMode:)`。

import Foundation
import EVEOPreviewCore

/// 会话标记与崩溃检测。全部方法在主线程调用。
@MainActor final class SessionTracker {
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

    /// 建检测器；调用 `start()` 后才开始工作。
    init(environment: AppEnvironment, state: StateController, diagnostics: any DiagnosticsService, isFakeMode: Bool) {
        self.environment = environment
        self.state = state
        self.diagnostics = diagnostics
        self.isFakeMode = isFakeMode
        previousRun = .noRecord
    }

    /// 读上一次的标记、写本次的标记、装信号处理，并安排崩溃报告的扫描。
    ///
    /// 骨架：只处理 `EVEO_FAKE_CRASH` 的调试入口（WP-1 实现其余部分）。
    func start() {
        guard isFakeMode, ProcessInfo.processInfo.environment["EVEO_FAKE_CRASH"] == "1" else { return }
        let crash = SessionTracker.sampleCrash(environment: environment)
        previousRun = .abnormal(SessionMarker(sessionID: crash.sessionID, pid: 90_000,
                                              appVersion: crash.appVersion, buildLabel: environment.buildLabel,
                                              startedAt: crash.startedAt, endedCleanly: false))
        onCrashDetected?(crash)
    }

    /// 把本次运行记为正常结束。只在 AppDelegate.replyToTerminate 里调。
    ///
    /// 骨架：不做事（WP-1 实现）。
    func markEndedCleanly() {}

    /// `EVEO_FAKE_CRASH` 用的样例：一小时前开始、刚检测到的崩溃，带两个报告文件名。
    /// 文件名不对应真实文件，演示模式的诊断服务按名字返回假内容。
    static func sampleCrash(environment: AppEnvironment) -> PendingCrash {
        let now = Date()
        return PendingCrash(sessionID: "00000000-0000-4000-8000-00000000FA4E", appVersion: environment.version,
                            startedAt: now.addingTimeInterval(-3600), detectedAt: now,
                            reportFileNames: ["EVEOPreview-2026-11-21-040506.ips", "EVEOPreview-2026-11-20-221100.ips"])
    }
}
