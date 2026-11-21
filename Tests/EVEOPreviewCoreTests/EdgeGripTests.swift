// SPDX-License-Identifier: GPL-3.0-or-later
//
// EdgeGrip 的用例：不带修饰键的左键在缩略图、浮窗边缘拖动缩放（v1.2.1）。
// 坐标是 Core 坐标（y 轴向下），矩形 (100, 100, 400, 200) 的边是 x=100、x=500、y=100、y=300。

import Testing
import EVEOPreviewCore

/// 边缘带的命中、角的判断与按下时的决定。
struct EdgeGripTests {
    /// 测试用的矩形。
    private let rect = ScreenRect(x: 100, y: 100, width: 400, height: 200)

    /// 便于书写的点。
    private func point(_ x: Double, _ y: Double) -> ScreenPoint {
        ScreenPoint(x: x, y: y)
    }

    /// 边缘带的边界：离左边 6 点命中，6.5 点不命中；四条边都一样。
    @Test func bandBoundary() {
        #expect(EdgeGrip.edges(at: point(106, 200), in: rect) == .left)
        #expect(EdgeGrip.edges(at: point(106.5, 200), in: rect).isEmpty)
        #expect(EdgeGrip.edges(at: point(495, 200), in: rect) == .right)
        #expect(EdgeGrip.edges(at: point(300, 104), in: rect) == .top)
        #expect(EdgeGrip.edges(at: point(300, 300), in: rect) == .bottom)
    }

    /// 矩形外的点不命中，即使离边很近。
    @Test func outsideIsEmpty() {
        #expect(EdgeGrip.edges(at: point(99, 200), in: rect).isEmpty)
        #expect(EdgeGrip.edges(at: point(300, 301), in: rect).isEmpty)
    }

    /// 命中边缘带后，离相邻边也在 14 点内时是角；两边都远于 6 点时不算命中，即使在 14 点内。
    @Test func cornerUsesLongerLength() {
        #expect(EdgeGrip.edges(at: point(103, 110), in: rect) == [.left, .top])
        #expect(EdgeGrip.edges(at: point(497, 298), in: rect) == [.right, .bottom])
        #expect(EdgeGrip.edges(at: point(110, 110), in: rect).isEmpty)
        // 离上边 20 点：只是左边，不是角。
        #expect(EdgeGrip.edges(at: point(103, 120), in: rect) == .left)
    }

    /// 很小的矩形：边缘带收窄到短边的 1/4，中心总是普通点击。
    @Test func tinyRectKeepsCenterClickable() {
        let tiny = ScreenRect(x: 0, y: 0, width: 16, height: 16)
        #expect(EdgeGrip.edges(at: point(8, 8), in: tiny).isEmpty)
        #expect(EdgeGrip.edges(at: point(3, 8), in: tiny) == .left)
        #expect(EdgeGrip.edges(at: point(5, 8), in: tiny).isEmpty)
        #expect(EdgeGrip.edges(at: point(1, 1), in: ScreenRect(x: 0, y: 0, width: 0, height: 10)).isEmpty)
    }

    /// 按下时的决定：锁定或不允许缩放时总是点击；允许时边缘带上是缩放，中间是点击。
    @Test func plainPressDecision() {
        let edge = point(102, 200)
        #expect(EdgeGrip.plainPress(at: edge, in: rect, allowsResize: true, isLocked: false) == .resize(.left))
        #expect(EdgeGrip.plainPress(at: edge, in: rect, allowsResize: true, isLocked: true) == .click)
        #expect(EdgeGrip.plainPress(at: edge, in: rect, allowsResize: false, isLocked: false) == .click)
        #expect(EdgeGrip.plainPress(at: point(300, 200), in: rect, allowsResize: true, isLocked: false) == .click)
    }
}
