// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的样式与颜色（docs/macos/design-intel-translate.md 8.4 节的表）：把 Core 的 OverlaySpanStyle 换成颜色、字重与字体，
// 把一条 OverlayLine 拼成一段富文本。第一行用 presentation.fontSize，第二行小 1 点（不小于 9 点），两行之间用换行连接。
// 背景只随不透明度变，文字始终不透明（Q21）。

import AppKit
import EVEOPreviewCore

/// 浮窗的样式表。
enum OverlayStyle {
    /// 背景的圆角，单位是点。
    static let cornerRadius: CGFloat = 6
    /// 背景边线的不透明度（白色，1 点）。
    static let borderAlpha: CGFloat = 0.18
    /// 第二行的最小字号。
    static let minimumSecondaryFontSize = 9.0

    // MARK: - 文字样式

    /// 一段文字的颜色（8.4 节的表）。
    static func color(for style: OverlaySpanStyle) -> NSColor {
        switch style {
        case .plain, .translated: return NSColor(white: 1, alpha: 0.92)
        case .dim, .channel, .ageOld, .jumpsUnknown, .noVisual, .pending: return NSColor(white: 1, alpha: 0.55)
        case .speaker: return hex("#A8C7FA")
        case .ageFresh: return hex("#FF6B6B")
        case .ageRecent, .jumpsMid: return hex("#FFD166")
        case .systemHigh, .clear: return hex("#6BD38A")
        case .systemLow: return hex("#F2B45A")
        case .systemNull, .failed: return hex("#FF7A7A")
        case .systemUnknown: return hex("#B8B8B8")
        case .jumpsNear: return hex("#FF5252")
        case .jumpsFar: return NSColor(white: 1, alpha: 0.8)
        case .ship: return hex("#7FC8FF")
        case .pilot: return hex("#FFB870")
        case .count: return .white
        }
    }

    /// 一段文字的字重（8.4 节的表）。
    static func weight(for style: OverlaySpanStyle) -> NSFont.Weight {
        switch style {
        case .systemHigh, .systemLow, .systemNull, .systemUnknown, .clear, .jumpsMid: return .medium
        case .jumpsNear, .count: return .bold
        default: return .regular
        }
    }

    /// 时间文字用等宽数字，刷新时不左右跳动。
    static func usesMonospacedDigits(_ style: OverlaySpanStyle) -> Bool {
        style == .ageFresh || style == .ageRecent
    }

    /// 一段文字的字体。
    static func font(for style: OverlaySpanStyle, size: Double) -> NSFont {
        let size = CGFloat(size)
        let weight = weight(for: style)
        return usesMonospacedDigits(style)
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 把一条消息拼成富文本：第一行加（有第二行时）换行与第二行，按词折行。
    static func attributedText(for line: OverlayLine, fontSize: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString()
        append(line.primary, size: fontSize, paragraph: paragraph, to: text)
        if !line.secondary.isEmpty {
            let secondarySize = max(minimumSecondaryFontSize, fontSize - 1)
            text.append(NSAttributedString(string: "\n", attributes: attributes(.plain, size: secondarySize,
                                                                                 paragraph: paragraph)))
            append(line.secondary, size: secondarySize, paragraph: paragraph, to: text)
        }
        return text
    }

    /// 把各段按样式接到富文本后面。
    private static func append(_ spans: [OverlaySpan], size: Double, paragraph: NSParagraphStyle,
                               to text: NSMutableAttributedString) {
        for span in spans {
            text.append(NSAttributedString(string: span.text, attributes: attributes(span.style, size: size,
                                                                                     paragraph: paragraph)))
        }
    }

    /// 一段文字的属性：字体、颜色与段落样式。
    private static func attributes(_ style: OverlaySpanStyle, size: Double,
                                   paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: font(for: style, size: size), .foregroundColor: color(for: style), .paragraphStyle: paragraph]
    }

    // MARK: - 行与状态

    /// 一行的强调背景（8.4 节）：alert 是红色（0.22），clear 是绿色（0.12），none 没有背景。
    static func emphasisColor(_ emphasis: OverlayEmphasis) -> NSColor? {
        switch emphasis {
        case .none: return nil
        case .alert: return hex("#FF3B30", alpha: 0.22)
        case .clear: return hex("#34C759", alpha: 0.12)
        }
    }

    /// 状态行的颜色：info 是半透明的白色，warning 是黄色，error 是红色。
    static func statusColor(_ level: OverlayStatusLevel) -> NSColor {
        switch level {
        case .info: return NSColor(white: 1, alpha: 0.55)
        case .warning: return hex("#FFD166")
        case .error: return hex("#FF7A7A")
        }
    }

    /// 标题、说明与新消息条的文字颜色。
    static var titleColor: NSColor { NSColor(white: 1, alpha: 0.92) }

    /// 十六进制颜色；写错时取白色（表里的值都是固定的，不会写错）。
    private static func hex(_ value: String, alpha: CGFloat = 1) -> NSColor {
        NSColor(hex: value, alpha: alpha) ?? .white
    }
}
