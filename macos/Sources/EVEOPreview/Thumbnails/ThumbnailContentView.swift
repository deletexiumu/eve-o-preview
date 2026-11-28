// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的内容视图（架构文档 7.3 节）。图层从下到上共 7 层：
// 画面层（IOSurface）、占位层、标题层、跳过标记层、边框层、锁定特效层（LockEffectLayer）、
// 提醒层（AlertFlashLayer，反馈文档 7.8 节）。
// 锁定特效层向内缩进外圈边框的宽度，不覆盖活动窗口高亮边框，两种效果清晰叠加。
// 鼠标事件转给 ThumbnailInteraction；悬停用 activeAlways 的 NSTrackingArea，
// 因为本应用几乎不在前台，不用 activeAlways 就收不到悬停事件。
// 同一个跟踪区域也收 mouseMoved：鼠标停在边缘带上时显示缩放光标（ResizeCursor，v1.2.1）。
//
// 坐标：视图不翻转，图层原点在左下角。Core 给的 contentsRect 原点在左上角，设置前在这里翻转。

import AppKit
import QuartzCore
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 缩略图的内容视图。
final class ThumbnailContentView: NSView {
    /// 鼠标手势的处理者。
    var interaction: ThumbnailInteraction?
    /// 悬停状态变化的回调，参数为鼠标是否在视图内。
    var onHoverChanged: ((Bool) -> Void)?
    /// 是否已经收到过画面；有画面时「等待画面」的占位不遮住它。
    private(set) var hasFrame = false

    /// 画面层：contents 是捕获到的 IOSurface，拉伸填满。
    private let imageLayer = CALayer()
    /// 占位层：深色半透明底，最小化时仍能隐约看到最后一帧。
    private let placeholderLayer = CALayer()
    /// 占位层里的说明文字。
    private let placeholderText = CATextLayer()
    /// 标题层：左上角的角色名，带半透明底。
    private let titleLayer = CATextLayer()
    /// 跳过标记层：右上角的红色圆。
    private let skipLayer = CALayer()
    /// 跳过标记里的白色横杠。
    private let skipBar = CALayer()
    /// 边框层：只画边框，盖在画面之上，不缩小画面。高亮边框与中性边框共用这一层，同一时刻只画一种。
    private let borderLayer = CALayer()
    /// 锁定特效层：画在外圈边框之内侧，叠加显示锁定布局的角标与流光动画，不覆盖活动高亮边框。
    private let lockLayer = LockEffectLayer()
    /// 提醒层：战斗提醒期间闪烁，在最顶层。动画由它自己管理。
    private let alertLayer = AlertFlashLayer()

    /// 当前呈现。
    private var presentation: ThumbnailPresentation?
    /// 当前外圈边框的内缩宽度（点），锁定特效层按此内缩以保留外圈高亮边框。
    private var borderInset: CGFloat = 0
    /// 画面在 surface 里的范围，归一化，原点在左上角。
    private var surfaceRect = UnitRect.full
    /// 悬停用的跟踪区域；视图尺寸变化时重建。
    private var trackingArea: NSTrackingArea?

