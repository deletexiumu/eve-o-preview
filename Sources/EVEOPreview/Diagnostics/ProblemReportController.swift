// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的流程（v1.1 设计 6.3 节、7.1 节）。三个入口打开同一个报告窗口：菜单栏菜单的「报告问题…」、
// 「通用」页的同名按钮（手动情境），以及检测到崩溃后的提示（崩溃情境）。
// 用户确认之前不写任何文件，不打开浏览器。
//
// 流程：
// 1. 主线程取快照（`ProblemReportBuilder.snapshot`），后台收集并脱敏，窗口先显示进度，收集完显示文件列表与预览。
// 2. 用户点「生成报告并打开 GitHub」或「只生成报告」：勾选的文件加上 `manifest.json` 交给 `diagnostics.writeArchive`。
// 3. 在访达里显示 zip；选了前一个按钮时，再用 `IssueURLBuilder.url(for:)` 生成地址并在浏览器里打开。
// 4. 崩溃情境下清掉 `pendingCrash` 与圆点。窗口换成完成页。
// 第 2 步失败时窗口显示原因，不打开浏览器。
//
// 崩溃提示只由 `SessionTracker.onCrashDetected` 触发（启动时 `state.json` 里已有的 `pendingCrash` 也由它重放），
// 本控制器不自己读 `state.json` 来弹提示，否则会弹两次。同一个会话每次运行最多自动显示一次窗口。

import AppKit
import EVEOPreviewCore

/// 报告窗口的情境。
enum ProblemReportContext: Sendable, Equatable {
    /// 用户从菜单或设置窗口打开。
    case manual
    /// 检测到上一次运行崩溃。
    case crash(PendingCrash)
}

/// 问题报告的控制器。全部方法在主线程调用。
@MainActor final class ProblemReportController {
    /// 协调器：取运行时摘要、配置与平台服务，亮起菜单栏的圆点。协调器与本控制器同生命周期，所以不持有强引用。
    unowned let coordinator: AppCoordinator
    /// 启动时读到的运行环境。
    let environment: AppEnvironment
    /// state.json 的持有者：`pendingCrash` 与 `dismissedSessionIDs`。
    let state: StateController

    /// 推迟弹窗用的 key（4.5 节）。
    static let presenterKey = "crash"
    /// `dismissedSessionIDs` 最多保留几个。
    static let maxDismissedSessions = 20

    /// 报告窗口。
    private let windowController = ProblemReportWindowController()
    /// 当前窗口的状态；窗口关闭后为 nil。
    private var model: ProblemReportModel?
    /// 进行中的收集任务。
    private var collectTask: Task<Void, Never>?
    /// 待报告的崩溃。演示模式的样例崩溃不写进 state.json，所以由本控制器自己记住。
    private(set) var pendingCrash: PendingCrash?
    /// 本次运行已自动显示过窗口的会话编号。
    private var autoPresentedSessions: Set<String> = []
    /// 控制器建立时的单调时钟，近似应用启动的时刻，用来算运行时长。
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    private let log = AppLog.logger("ProblemReport")

    /// 建控制器。由 AppDelegate 在建好协调器之后调用。
    init(coordinator: AppCoordinator, environment: AppEnvironment, state: StateController) {
        self.coordinator = coordinator
        self.environment = environment
        self.state = state
        windowController.onClose = { [weak self] in self?.windowDidClose() }
    }

    // MARK: - 入口

    /// 用户从菜单或设置窗口打开。
    func showReportWindow(context: ProblemReportContext) {
        open(context: context, userInitiated: true)
    }

    /// 菜单顶部的崩溃提示项：打开崩溃情境的窗口。没有待报告的崩溃时打开手动情境。
    func showPendingCrashReport() {
        if let crash = pendingCrash ?? state.state.diagnostics.pendingCrash {
            showReportWindow(context: .crash(crash))
        } else {
            showReportWindow(context: .manual)
        }
    }

    /// 检测到崩溃后调用：亮起菜单栏的提示，并在不打断游戏时显示报告窗口。同一个会话每次运行最多自动显示一次。
    /// 「不报告」过的会话由 `SessionTracker` 过滤（6.3 节），这里不再查 `dismissedSessionIDs`。
    func crashDetected(_ crash: PendingCrash) {
        pendingCrash = crash
        coordinator.setAttention(.crashPending, on: true)
        guard autoPresentedSessions.insert(crash.sessionID).inserted else { return }
        log.info("检测到上一次运行崩溃，\(crash.reportFileNames.count) 个崩溃报告")
        coordinator.presenter.present(key: ProblemReportController.presenterKey) { [weak self] in
            self?.presentAutomatically(crash)
        }
    }

    /// 用户选「不报告」：记下会话编号，清掉 `pendingCrash` 与圆点。
    func dismissPendingCrash() {
        if let sessionID = (pendingCrash ?? state.state.diagnostics.pendingCrash)?.sessionID {
            state.update { state in
                var dismissed = state.diagnostics.dismissedSessionIDs.filter { $0 != sessionID }
                dismissed.append(sessionID)
                state.diagnostics.dismissedSessionIDs = Array(dismissed.suffix(ProblemReportController.maxDismissedSessions))
            }
        }
        clearPendingCrash()
    }

    // MARK: - 窗口

