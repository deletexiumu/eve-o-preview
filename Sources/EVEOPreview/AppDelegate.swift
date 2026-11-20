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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 没有 EVEO_FAKE 时使用真实平台服务（由 WP-B 实现）。
        let isFake = FakeServices.isEnabled
        let config = ConfigController(store: JSONFileConfigStore(fileURL: AppDelegate.configFileURL(fake: isFake)))
        // 界面语言要在建主菜单、菜单栏与设置窗口之前定下，它们建好后不会自己换语言。
        L10n.setLanguage(L10n.resolve(config.config.general.language))
        installMainMenu()
        let services = isFake ? FakeServices.make() : PlatformServices.makeLive()
        let coordinator = AppCoordinator(services: services, config: config, isFakeMode: isFake)
        let settings = SettingsWindowController(coordinator: coordinator)
        coordinator.openSettings = { [weak settings] page in settings?.show(page: page) }
        // 语言切换后：主菜单启动时建一次，要重建；设置窗口的标题建窗口时设一次，要重设。
        coordinator.onLanguageChanged = { [weak self, weak settings] in
            self?.installMainMenu()
            settings?.languageDidChange()
        }
        statusItem = StatusItemController(coordinator: coordinator)
        configController = config
        self.coordinator = coordinator
        settingsWindow = settings
        coordinator.start()
        log.info("启动完成，演示模式：\(isFake)，界面语言：\(L10n.language.rawValue, privacy: .public)，配置文件：\(config.fileURL.path, privacy: .public)")
        showOnboardingIfNeeded(config: config, coordinator: coordinator)
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

    /// 退出：先写配置，再等捕获服务停止全部流（最多 `terminateTimeout`），然后真正退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        // 配置先同步写盘：即使停止捕获时出问题，用户的改动也不会丢。
        configController?.flush()
        let coordinator = self.coordinator
        // 停止与超时各用一个独立任务，谁先完成谁回复。不用 TaskGroup：任务组要等全部子任务结束，
        // 停流卡住时仍会挂住退出。
        Task { @MainActor [weak self] in
            await coordinator?.stop()
            self?.replyToTerminate(timedOut: false)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppDelegate.terminateTimeout)
            self?.replyToTerminate(timedOut: true)
        }
        return .terminateLater
    }

    /// 回复系统可以退出。只回复一次。
    private func replyToTerminate(timedOut: Bool) {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        if timedOut { log.error("停止捕获超过 2.5 秒，不再等待，直接退出") }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// 关掉设置窗口后应用继续在菜单栏运行。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 主菜单

    /// 装一个只含「编辑」的主菜单。应用没有 Dock 图标，菜单栏上看不到它，
    /// 但设置窗口的文本框要靠它响应 Cmd+C、Cmd+V、Cmd+Z 等快捷键，Cmd+W 关窗口。
    /// 启动时调用一次，界面语言变了以后再调用一次，整个替换掉旧菜单。
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
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