    /// 建视图并建好 7 个图层。视图由 AppKit 托管图层（wantsLayer）。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
        layoutLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 创建")
    }

    // MARK: - 图层

    /// 建 7 个图层并关闭隐式动画（锁定特效层与提醒层的显示与动画由各自管理）。
    private func setUpLayers() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        imageLayer.contentsGravity = .resize
        placeholderLayer.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        placeholderText.alignmentMode = .center
        placeholderText.isWrapped = true
        placeholderText.fontSize = 12
        placeholderText.foregroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        placeholderLayer.addSublayer(placeholderText)
        titleLayer.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        titleLayer.cornerRadius = 3
        titleLayer.truncationMode = .end
        // 跳过标记：红色圆形加一条白色横杠（禁行符号）。
        skipLayer.backgroundColor = NSColor.systemRed.cgColor
        skipBar.backgroundColor = NSColor.white.cgColor
        skipLayer.addSublayer(skipBar)
        borderLayer.backgroundColor = nil
        for sublayer in [imageLayer, placeholderLayer, titleLayer, skipLayer, borderLayer, lockLayer, alertLayer] {
            root.addSublayer(sublayer)
        }
        // 图层属性默认带 0.25 秒的隐式动画；画面每帧更新、面板拖动时跟手，都不能有动画。
        let none = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull(),
                    "hidden": NSNull(), "borderWidth": NSNull(), "borderColor": NSNull(), "string": NSNull()]
        for sublayer in [imageLayer, placeholderLayer, placeholderText, titleLayer, skipLayer, skipBar, borderLayer] {
            sublayer.actions = none
        }
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    /// 移到不同缩放的屏幕时更新文字图层的 contentsScale，否则文字发虚。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in [placeholderText, titleLayer] {
            text.contentsScale = scale
        }
        lockLayer.updateContentsScale(scale)
    }

    /// 按视图尺寸摆放各图层。标题在左上角，跳过标记在右上角。
    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = self.bounds
        imageLayer.frame = bounds
        placeholderLayer.frame = bounds
        let textHeight = placeholderText.fontSize * 2.6
        placeholderText.frame = CGRect(x: 8, y: (bounds.height - textHeight) / 2,
                                       width: max(0, bounds.width - 16), height: textHeight)
        borderLayer.frame = bounds
        layoutLockLayer(in: bounds)
        alertLayer.frame = bounds
        layoutTitle(in: bounds)
        let diameter = max(14, min(24, bounds.height * 0.12))
        skipLayer.frame = CGRect(x: bounds.width - diameter - 4, y: bounds.height - diameter - 4,
                                 width: diameter, height: diameter)
        skipLayer.cornerRadius = diameter / 2
        skipBar.frame = CGRect(x: diameter * 0.2, y: diameter * 0.42, width: diameter * 0.6, height: diameter * 0.16)
    }

    /// 标题层按文字宽度收缩，最宽到视图宽度减去边距。
    private func layoutTitle(in bounds: CGRect) {
        let size = CGFloat(presentation?.titleFontSize ?? 12)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let text = presentation?.title ?? ""
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + 4)
        let width = min(textWidth + 10, max(0, bounds.width - 8))
        titleLayer.frame = CGRect(x: 4, y: bounds.height - height - 4, width: width, height: height)
    }

    // MARK: - 呈现与画面

    /// 按呈现更新标题、占位、跳过标记、边框、提醒与画面的裁剪范围。
    func apply(_ newPresentation: ThumbnailPresentation) {
        let old = presentation
        presentation = newPresentation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        applyTitle(newPresentation)
        applyPlaceholder(newPresentation)
        skipLayer.isHidden = !newPresentation.isSkipped
        applyBorder(newPresentation)
        let inset = CGFloat(LockEffectRules.borderInset(for: newPresentation))
        if inset != borderInset || (lockLayer.frame.isEmpty && !bounds.isEmpty) {
            borderInset = inset
            layoutLockLayer(in: bounds)
        }
        let triggerEngage = LockEffectRules.shouldTriggerEngage(previousLocked: old?.isLocked,
                                                                newLocked: newPresentation.isLocked)
        lockLayer.update(locked: newPresentation.isLocked, triggerEngage: triggerEngage)
        alertLayer.update(newPresentation.alert)
        // 裁剪范围只在源窗口尺寸或裁剪设置变化时变，避免每次重算都改 contentsRect。
        if old?.contentsRect != newPresentation.contentsRect {
            updateContentsRect()
        }
        if old?.title != newPresentation.title || old?.titleFontSize != newPresentation.titleFontSize {
            needsLayout = true
        }
    }

    /// 设置边框层（反馈文档 4.1 节）。取值顺序：
    /// 1. 有高亮颜色（高亮已打开，且是活动客户端）：用高亮的颜色和粗细；
    /// 2. 否则有边框颜色（边框已打开）：用中性边框的颜色和粗细；
    /// 3. 否则不画。
    /// 颜色串解析失败时按「没有这种颜色」处理，落到下一种（校验器已保证合法，这里只作防御）。
    private func applyBorder(_ p: ThumbnailPresentation) {
        let highlight = p.highlightColor.flatMap { NSColor(hex: $0) }
        let neutral = p.borderColor.flatMap { NSColor(hex: $0) }
        if let highlight {
            borderLayer.borderColor = highlight.cgColor
            borderLayer.borderWidth = CGFloat(p.highlightThickness)
            borderLayer.isHidden = false
        } else if let neutral {
            borderLayer.borderColor = neutral.cgColor
            borderLayer.borderWidth = CGFloat(p.borderThickness)
            borderLayer.isHidden = false
        } else {
            borderLayer.isHidden = true
        }
    }

    /// 用当前的呈现再更新一次提醒层与锁定特效层。面板从隐藏变成显示后调用：隐藏期间系统可能移除了图层上的动画（V14）。
    func refreshAlert() {
        alertLayer.update(presentation?.alert)
        lockLayer.refresh()
    }

    /// 将锁定特效层摆在外圈边框（活动高亮或中性边框）之内侧，防止遮挡外圈边框。
    private func layoutLockLayer(in bounds: CGRect) {
        let safeInset = min(borderInset, min(bounds.width, bounds.height) / 2)
        lockLayer.frame = bounds.insetBy(dx: safeInset, dy: safeInset)
    }

    /// 更新标题层的文字、字号与颜色。
    private func applyTitle(_ p: ThumbnailPresentation) {
        titleLayer.isHidden = !p.showsTitle
        // 前面加一个空格，让文字与半透明底的左边留出间距。
        titleLayer.string = " " + p.title
        titleLayer.font = NSFont.systemFont(ofSize: CGFloat(p.titleFontSize), weight: .semibold)
        titleLayer.fontSize = CGFloat(p.titleFontSize)
        titleLayer.foregroundColor = (NSColor(hex: p.titleColor) ?? .white).cgColor
    }

    /// 按占位类型显示或隐藏占位层。已有画面时「等待画面」不遮住画面。
    private func applyPlaceholder(_ p: ThumbnailPresentation) {
        let text: String?
        switch p.placeholder {
        case .none: text = nil
        case .waitingForFrame: text = hasFrame ? nil : L10n.thumbnail.waiting
        case .needsScreenRecording: text = L10n.thumbnail.needsScreenRecording
        case .captureStopped: text = L10n.thumbnail.captureStopped
        case .minimized: text = L10n.thumbnail.minimized
        }
        placeholderLayer.isHidden = text == nil
        placeholderText.string = text ?? ""
    }

    /// 显示一帧画面。画面拉伸填满缩略图（与上游一致）。
    func display(_ frame: CapturedFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // contentRect 的单位是像素，原点在 surface 左上角；归一化后与规划器的裁剪范围复合。
        let width = Double(frame.surface.width)
        let height = Double(frame.surface.height)
        if width > 0, height > 0 {
            let rect = frame.contentRect
            let unit = UnitRect(x: rect.minX / width, y: rect.minY / height,
                                width: rect.width / width, height: rect.height / height)
            if unit != surfaceRect {
                surfaceRect = unit
                updateContentsRect()
            }
        }
        imageLayer.contents = frame.surface
        if !hasFrame {
            hasFrame = true
            if let presentation { applyPlaceholder(presentation) }
        }
    }

    /// 由 surface 内的画面范围与规划器给的裁剪范围复合出 `contentsRect`，并翻转到图层坐标。
    ///
    /// 两者原点都在左上角：先在画面范围内取裁剪范围，再把 y 换成「距底边的距离」。
    private func updateContentsRect() {
        let crop = presentation?.contentsRect ?? .full
        let x = surfaceRect.x + crop.x * surfaceRect.width
        let y = surfaceRect.y + crop.y * surfaceRect.height
        let width = crop.width * surfaceRect.width
        let height = crop.height * surfaceRect.height
        imageLayer.contentsRect = CGRect(x: x, y: 1 - y - height, width: width, height: height)
    }

    // MARK: - 鼠标

    /// 面板不是 key 窗口时，第一次点击也要直接生效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 重建跟踪区域。inVisibleRect 让区域随视图尺寸自动变化（悬停放大时面板会变大）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways,
                                            .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // 鼠标事件：悬停交给回调，按键与拖动交给手势状态机。右键也由视图自己处理，不设置 NSView.menu。
    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        updateCursor()
    }
    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        ResizeCursor.reset()
    }
    override func mouseMoved(with event: NSEvent) { updateCursor() }
    /// AppKit 在光标进入跟踪区域时会发 cursorUpdate 并默认设回箭头；改为按边缘带重新设置。
    override func cursorUpdate(with event: NSEvent) { updateCursor() }
    override func mouseDown(with event: NSEvent) { interaction?.mouseDown(event, button: .left) }
    override func mouseDragged(with event: NSEvent) { interaction?.mouseDragged(event, button: .left) }
    override func mouseUp(with event: NSEvent) { interaction?.mouseUp(event, button: .left, in: self) }
    override func rightMouseDown(with event: NSEvent) { interaction?.mouseDown(event, button: .right) }
    override func rightMouseDragged(with event: NSEvent) { interaction?.mouseDragged(event, button: .right) }
    override func rightMouseUp(with event: NSEvent) { interaction?.mouseUp(event, button: .right, in: self) }

    /// 按鼠标是否停在边缘带上显示或恢复缩放光标。
    private func updateCursor() {
        ResizeCursor.update(for: interaction?.hoverEdges() ?? [])
    }
}
