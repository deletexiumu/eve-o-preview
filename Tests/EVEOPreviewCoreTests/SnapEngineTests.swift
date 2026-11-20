// SPDX-License-Identifier: GPL-3.0-or-later
//
// SnapEngine 的用例（架构文档 5.4 节、10.2 节）。
// 邻居 N 位于 (500, 100)，200×100；屏幕是 (0, 0, 1728, 1117)；阈值 8 点。

import Testing
import EVEOPreviewCore

/// 吸附：4 种边组合、阈值、最近者、远处不吸附、屏幕边、缩放与约束。
struct SnapEngineTests {
    private let neighbor = ScreenRect(x: 500, y: 100, width: 200, height: 100)
    private let screen = ScreenRect(x: 0, y: 0, width: 1728, height: 1117)
    private var targets: SnapTargets { SnapTargets(neighbors: [neighbor], screens: [screen]) }
    private let minimum = ScreenSize(width: 192, height: 108)
    private let maximum = ScreenSize(width: 960, height: 540)

    /// 移动吸附的简写。
    private func move(_ rect: ScreenRect, _ t: SnapTargets? = nil) -> SnapResult {
        SnapEngine.snapMove(proposed: rect, targets: t ?? targets, threshold: SnapEngine.defaultThreshold)
    }

    /// 左对右：左边贴到邻居右边。
    @Test func leftToRight() {
        let r = move(ScreenRect(x: 705, y: 120, width: 100, height: 50))
        #expect(r.rect.x == 700 && r.snappedX == 700 && r.rect.y == 120 && r.snappedY == nil)
    }

    /// 右对左：右边贴到邻居左边。
    @Test func rightToLeft() {
        let r = move(ScreenRect(x: 395, y: 120, width: 100, height: 50))
        #expect(r.rect.x == 400 && r.snappedX == 500)
    }

    /// 左对左：在邻居下方 5 点处，左边对齐邻居左边，上边贴邻居下边。
    @Test func leftToLeft() {
        let r = move(ScreenRect(x: 504, y: 205, width: 100, height: 50))
        #expect(r.rect.origin == ScreenPoint(x: 500, y: 200))
        #expect(r.snappedX == 500 && r.snappedY == 200)
    }

    /// 右对右：右边对齐邻居右边。
    @Test func rightToRight() {
        let r = move(ScreenRect(x: 605, y: 205, width: 100, height: 50))
        #expect(r.rect.x == 600 && r.snappedX == 700)
    }

    /// 阈值内吸附，阈值外不动；恰好在阈值上算阈值内。
    @Test func thresholdBoundary() {
        #expect(move(ScreenRect(x: 708, y: 120, width: 100, height: 50)).rect.x == 700)
        let outside = move(ScreenRect(x: 709, y: 120, width: 100, height: 50))
        #expect(outside.rect.x == 709 && outside.snappedX == nil)
    }

    /// 多个目标都在阈值内时取最近的。
    @Test func nearestWins() {
        let closer = ScreenRect(x: 0, y: 300, width: 703, height: 20)
        let t = SnapTargets(neighbors: [neighbor, closer], screens: [screen])
        let r = move(ScreenRect(x: 705, y: 200, width: 100, height: 105), t)
        #expect(r.rect.x == 703 && r.snappedX == 703)
    }

    /// 远处的行不参与 x 方向吸附：邻居在 y 方向离得远时，x 坐标不对齐。
    @Test func distantRowIgnored() {
        let far = ScreenRect(x: 500, y: 900, width: 200, height: 100)
        let r = move(ScreenRect(x: 705, y: 120, width: 100, height: 50), SnapTargets(neighbors: [far], screens: [screen]))
        #expect(r.rect.x == 705 && r.snappedX == nil)
    }

    /// 屏幕的边始终参与，左右两侧都能吸附。
    @Test func screenEdges() {
        let left = move(ScreenRect(x: 5, y: 600, width: 100, height: 50), SnapTargets.none)
        #expect(left.rect.x == 5)   // 没有目标时不动
        let t = SnapTargets(neighbors: [], screenInfos: [Fixtures.mainScreen])
        #expect(move(ScreenRect(x: 5, y: 600, width: 100, height: 50), t).rect.x == 0)
        #expect(move(ScreenRect(x: 1625, y: 600, width: 100, height: 50), t).rect.x == 1628)
        // visibleFrame 的上边（菜单栏下方 33 点）也是目标。
        #expect(move(ScreenRect(x: 900, y: 38, width: 100, height: 50), t).rect.y == 33)
    }