    /// 打开窗口。已显示同一情境的报告时只放到前面；自动弹出时窗口已显示就不打扰。
    private func open(context: ProblemReportContext, userInitiated: Bool) {
        if userInitiated, case .crash = context {
            coordinator.presenter.cancel(key: ProblemReportController.presenterKey)
        }
        if windowController.isVisible {
            guard userInitiated else { return }
            if let model, model.context == context, model.phase != .done {
                windowController.bringToFront()
                return
            }
        }
        startSession(context: context, userInitiated: userInitiated)
    }

    /// 推迟器到时调用：自动显示崩溃情境的窗口，不激活本应用。
    private func presentAutomatically(_ crash: PendingCrash) {
        guard pendingCrash?.sessionID == crash.sessionID else { return }
        open(context: .crash(crash), userInitiated: false)
    }

    /// 新建一次报告：显示窗口（收集中），在后台收集。
    private func startSession(context: ProblemReportContext, userInitiated: Bool) {
        collectTask?.cancel()
        let model = ProblemReportModel(context: context)
        self.model = model
        windowController.show(model: model, controller: self, userInitiated: userInitiated)
        let snapshot = ProblemReportBuilder.snapshot(coordinator: coordinator, environment: environment,
                                                     context: context, launchUptime: launchUptime,
                                                     pendingCrash: pendingCrash)
        collectTask = Task { [weak self, weak model] in
            let contents = await ProblemReportBuilder.collectInBackground(snapshot)
            guard !Task.isCancelled, let model, self?.model === model else { return }
            model.loaded(contents)
        }
    }

    /// 窗口关闭：停止收集，丢掉状态。崩溃情境下关闭等于「以后再说」，`pendingCrash` 与圆点保留。
    private func windowDidClose() {
        collectTask?.cancel()
        collectTask = nil
        model = nil
    }

    // MARK: - 窗口里的按钮

    /// 「取消」「以后再说」「关闭」：关闭窗口。
    func closeWindow() {
        windowController.close()
    }

    /// 「不报告」：记下会话编号并关闭窗口。
    func dontReport() {
        dismissPendingCrash()
        windowController.close()
    }

    /// 「生成报告并打开 GitHub」与「只生成报告」：写压缩包，在访达里显示，按需打开浏览器。
    func createReport(openIssue: Bool) {
        guard let model, model.phase == .review, let contents = model.contents else { return }
        model.phase = .creating
        model.errorMessage = nil
        let now = Date()
        let name = DiagnosticsBundlePlanner.archiveName(at: now)
        let selected = model.includedItems
        let manifest = ProblemReportBuilder.manifestItem(for: selected, contents: contents, generatedAt: now)
        let files = (selected + [manifest]).map { DiagnosticsFile(relativePath: $0.relativePath, contents: $0.contents) }
        let issueURL = IssueURLBuilder.url(for: ProblemReportBuilder.issueDraft(contents: contents,
                                                                                archiveFileName: name + ".zip"))
        let diagnostics = coordinator.services.diagnostics
        Task { [weak self] in
            let result = await ProblemReportBuilder.writeArchive(diagnostics, named: name, files: files)
            self?.archiveFinished(result, model: model, issueURL: issueURL, openIssue: openIssue)
        }
    }

    /// 压缩包写完：成功时显示 zip、按需打开浏览器、清掉崩溃提示、换成完成页；失败时显示原因。
    ///
    /// 用户在生成期间关了窗口时，照样显示 zip 与打开浏览器：生成是用户点的。
    private func archiveFinished(_ result: Result<URL, DiagnosticsIOError>, model: ProblemReportModel,
                                 issueURL: URL, openIssue: Bool) {
        switch result {
        case .success(let zip):
            model.archiveURL = zip
            model.issueURL = issueURL
            model.phase = .done
            let diagnostics = coordinator.services.diagnostics
            diagnostics.revealInFinder(zip)
            if openIssue { diagnostics.openInBrowser(issueURL) }
            if model.isCrash { clearPendingCrash() }
        case .failure(let error):
            log.error("生成报告失败：\(String(describing: error), privacy: .public)")
            model.phase = .review
            model.errorMessage = L10n.diagnostics.createFailed(ProblemReportController.reason(error))
        }
    }

    /// 完成页的「在访达中显示」。
    func revealArchive() {
        guard let zip = model?.archiveURL else { return }
        coordinator.services.diagnostics.revealInFinder(zip)
    }

    /// 完成页的「再次打开 GitHub」。
    func reopenIssue() {
        guard let url = model?.issueURL else { return }
        coordinator.services.diagnostics.openInBrowser(url)
    }

    // MARK: - 小工具

    /// 清掉待报告的崩溃：state.json、圆点与推迟中的弹窗。
    private func clearPendingCrash() {
        pendingCrash = nil
        state.update { $0.diagnostics.pendingCrash = nil }
        coordinator.setAttention(.crashPending, on: false)
        coordinator.presenter.cancel(key: ProblemReportController.presenterKey)
    }

    /// 失败原因的文字（系统的说明，不翻译）。
    private static func reason(_ error: DiagnosticsIOError) -> String {
        switch error {
        case .writeFailed(let path, let reason): return "\(reason) (\(path))"
        case .archiveFailed(let reason): return reason
        }
    }
}
