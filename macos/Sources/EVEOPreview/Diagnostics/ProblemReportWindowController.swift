// SPDX-License-Identifier: GPL-3.0-or-later
//
// 报告窗口（v1.1 设计 7.4 节、4.5 节）：`NSWindow` 加 `NSHostingController`，宽 720 点、高 520 点，可缩放。
// 用户点出来的窗口激活本应用并成为 key 窗口；自动弹出的窗口（崩溃提示）只 `orderFrontRegardless()`，不抢焦点。
//
// 本文件还有窗口的状态 `ProblemReportModel`：阶段（收集中、预览、生成中、完成）、文件列表与勾选、选中的文件、错误。
// 流程由 `ProblemReportController` 驱动，视图在 ProblemReportView.swift。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 报告窗口的状态。全部方法在主线程调用。
@MainActor @Observable final class ProblemReportModel {
    /// 窗口的阶段。
    enum Phase: Equatable {
        /// 正在收集与脱敏，显示进度，生成按钮不可用。
        case collecting
        /// 显示文件列表与预览，等用户确认。
        case review
        /// 正在写压缩包。
        case creating
        /// 完成页。
        case done
    }

    /// 情境。
    let context: ProblemReportContext
    /// 当前阶段。
    var phase: Phase = .collecting
    /// 预览项（不含 `manifest.json`）。
    private(set) var items: [ReportItem] = []
    /// 勾选的文件（相对路径）。
    var included: Set<String> = []
    /// 选中查看的文件（相对路径）。
    var selectedID: String?
    /// 生成失败时的说明。
    var errorMessage: String?
    /// 生成好的 zip。
    var archiveURL: URL?
    /// 预填的 Issue 地址。
    var issueURL: URL?
    /// 收集的结果，生成时用。
    @ObservationIgnored private(set) var contents: ProblemReportContents?

    /// 建状态，阶段是收集中。
    init(context: ProblemReportContext) {
        self.context = context
    }

    /// 是否为崩溃情境。
    var isCrash: Bool {
        if case .crash = context { return true }
        return false
    }

    /// 收集完成：默认全部勾选，选中第一个文件。
    func loaded(_ contents: ProblemReportContents) {
        self.contents = contents
        items = contents.items
        included = Set(contents.items.map(\.id))
        selectedID = contents.items.first?.id
        phase = .review
    }

    /// 勾选的预览项，顺序与列表相同。
    var includedItems: [ReportItem] {
        items.filter { $0.isRequired || included.contains($0.id) }
    }

    /// 按当前勾选生成的 `manifest.json` 预览；收集完成前为 nil。
    var manifestPreview: ReportItem? {
        guard let contents else { return nil }
        return ProblemReportBuilder.manifestItem(for: includedItems, contents: contents, generatedAt: contents.snapshot.takenAt)
    }

    /// 列表里的全部文件：预览项加上 `manifest.json`。
    var displayItems: [ReportItem] {
        items + (manifestPreview.map { [$0] } ?? [])
    }

    /// 选中的文件。
    var selectedItem: ReportItem? {
        displayItems.first { $0.id == selectedID }
    }
}

/// 报告窗口。全部方法在主线程调用。
@MainActor final class ProblemReportWindowController: NSObject, NSWindowDelegate {
    /// 窗口；第一次显示时建，关闭后保留以便再次使用。
    private var window: NSWindow?
    /// 窗口的内容。
    private var hosting: NSHostingController<ProblemReportView>?
    /// 窗口被关闭（用户点关闭按钮或代码关闭）后调用。
    var onClose: (() -> Void)?

    /// 窗口是否正在显示。
    var isVisible: Bool { window?.isVisible == true }

    /// 用新的状态显示窗口。userInitiated 为真时激活本应用并成为 key 窗口；为假时只放到前面，不抢焦点。
    func show(model: ProblemReportModel, controller: ProblemReportController, userInitiated: Bool) {
        let view = ProblemReportView(model: model, controller: controller)
        let window: NSWindow
        if let existing = self.window, let hosting {
            hosting.rootView = view
            window = existing
        } else {
            let hosting = NSHostingController(rootView: view)
            // 窗口大小由窗口决定，不跟随内容的理想尺寸。
            hosting.sizingOptions = []
            window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 520))
            // 最小宽度要放得下崩溃情境的 4 个按钮（俄文约 640 点加两侧边距）。
            window.contentMinSize = NSSize(width: 700, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            self.hosting = hosting
        }
        window.title = L10n.diagnostics.windowTitle
        if userInitiated {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// 把已显示的窗口放到前面（用户再次从菜单打开同一个报告）。
    func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关闭窗口；会触发 `onClose`。
    func close() {
        window?.close()
    }

    /// 窗口关闭时通知控制器。
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
