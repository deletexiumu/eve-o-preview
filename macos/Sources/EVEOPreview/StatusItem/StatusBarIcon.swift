// SPDX-License-Identifier: GPL-3.0-or-later
//
// 菜单栏图标：八边形框里一个分子（沿用上游 EVE-O Preview 的分子图案）。应用图标另由 shared/branding/make-icons.py 生成。
//
// 用代码画矢量，不放图片资源：SwiftPM 的资源包放进手工组装的 .app 后查找路径有问题（架构文档 7.4 节），
// 矢量图在任何缩放比例下都清晰。图像标记为模板图（isTemplate），由系统按菜单栏的深浅色自动着色，
// 所以这里只用黑色加透明度绘制。
//
// v1.1（v1.1 设计 11.1 节）：`make(attention: true)` 在右上角画一个直径 5 点的实心圆点，
// 圆点周围清出 1 点宽的透明环，与八边形框分开，深浅色菜单栏上都看得清。

import AppKit

/// 生成菜单栏用的模板图标。
enum StatusBarIcon {
    /// 图标边长，单位是点。菜单栏图标的惯例高度是 18 点。
    static let side: CGFloat = 18

    /// 分子各原子的位置与半径，都按图标边长归一化（0～1，原点在左上角，y 轴向下）。
    /// 位置照上游分子图标的摆放：中心原子偏左上，右下是一个大原子，另有 4 个小原子。
    private static let center = (x: 0.45, y: 0.45, r: 0.12)
    private static let atoms: [(x: Double, y: Double, r: Double)] = [
        (0.36, 0.22, 0.085),   // 左上
        (0.68, 0.30, 0.075),   // 右上
        (0.22, 0.42, 0.075),   // 左
        (0.29, 0.68, 0.08),    // 左下
        (0.64, 0.68, 0.15),    // 右下的大原子
    ]

    /// 圆点的直径，单位是点。
    static let attentionDotDiameter: CGFloat = 5
    /// 圆点外围清出的透明环的宽度，单位是点。
    static let attentionDotGap: CGFloat = 1

    /// 生成图标。每次调用都返回新的 NSImage；绘制在 drawingHandler 里按需进行，适配 Retina。
    ///
    /// - Parameter attention: 为真时在右上角画圆点（`AppCoordinator.attention` 不为空）。
    static func make(attention: Bool = false) -> NSImage {
        let size = NSSize(width: side, height: side)
        // flipped 为 true：绘制坐标原点在左上角，与上面的归一化坐标一致。
        let image = NSImage(size: size, flipped: true) { rect in
            draw(in: rect)
            if attention { drawAttentionDot(in: rect) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.appName
        return image
    }

    /// 在右上角画圆点：先清出比圆点大一圈的透明区域，再画实心圆。
    private static func drawAttentionDot(in rect: NSRect) {
        let d = attentionDotDiameter
        let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
        let gap = dot.insetBy(dx: -attentionDotGap, dy: -attentionDotGap)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: gap).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// 在给定矩形里画八边形框与分子。
    private static func draw(in rect: NSRect) {
        let s = Double(rect.width)
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // 八边形框：正八边形，边与坐标轴平行，线宽 1.4 点。
        let lineWidth = 1.4
        let radius = s / 2 - lineWidth / 2 - 0.3
        let octagon = NSBezierPath()
        for i in 0..<8 {
            // 起始角 22.5 度，让上下左右各有一条水平或竖直的边。
            let angle = (22.5 + 45.0 * Double(i)) * .pi / 180
            let point = NSPoint(x: s / 2 + radius * cos(angle), y: s / 2 + radius * sin(angle))
            if i == 0 { octagon.move(to: point) } else { octagon.line(to: point) }
        }
        octagon.close()
        octagon.lineWidth = lineWidth
        octagon.lineJoinStyle = .round
        octagon.stroke()

        // 化学键：从中心原子连到每个原子的线段，线宽 1.1 点。
        let bonds = NSBezierPath()
        bonds.lineWidth = 1.1
        bonds.lineCapStyle = .round
        for atom in atoms {
            bonds.move(to: NSPoint(x: center.x * s, y: center.y * s))
            bonds.line(to: NSPoint(x: atom.x * s, y: atom.y * s))
        }
        bonds.stroke()

        // 原子：实心圆。中心原子与各原子都画满，靠模板图着色。
        for atom in atoms + [center] {
            let r = atom.r * s
            NSBezierPath(ovalIn: NSRect(x: atom.x * s - r, y: atom.y * s - r, width: 2 * r, height: 2 * r)).fill()
        }
    }
}
