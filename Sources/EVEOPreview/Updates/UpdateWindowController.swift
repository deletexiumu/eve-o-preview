// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新窗口（v1.1 设计 8.6 节）：宽 560 点、高 480 点，显示新版本、发布说明与按钮（内容在 UpdateView.swift）。
// 窗口第一次显示时创建，关闭后保留，下次显示沿用。
//
// 两种显示方式（4.5 节）：
// - 用户点出来的（菜单项、「通用」页的按钮）：取消等待中的自动弹出，调 `NSApp.activate()`，再 `makeKeyAndOrderFront`。
// - 应用自己弹出的（自动检查发现新版本）：经 `DeferredPresenter`，key 是 `update`。能弹时只 `orderFrontRegardless()`，
//   不激活本应用，窗口不成为 key 窗口；前台是 EVE 客户端时等前台变化之后再弹。窗口已显示时不重复弹出。
//
// 窗口被用户用标题栏的关闭按钮或 ⌘W 直接关掉、阶段仍是 `available` 时，按「稍后」处理（Esc 本来就触发「稍后」按钮）。
// 界面语言变了以后重设标题并重建视图：本窗口不在设置窗口的 `.id` 重建范围里，协调器的
// `onLanguageChanged` 已由 AppDelegate 占用，所以自己注册一个配置观察者。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 更新窗口的控制器。全部方法在主线程调用。
@MainActor final class UpdateWindowController: NSObject, NSWindowDelegate {
    /// 更新功能的控制器，窗口按它的状态显示。
    let controller: UpdateController

    /// `DeferredPresenter` 里自动弹出的更新窗口的 key（4.5 节的表）。
    static let presenterKey = "update"
    /// 窗口内容区的尺寸（8.6 节）。
    static let contentSize = NSSize(width: 560, height: 480)

    /// 窗口；第一次显示时创建。
    private var window: NSWindow?
    /// 窗口的内容控制器，界面语言变了以后换掉它的根视图。
    private var hosting: NSHostingController<AnyView>?
    /// 为真时窗口是按钮的动作关掉的，`windowWillClose` 不再按「稍后」处理。
    private var closingAfterAction = false

    /// 建窗口控制器。窗口在第一次 `show` 时才建。
    init(controller: UpdateController) {
        self.controller = controller
        super.init()
        // 协调器的配置观察者注册得更早，这里收到通知时界面语言已经切换好（AppCoordinator+Language.swift）。
        controller.coordinator.config.addObserver { [weak self] old, new in
            guard old.general.language != new.general.language else { return }
            self?.languageDidChange()
        }
    }

    /// 显示更新窗口。userInitiated 为真时激活本应用并成为 key 窗口；为假时不激活。窗口已显示时不重复弹出。
    func show(userInitiated: Bool) {
        let presenter = controller.coordinator.presenter
        if userInitiated {
            // 用户自己打开了，等待中的自动弹出不再需要。
            presenter.cancel(key: Self.presenterKey)
            let window = ensureWindow()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            presenter.present(key: Self.presenterKey) { [weak self] in self?.showWithoutActivating() }
        }
    }

    /// 自动弹出：不激活本应用，不抢键盘焦点（4.5 节、V27）。窗口已显示时什么也不做。
    private func showWithoutActivating() {
        if let window, window.isVisible { return }
        ensureWindow().orderFrontRegardless()
    }

    /// 按钮的动作已交给控制器之后关窗口。
    private func dismissAfterAction() {
        closingAfterAction = true
        window?.close()
        closingAfterAction = false
    }

    /// 取已有的窗口，没有时创建：标准标题栏，可缩放，第一次显示时居中。
    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: rootView())
        // 尺寸由窗口决定，不跟随 SwiftUI 内容的理想尺寸：发布说明很长时窗口会超出屏幕。
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.updates.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.contentSize)
        window.contentMinSize = NSSize(width: 480, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.hosting = hosting
        self.window = window
        return window
    }

    /// 窗口的根视图。`.id` 随界面语言变化，语言变了以后整棵视图树重建，各处文字取到新语言。
    private func rootView() -> AnyView {
        AnyView(UpdateView(controller: controller) { [weak self] in self?.dismissAfterAction() }
            .id(L10n.language))
    }

    /// 界面语言变了：重设标题，换根视图。窗口还没建过时不用处理，建窗口时自然取到新语言。
    private func languageDidChange() {
        window?.title = L10n.updates.windowTitle
        hosting?.rootView = rootView()
    }

    /// 窗口被用户直接关掉、阶段仍是 `available` 时，按「稍后」处理：圆点与菜单项保留，下次自动检查时再提示。
    func windowWillClose(_ notification: Notification) {
        guard !closingAfterAction, case .available = controller.phase else { return }
        controller.remindLater()
    }
}
