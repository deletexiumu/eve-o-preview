// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口（架构文档 7.4 节）：NSWindow 加 NSHostingController，内容是 SwiftUI 的 SettingsRootView。
// 窗口第一次打开时创建，关闭后保留，下次打开沿用。打开时调 NSApp.activate()，
// 因为本应用是 accessory 应用，不激活的话窗口会出现在其他应用后面、也收不到键盘输入。

import AppKit
import SwiftUI

/// 设置窗口的页。顺序即侧栏顺序（docs/design-intel-translate.md 第 10 节）：客户端、预览与布局、切换与热键、
/// 提醒、预警、翻译、配置方案、通用、权限、关于，共 10 页。
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case clients, previews, switching, alerts, intel, translation, profiles, general, permissions, about

    var id: String { rawValue }
}

/// 设置窗口的控制器。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private var window: NSWindow?
    private var model: SettingsViewModel?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// 打开设置窗口并切到指定页。
    func show(page: SettingsPage) {
        let model = self.model ?? SettingsViewModel(coordinator: coordinator)
        self.model = model
        model.page = page
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        model.windowDidOpen()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 界面语言变了以后调用：重设窗口标题。页内容由 SettingsRootView 的 `.id` 重建（反馈文档 5.4 节）。
    func languageDidChange() {
        window?.title = L10n.settings.windowTitle
    }

    /// 建窗口：标准标题栏，可缩放，最小 760×520。
    private func makeWindow(model: SettingsViewModel) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        // 不让窗口跟随 SwiftUI 内容的理想尺寸：表单很长，跟随时窗口会超出屏幕。
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.settings.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 620))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// 窗口关闭：先取消进行中的热键录制（恢复全局热键），再停止权限轮询。
    func windowWillClose(_ notification: Notification) {
        HotkeyRecorder.cancelActive()
        model?.windowDidClose()
    }

    /// 窗口失去键盘焦点（切到别的应用或窗口）：取消进行中的热键录制。
    /// 本地键盘监听只收得到发给 key 窗口的按键，失去焦点后录制无法完成，全局热键会一直暂停。
    func windowDidResignKey(_ notification: Notification) {
        HotkeyRecorder.cancelActive()
    }
}