    /// 缩放只动被拖动的边：拖右边时左边即使靠近目标也不动。
    @Test func resizeMovesOnlyDraggedEdge() {
        let leftLine = ScreenRect(x: 300, y: 300, width: 97, height: 50)     // 右边在 x = 397
        let rightLine = ScreenRect(x: 608, y: 300, width: 50, height: 50)   // 左边在 x = 608
        let t = SnapTargets(neighbors: [leftLine, rightLine], screens: [])
        let r = SnapEngine.snapResize(proposed: ScreenRect(x: 400, y: 300, width: 203, height: 150), movingEdges: .right,
                                      targets: t, threshold: 8, minimum: minimum, maximum: maximum, aspectRatio: nil)
        #expect(r.rect == ScreenRect(x: 400, y: 300, width: 208, height: 150))
        #expect(r.snappedX == 608)
    }

    /// 约束优先于吸附：吸附后超过最大宽度时夹回，对齐线作废。
    @Test func constraintsBeatSnapping() {
        let line = ScreenRect(x: 1368, y: 300, width: 50, height: 50)
        let r = SnapEngine.snapResize(proposed: ScreenRect(x: 400, y: 300, width: 963, height: 150), movingEdges: .right,
                                      targets: SnapTargets(neighbors: [line], screens: []), threshold: 8,
                                      minimum: minimum, maximum: maximum, aspectRatio: nil)
        #expect(r.rect == ScreenRect(x: 400, y: 300, width: 960, height: 150))
        #expect(r.snappedX == nil)
    }

    /// 拖左边缩到最小宽度以下：右边与下边保持不动。
    @Test func leftDragHitsMinimum() {
        let r = SnapEngine.snapResize(proposed: ScreenRect(x: 250, y: 100, width: 50, height: 200), movingEdges: .left,
                                      targets: .none, threshold: 8, minimum: minimum, maximum: maximum, aspectRatio: nil)
        #expect(r.rect.maxX == 300 && r.rect.maxY == 300)
        #expect(r.rect.width == 192 && r.rect.x == 108)
    }

    /// 拖左上角缩到最小尺寸以下：右边与下边保持不动。
    @Test func topLeftDragHitsMinimum() {
        let r = SnapEngine.snapResize(proposed: ScreenRect(x: 280, y: 280, width: 20, height: 20),
                                      movingEdges: [.left, .top], targets: .none, threshold: 8,
                                      minimum: minimum, maximum: maximum, aspectRatio: nil)
        #expect(r.rect == ScreenRect(x: 108, y: 192, width: 192, height: 108))
    }

    /// 宽高比：拖右边时以宽算高（上边固定）；拖下边时以高算宽（左边固定）。
    @Test func aspectRatio() {
        let byWidth = SnapEngine.snapResize(proposed: ScreenRect(x: 100, y: 100, width: 300, height: 100), movingEdges: .right,
                                            targets: .none, threshold: 8, minimum: minimum, maximum: maximum,
                                            aspectRatio: 2)
        #expect(byWidth.rect == ScreenRect(x: 100, y: 100, width: 300, height: 150))
        let byHeight = SnapEngine.snapResize(proposed: ScreenRect(x: 100, y: 100, width: 200, height: 150),
                                             movingEdges: .bottom, targets: .none, threshold: 8,
                                             minimum: minimum, maximum: maximum, aspectRatio: 2)
        #expect(byHeight.rect == ScreenRect(x: 100, y: 100, width: 300, height: 150))
    }

    /// 宽高比与最大尺寸冲突：按比例缩到范围内，拖上边时下边固定。
    @Test func aspectRatioWithinLimits() {
        let r = SnapEngine.snapResize(proposed: ScreenRect(x: 100, y: 0, width: 400, height: 700), movingEdges: .top,
                                      targets: .none, threshold: 8, minimum: minimum, maximum: maximum, aspectRatio: 1)
        #expect(r.rect == ScreenRect(x: 100, y: 160, width: 540, height: 540))
    }

    /// 由按下位置判断缩放的边或角；点在矩形外时为空。
    @Test func resizeEdgesHitTest() {
        let rect = ScreenRect(x: 0, y: 0, width: 200, height: 100)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 5, y: 50), in: rect, margin: 12) == .left)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 195, y: 95), in: rect, margin: 12) == [.right, .bottom])
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 10, y: 3), in: rect, margin: 12) == [.left, .top])
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 100, y: 50), in: rect, margin: 12).isEmpty)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: -5, y: 50), in: rect, margin: 12).isEmpty)
    }
}
