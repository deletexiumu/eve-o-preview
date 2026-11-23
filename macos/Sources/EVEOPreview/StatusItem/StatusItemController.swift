// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单栏图标与菜单（架构文档 7.4 节），代替 Windows 版的托盘图标。
// 常驻的菜单项依次是：显示或隐藏全部缩略图、配置方案子菜单、全部最小化、热键只在 EVE 内生效、
// 显示预警浮窗、显示翻译浮窗、设置、退出。
// 有客户端的捕获被用户停止时多「恢复捕获」，缺权限时多一项权限提示。
// 菜单在每次打开前按当前状态重建（NSMenuDelegate.menuNeedsUpdate），不需要另外订阅状态变化。
//
// v1.1（v1.1 设计 11.1 节）：顶部加诊断与更新的提示项，退出前加「检查更新…」「报告问题…」，
// 这 4 组菜单项由 StatusItemController+Diagnostics.swift 与 StatusItemController+Updates.swift 返回。
// `coordinator.attention` 不为空时图标右上角显示圆点，`onAttentionChanged` 触发时重画图标。

import AppKit
import EVEOPreviewCore

/// 菜单栏图标的控制器。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// 协调器：菜单项的状态从它读，动作也交给它。扩展文件（诊断、更新的菜单项）也要读它，所以不是 private。
    let coordinator: AppCoordinator
    /// 菜单栏图标；系统只在它存活时显示图标，所以由控制器一直持有。
    private let statusItem: NSStatusItem
    /// 图标的菜单，内容每次打开前重建。
    private let menu = NSMenu()

    /// 建菜单栏图标。图标用 SF Symbols，没有时退回文字。
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            // 与应用图标一致的分子模板图（见 StatusBarIcon），由系统按菜单栏深浅色着色。
            button.image = StatusBarIcon.make(attention: !coordinator.attention.isEmpty)
            button.toolTip = L10n.appName
        }
        coordinator.onAttentionChanged = { [weak self] in self?.refreshIcon() }
        // 关掉自动启用：菜单项用闭包而不是响应链，置灰由各项的 isEnabled 决定。
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 按 `coordinator.attention` 重画图标：有原因时带圆点。
    func refreshIcon() {
        statusItem.button?.image = StatusBarIcon.make(attention: !coordinator.attention.isEmpty)
    }

    /// 菜单打开前按当前状态重建。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addHeader(to: menu)
        addAttentionItems(to: menu)
        addPermissionAndCaptureItems(to: menu)
        // 「全部隐藏」的文字随状态切换，点击即取反。
        let hideAll = coordinator.session.hideAll
        menu.addItem(ClosureMenuItem(hideAll ? L10n.menu.showAll : L10n.menu.hideAll) { [weak coordinator] in
            coordinator?.toggleHideAll()
        })
        menu.addItem(profilesItem())
        // 最小化要辅助功能权限，没有时置灰。
        menu.addItem(ClosureMenuItem(L10n.menu.minimizeAll, isEnabled: coordinator.permissions.accessibility) {
            [weak coordinator] in coordinator?.minimizeAll()
        })
        menu.addItem(hotkeyScopeItem())
        menu.addItem(overlayItem(.intel))
        menu.addItem(overlayItem(.translation))
        // 「检查更新…」「报告问题…」一组；骨架阶段没有菜单项时不加分隔线，菜单与 1.0.0 相同。
        let tools = updateMenuItems() + diagnosticsMenuItems()
        if !tools.isEmpty {
            menu.addItem(.separator())
            tools.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.menu.settings) { [weak coordinator] in
            coordinator?.openSettings?(.clients)
        })
        // 退出走 NSApp.terminate，由 AppDelegate 先写配置、再停捕获。
        menu.addItem(ClosureMenuItem(L10n.menu.quit) { NSApp.terminate(nil) })
    }

    /// 顶部的说明行：客户端数量；演示模式时注明。
    private func addHeader(to menu: NSMenu) {
        let count = coordinator.registry.clients.count
        let title = count == 0 ? L10n.menu.noClients : L10n.menu.clientCount(count)
        // 置灰的说明行，只显示不响应。
        menu.addItem(ClosureMenuItem(title, isEnabled: false) {})
        if coordinator.isFakeMode {
            menu.addItem(ClosureMenuItem(L10n.menu.fakeMode, isEnabled: false) {})
        }
        menu.addItem(.separator())
    }

    /// 诊断与更新的提示项（崩溃待报告、更新待安装、有可用更新），有时后面加一条分隔线。
    private func addAttentionItems(to menu: NSMenu) {
        let items = diagnosticsAttentionItems() + updateAttentionItems()
        guard !items.isEmpty else { return }
        items.forEach(menu.addItem)
        menu.addItem(.separator())
    }

    /// 缺权限的提示与「恢复捕获」，没有时不加任何项。
    private func addPermissionAndCaptureItems(to menu: NSMenu) {
        var added = false
        let status = coordinator.permissions
        if !status.screenRecording || !status.accessibility {
            menu.addItem(ClosureMenuItem("⚠︎ " + L10n.menu.permissionsMissing) { [weak coordinator] in
                coordinator?.openSettings?(.permissions)
            })
            added = true
        }
        // 每个被用户停止捕获的客户端一项（风险 R2：用户可能从系统录制指示器里停止捕获）。
        for client in coordinator.stoppedClients {
            let title = TitleParser.title(for: client.identity, pid: client.pid)
            let id = client.id
            menu.addItem(ClosureMenuItem(L10n.menu.resumeCapture(title)) { [weak coordinator] in
                coordinator?.resumeCapture(id)
            })
            added = true
        }
        if added { menu.addItem(.separator()) }
    }

    /// 「热键只在 EVE 内生效」：当前配置方案的默认作用范围是 game 时打勾，点击在 global 与 game 之间切换。
    /// 只改默认值，带后缀的热键不受影响（反馈文档 6.3 节、6.8 节）。
    private func hotkeyScopeItem() -> NSMenuItem {
        let isGameOnly = coordinator.profile.hotkeyDefaultScope == .game
        return ClosureMenuItem(L10n.hotkeys.menuHotkeysOnlyInEVE, isChecked: isGameOnly) { [weak coordinator] in
            coordinator?.config.updateActiveProfile { $0.hotkeyDefaultScope = isGameOnly ? .global : .game }
        }
    }

    /// 「显示预警浮窗」「显示翻译浮窗」：对应功能已开启时打勾，点击切换当前配置方案里的 `enabled`
    /// （docs/macos/design-intel-translate.md 第 10 节）。
    private func overlayItem(_ kind: OverlayKind) -> NSMenuItem {
        let profile = coordinator.profile
        let isOn = kind == .intel ? profile.intel.enabled : profile.translation.enabled
        let title = kind == .intel ? L10n.menu.showIntelOverlay : L10n.menu.showTranslationOverlay
        return ClosureMenuItem(title, isChecked: isOn) { [weak coordinator] in
            coordinator?.toggleOverlay(kind)
        }
    }

    /// 配置方案子菜单：当前方案打勾，点击即切换。
    private func profilesItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menu.profiles, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let config = coordinator.config.config
        for profile in config.profiles {
            let id = profile.id
            submenu.addItem(ClosureMenuItem(profile.name, isChecked: profile.id == config.activeProfileID) {
                [weak coordinator] in coordinator?.switchProfile(to: id)
            })
        }
        item.submenu = submenu
        return item
    }
}
