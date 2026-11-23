// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗列表的一行（docs/design-intel-translate.md 8.4 节）：一个多行的 NSTextField 标签，内容是 OverlayStyle 拼出的富文本，
// 按词折行，不可选中；emphasis 是 alert 或 clear 时画行的背景。
// 行高由 measuredHeight 给出：用与标签同样设置的 NSTextFieldCell 按列宽量出文字的高度，向上取整后加 4 点。
// 用标签自己的单元格量，量出的高度与标签实际折行一致（boundingRect 不含单元格的内边距，可能少一行）。

import AppKit
import EVEOPreviewCore

/// 浮窗列表的一行。
final class OverlayRowView: NSView {
    /// 表格复用行视图时用的标识。
    static let identifier = NSUserInterfaceItemIdentifier("OverlayRow")
    /// 文字左右各留的边距，单位是点。
    static let horizontalPadding: CGFloat = 6
    /// 文字上下合计留的边距（8.4 节的「加 4 点」），单位是点。
    static let verticalPadding: CGFloat = 4

    /// 显示富文本的标签。
    private let label = OverlayRowView.makeLabel()

    /// 建行视图，开图层画背景。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = OverlayRowView.identifier
        wantsLayer = true
        layer?.cornerRadius = 3
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 创建")
    }

    /// 显示一行：富文本与强调背景。
    func show(_ text: NSAttributedString, emphasis: OverlayEmphasis) {
        label.attributedStringValue = text
        layer?.backgroundColor = OverlayStyle.emphasisColor(emphasis)?.cgColor
        needsLayout = true
    }

    /// 标签占满去掉边距后的区域。
    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: OverlayRowView.horizontalPadding, dy: OverlayRowView.verticalPadding / 2)
    }

    /// 鼠标事件不落在行上：点击由面板与表格处理，标签不响应。
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - 行高

    /// 量行高用的单元格，设置与标签相同。只在主线程使用。
    private static let measuringCell: NSTextFieldCell = {
        let cell = makeLabel().cell as? NSTextFieldCell ?? NSTextFieldCell()
        return cell
    }()

    /// 一行的高度：按列宽（减去左右边距）量出文字的高度，向上取整后加 4 点。
    static func measuredHeight(of text: NSAttributedString, columnWidth: CGFloat) -> CGFloat {
        let width = max(20, columnWidth - 2 * horizontalPadding)
        measuringCell.attributedStringValue = text
        let size = measuringCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                            height: CGFloat.greatestFiniteMagnitude))
        return ceil(size.height) + verticalPadding
    }

    /// 建一个按词折行、不可选中、不画背景与边框的多行标签。
    private static func makeLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.refusesFirstResponder = true
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        return label
    }
}
