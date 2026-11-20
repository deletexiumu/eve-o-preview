// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一个缩略图面板的控制器（架构文档 7.3 节）：持有面板、内容视图与手势状态机，
// 按呈现更新面板的位置、透明度、层级与可见性。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 一个缩略图面板的控制器。
@MainActor
final class ThumbnailPanelController {
    /// 对应客户端主窗口的窗口 ID。
    let id: WindowID
    /// 面板。
    let panel: ThumbnailPanel
    /// 内容视图。
    let contentView: ThumbnailContentView
    /// 手势状态机。
    let interaction: ThumbnailInteraction
    /// 最近一次应用的呈现。
    private(set) var presentation: ThumbnailPresentation

    /// 用初始呈现建面板，暂不显示；随后调用 `apply` 决定是否显示。
    init(presentation: ThumbnailPresentation, delegate: ThumbnailPanelDelegate?) {
        id = presentation.id
        self.presentation = presentation
        let frame = CoordinateConversion.appKitFrame(presentation.frame)
        panel = ThumbnailPanel(frame: frame)
        contentView = ThumbnailContentView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        interaction = ThumbnailInteraction(id: presentation.id)
        interaction.delegate = delegate
        contentView.interaction = interaction
        let id = presentation.id
        contentView.onHoverChanged = { [weak delegate] inside in
            delegate?.hoverChanged(id, isHovering: inside)
        }
        interaction.setLiveFrame = { [weak self] rect in self?.setLiveFrame(rect) }
    }

    /// 面板当前是否可见。
    var isVisible: Bool { panel.isVisible }

    /// 面板当前的 frame，Core 坐标。
    var currentFrame: ScreenRect {
        CoordinateConversion.screenRect(appKitFrame: panel.frame)
    }

    /// 应用一个呈现。
    ///
    /// - Parameters:
    ///   - newPresentation: 规划器给出的呈现。
    ///   - isInteracting: 正在拖动时为真；此时呈现里是基准 frame，不应用，保留拖动中的实际位置。
    func apply(_ newPresentation: ThumbnailPresentation, isInteracting: Bool) {
        presentation = newPresentation
        contentView.apply(newPresentation)
        guard newPresentation.isVisible else {
            if panel.isVisible {
                // 拖动中被隐藏时取消拖动：协调器同时清掉它的交互状态，松开鼠标时不再提交。
                interaction.cancel()
                panel.orderOut(nil)
            }
            return
        }
        if !isInteracting {
            let frame = CoordinateConversion.appKitFrame(newPresentation.frame)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        panel.alphaValue = CGFloat(newPresentation.opacity)
        let level: NSWindow.Level = newPresentation.isAlwaysOnTop ? .floating : .normal
        if panel.level != level { panel.level = level }
        if !panel.isVisible {
            // 本应用几乎不在前台，orderFront 对非活动应用无效，所以用 orderFrontRegardless。
            panel.orderFrontRegardless()
            // 隐藏期间提醒层的动画可能已被系统移除，显示后补一次（反馈文档 7.8 节）。
            contentView.refreshAlert()
        }
    }

    /// 显示一帧画面。
    func display(_ frame: CapturedFrame) {
        contentView.display(frame)
    }

    /// 把面板放到最上面（同一层级内）。
    func bringToFront() {
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 拖动中直接设置面板 frame，不经过规划器。
    func setLiveFrame(_ rect: ScreenRect) {
        panel.setFrame(CoordinateConversion.appKitFrame(rect), display: true)
    }

    /// 关闭面板，客户端消失时调用。
    func close() {
        contentView.interaction = nil
        contentView.onHoverChanged = nil
        panel.orderOut(nil)
        panel.close()
    }
}
