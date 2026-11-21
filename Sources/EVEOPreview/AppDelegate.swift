// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用生命周期（架构文档 7.1 节）：组装配置、平台服务、协调器、菜单栏与设置窗口。
//
// - 环境变量 `EVEO_FAKE=1` 时用 FakeServices，否则用 PlatformServices.makeLive()。
// - 演示模式的配置写到单独的 `config-fake.json`，不把假角色写进用户的配置。
//   环境变量 `EVEO_CONFIG_PATH` 可以指定任意配置文件，供开发调试。
// - 读完配置后、建任何界面之前设置界面语言（反馈文档 5.4 节）；语言变了以后重建主菜单、重设设置窗口的标题。
// - 首次启动（onboardingCompleted 为 false）或缺权限时，打开设置窗口的权限页。
// - 退出时先写配置，再等捕获服务停止全部流。
//
// v1.1（v1.1 设计 4.4 节）：
// - 启动时先读运行环境、装文件日志（读配置之前，读配置的错误才能进文件），读完配置后设文件日志的级别，
//   再建 `StateController`；建好协调器后建会话检测、问题报告、更新与更新窗口，`coordinator.start()` 之后启动前两者。
// - 退出时协调器停止后，自动安装已下载好时安装更新；回复系统之前把会话标为正常结束并冲刷日志。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform
import os

