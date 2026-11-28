// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一个浮窗面板的控制器（docs/macos/design-intel-translate.md 8.3～8.7 节）：持有面板、内容视图与手势状态机，
// 按呈现更新面板的位置、层级、外观与可见性，把内容交给内容视图，弹出右键菜单。
// - 层级的取法与缩略图相同：不置顶是 normal，置顶是 floating，盖在原生全屏客户端上时用 ThumbnailPanel.fullScreenLevel。
// - 不透明度只给内容视图的背景图层，面板的 alphaValue 保持 1，文字始终不透明（Q21）。
// - 拖动中（isInteracting）不应用呈现里的 frame，保留手势设的实际位置。
// - 面板不知道预警与翻译的区别，也不知道链接指向哪里。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 一个浮窗面板的控制器。
@MainActor
final class InfoOverlayController {
    /// 浮窗的种类。
    let kind: OverlayKind
    /// 面板。
    let panel: InfoOverlayPanel
    /// 内容视图。
    let contentView: InfoOverlayContentView
    /// 手势状态机。
    let interaction: OverlayInteraction
    /// 最近一次应用的呈现。
    private(set) var presentation: OverlayPresentation
    /// 委托（协调器）：拖动与菜单的结果交给它。
    weak var delegate: InfoOverlayDelegate? {
        didSet { interaction.delegate = delegate }
    }

    /// 用初始呈现建面板，暂不显示；随后调用 `apply` 决定是否显示。
    init(presentation: OverlayPresentation, delegate: InfoOverlayDelegate?) {
        kind = presentation.kind
        self.presentation = presentation
        let frame = CoordinateConversion.appKitFrame(presentation.frame)
        panel = InfoOverlayPanel(frame: frame)
        contentView = InfoOverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        interaction = OverlayInteraction(kind: presentation.kind)
        self.delegate = delegate
        interaction.delegate = delegate
        panel.interaction = interaction
        interaction.setLiveFrame = { [weak self] rect in self?.setLiveFrame(rect) }
        interaction.showMenu = { [weak self] event in self?.showMenu(for: event) }
        interaction.plainClick = { [weak self] event in self?.handlePlainClick(event) ?? false }
        // 鼠标停在边缘带上时显示缩放光标；规则与左键按下时相同（布局锁定时不显示）。
        contentView.cursorEdges = { [weak self] in self?.interaction.hoverEdges() ?? [] }
        contentView.applyAppearance(opacity: presentation.opacity, fontSize: presentation.fontSize)
        contentView.applyLockState(presentation.isLocked)
    }

    /// 面板当前是否可见。
    var isVisible: Bool { panel.isVisible }

    /// 面板当前的 frame，Core 坐标。
    var currentFrame: ScreenRect {
        CoordinateConversion.screenRect(appKitFrame: panel.frame)
    }

    /// 应用一个呈现：外观、可见性、frame 与层级。
    ///
    /// - Parameters:
    ///   - newPresentation: 规划器给出的呈现。
    ///   - isInteracting: 正在拖动时为真；此时不应用 frame。
    func apply(_ newPresentation: OverlayPresentation, isInteracting: Bool) {
        presentation = newPresentation
        contentView.applyAppearance(opacity: newPresentation.opacity, fontSize: newPresentation.fontSize)
        contentView.applyLockState(newPresentation.isLocked)
        guard newPresentation.isVisible else {
            if panel.isVisible {
                // 拖动中被隐藏时取消拖动：协调器同时清掉它的交互状态，松开鼠标时不再提交。
                interaction.cancel()
                // 隐藏的面板收不到 mouseExited：鼠标正停在边缘带或频道按钮上时，光标与悬停态要在这里恢复。
                contentView.resetHoverAndCursor()
                panel.orderOut(nil)
            }
            return
        }
        if !isInteracting {
            let frame = CoordinateConversion.appKitFrame(newPresentation.frame)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        let level: NSWindow.Level
        if !newPresentation.isAlwaysOnTop {
            level = .normal
        } else {
            level = newPresentation.isOverFullScreen ? ThumbnailPanel.fullScreenLevel : .floating
        }
        if panel.level != level { panel.level = level }
        if !panel.isVisible {
            // 本应用几乎不在前台，orderFront 对非活动应用无效，所以用 orderFrontRegardless；不激活本应用。
            panel.orderFrontRegardless()
            contentView.refreshLockEffect()
        }
    }

    /// 显示新内容。
    func setContent(_ content: OverlayContent) {
        contentView.setContent(content)
    }

    /// 拖动中直接设置面板 frame，不经过规划器。
    private func setLiveFrame(_ rect: ScreenRect) {
        panel.setFrame(CoordinateConversion.appKitFrame(rect), display: true)
    }

    /// 不带修饰键的左键：点在新消息条上时回到最新，点在频道切换按钮上时通知委托弹菜单，否则交还给面板。
    private func handlePlainClick(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        if contentView.isChannelButton(atWindowPoint: point) {
            delegate?.overlayChannelSwitcherClicked(for: kind)
            return true
        }
        guard contentView.isNewMessagesBar(atWindowPoint: point) else { return false }
        contentView.scrollToLatest()
        return true
    }

    /// 在频道切换按钮下方弹出原生菜单；面板不可见时不弹。菜单关闭后恢复按钮悬停态。
    func showChannelMenu(_ menu: NSMenu) {
        guard panel.isVisible else { return }
        menu.popUp(positioning: nil, at: contentView.channelButtonMenuOrigin(), in: contentView)
        contentView.resetHoverAndCursor()
    }

    /// 右键单击：按光标下的那一行建菜单并弹出。
    private func showMenu(for event: NSEvent) {
        let model = OverlayContextMenu.Model(isLocked: presentation.isLocked,
                                             line: contentView.line(atWindowPoint: event.locationInWindow))
        let kind = self.kind
        let menu = OverlayContextMenu.make(model) { [weak self] action in
            switch action {
            case .scrollToLatest: self?.contentView.scrollToLatest()
            case .delegate(let action): self?.delegate?.overlayMenuAction(action, for: kind)
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    /// 关闭面板：浮窗被关掉或退出时调用。
    func close() {
        contentView.cursorEdges = nil
        contentView.resetHoverAndCursor()
        interaction.cancel()
        panel.interaction = nil
        panel.orderOut(nil)
        panel.close()
    }
}