/// 应用委托。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 配置的持有者，退出时用它写盘。
    private var configController: ConfigController?
    /// 协调器，持有全部运行时状态。
    private var coordinator: AppCoordinator?
    /// 菜单栏图标；必须一直持有，否则图标消失。
    private var statusItem: StatusItemController?
    /// 设置窗口的控制器。
    private var settingsWindow: SettingsWindowController?
    /// 退出流程已开始；重复的退出请求只等第一次完成。
    private var isTerminating = false
    /// 已回复 `applicationShouldTerminate`；停止完成与超时谁先到谁回复，只回复一次。
    private var didReplyToTerminate = false
    private let log = AppLog.logger("App")

    /// 退出时等捕获服务停止的上限。某条流的停止卡住时，到点也照常退出，不让退出流程挂住。
    static let terminateTimeout: Duration = .milliseconds(2500)
    /// 有已下载好、等待安装的更新时的退出上限：停止捕获 2.5 秒加安装 8 秒（v1.1 设计 4.4 节、9.5 节）。
    static let terminateTimeoutWithUpdate: Duration = .milliseconds(10_500)
    /// 退出时安装更新最多等多久。
    static let installOnQuitTimeout: Duration = .seconds(8)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 没有 EVEO_FAKE 时使用真实平台服务（由 WP-B 实现）。
        let isFake = FakeServices.isEnabled
        // 运行环境与文件日志放在最前面：之后每一步（含读配置）的日志都能进文件。
        let environment = AppEnvironmentProvider.current()
        LogBootstrap.start(environment: environment, isFakeMode: isFake)
        let config = ConfigController(store: JSONFileConfigStore(fileURL: AppDelegate.configFileURL(fake: isFake)))
        LogBootstrap.apply(level: config.config.general.logLevel)
        let state = StateController(store: JSONStateStore(
            fileURL: StateController.fileURL(baseName: "state", isFakeMode: isFake)))
        // 界面语言要在建主菜单、菜单栏与设置窗口之前定下，它们建好后不会自己换语言。
        L10n.setLanguage(L10n.resolve(config.config.general.language))
        installMainMenu()
        // 进程按 LSUIElement 以 .accessory 启动；读完配置再按开关决定要不要 Dock 图标。
        DockIconPolicy.apply(showDockIcon: config.config.general.showDockIcon)
        config.addObserver { old, new in
            guard old.general.showDockIcon != new.general.showDockIcon else { return }
            DockIconPolicy.apply(showDockIcon: new.general.showDockIcon)
        }
        let services = isFake ? FakeServices.make() : PlatformServices.makeLive()
        let coordinator = AppCoordinator(services: services, config: config, isFakeMode: isFake,
                                         environment: environment, state: state)
        let settings = SettingsWindowController(coordinator: coordinator)
        coordinator.openSettings = { [weak settings] page in settings?.show(page: page) }
        // 语言切换后：主菜单启动时建一次，要重建；设置窗口的标题建窗口时设一次，要重设。
        coordinator.onLanguageChanged = { [weak self, weak settings] in
            self?.installMainMenu()
            settings?.languageDidChange()
        }
        installDiagnosticsAndUpdates(on: coordinator, environment: environment, state: state, isFake: isFake)
        statusItem = StatusItemController(coordinator: coordinator)
        configController = config
        self.coordinator = coordinator
        settingsWindow = settings
        coordinator.start()
        coordinator.sessionTracker.start()
        coordinator.updates.start()
        log.info("启动完成，演示模式：\(isFake)，界面语言：\(L10n.language.rawValue, privacy: .public)，配置文件：\(config.fileURL.path, privacy: .public)")
        showOnboardingIfNeeded(config: config, coordinator: coordinator)
    }

    /// 建会话检测、问题报告、更新与更新窗口，赋给协调器，并接上两个回调（v1.1 设计 4.4 节第 6 步）：
    /// 检测到崩溃时交给问题报告；更新控制器请求显示窗口时交给更新窗口。
    private func installDiagnosticsAndUpdates(on coordinator: AppCoordinator, environment: AppEnvironment,
                                              state: StateController, isFake: Bool) {
        let sessionTracker = SessionTracker(environment: environment, state: state,
                                            diagnostics: coordinator.services.diagnostics, isFakeMode: isFake)
        let problemReport = ProblemReportController(coordinator: coordinator, environment: environment, state: state)
        let updates = UpdateController(coordinator: coordinator, environment: environment, state: state)
        let updateWindow = UpdateWindowController(controller: updates)
        sessionTracker.onCrashDetected = { [weak problemReport] crash in problemReport?.crashDetected(crash) }
        updates.presentWindow = { [weak updateWindow] userInitiated in updateWindow?.show(userInitiated: userInitiated) }
        coordinator.sessionTracker = sessionTracker
        coordinator.problemReport = problemReport
        coordinator.updates = updates
        coordinator.updateWindow = updateWindow
    }

    /// 首次启动或缺权限时打开权限页，并记下已完成首次引导。
    private func showOnboardingIfNeeded(config: ConfigController, coordinator: AppCoordinator) {
        // 开发调试：环境变量 `EVEO_SETTINGS_PAGE=<页名>`（如 previews）启动后直接打开该页，便于截图核对界面。
        if let name = ProcessInfo.processInfo.environment["EVEO_SETTINGS_PAGE"], let page = SettingsPage(rawValue: name) {
            coordinator.openSettings?(page)
            return
        }
        let status = coordinator.services.permissions.status()
        let missing = !status.screenRecording || !status.accessibility
        guard !config.config.general.onboardingCompleted || missing else { return }
        coordinator.openSettings?(.permissions)
        config.update { $0.general.onboardingCompleted = true }
    }

    /// 配置文件的位置：`EVEO_CONFIG_PATH` 优先；演示模式用同目录下的 `config-fake.json`。
    static func configFileURL(fake: Bool) -> URL {
        if let path = ProcessInfo.processInfo.environment["EVEO_CONFIG_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let standard = JSONFileConfigStore.defaultFileURL()
        guard fake else { return standard }
        return standard.deletingLastPathComponent().appendingPathComponent("config-fake.json")
    }

    /// 退出：先写配置，再等捕获服务停止全部流，自动安装已下载好时再安装更新，然后真正退出。
    ///
    /// 等待上限：没有待安装的更新时是 `terminateTimeout`（2.5 秒），有时是 `terminateTimeoutWithUpdate`（10.5 秒）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        // 配置先同步写盘：即使停止捕获时出问题，用户的改动也不会丢。
        configController?.flush()
        let coordinator = self.coordinator
        // 是否有已下载好的更新只决定等多久；装不装由 installOnQuitIfReady 按 9.5 节的条件判断。
        let timeout = coordinator?.state.state.updates.prepared == nil
            ? AppDelegate.terminateTimeout : AppDelegate.terminateTimeoutWithUpdate
        // 停止与超时各用一个独立任务，谁先完成谁回复。不用 TaskGroup：任务组要等全部子任务结束，
        // 停流卡住时仍会挂住退出。
        Task { @MainActor [weak self] in
            await coordinator?.stop()
            await coordinator?.updates?.installOnQuitIfReady(timeout: AppDelegate.installOnQuitTimeout)
            self?.replyToTerminate(timedOut: false)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.replyToTerminate(timedOut: true, timeout: timeout)
        }
        return .terminateLater
    }

    /// 回复系统可以退出。只回复一次。
    ///
    /// 正常结束与超时两条路径都经过这里：先把会话标为正常结束，再冲刷日志，最后回复系统。
    private func replyToTerminate(timedOut: Bool, timeout: Duration = AppDelegate.terminateTimeout) {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        if timedOut {
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            log.error("退出流程超过 \(seconds, format: .fixed(precision: 1)) 秒，不再等待，直接退出")
        }
        coordinator?.sessionTracker?.markEndedCleanly()
        PlatformLog.flush()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// 关掉设置窗口后应用继续在菜单栏运行。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点 Dock 图标，或在访达里再次打开正在运行的应用：没有可见窗口时打开设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { coordinator?.openSettings?(.clients) }
        return true
    }

    // MARK: - 主菜单

    /// 装主菜单：应用菜单（设置、退出）与「编辑」菜单。
    /// 不显示 Dock 图标时菜单栏上看不到它，但设置窗口的文本框要靠它响应 Cmd+C、Cmd+V、Cmd+Z 等快捷键，
    /// Cmd+W 关窗口；显示 Dock 图标时应用激活后菜单栏上会出现它，所以应用菜单不能是空的。
    /// 启动时调用一次，界面语言变了以后再调用一次，整个替换掉旧菜单。
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = ClosureMenuItem(L10n.menu.settings) { [weak self] in
            self?.coordinator?.openSettings?(.clients)
        }
        settingsItem.keyEquivalent = ","
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        // 退出走 NSApp.terminate，由 applicationShouldTerminate 先写配置、再停捕获。
        appMenu.addItem(NSMenuItem(title: L10n.menu.quit, action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L10n.editMenu.title)
        let entries: [(String, Selector, String)] = [
            (L10n.editMenu.undo, Selector(("undo:")), "z"),
            (L10n.editMenu.redo, Selector(("redo:")), "Z"),
            (L10n.editMenu.cut, #selector(NSText.cut(_:)), "x"),
            (L10n.editMenu.copy, #selector(NSText.copy(_:)), "c"),
            (L10n.editMenu.paste, #selector(NSText.paste(_:)), "v"),
            (L10n.editMenu.selectAll, #selector(NSText.selectAll(_:)), "a"),
            (L10n.editMenu.closeWindow, #selector(NSWindow.performClose(_:)), "w"),
        ]
        for (title, action, key) in entries {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}
