// SPDX-License-Identifier: GPL-3.0-or-later
//
// 布局与吸附的补充用例（架构文档 5.4 节）。测试方于 2026-11-20 补写，
// 覆盖原有用例没有检查的边界：屏幕顺序、副屏下方的空白区、比屏幕大的矩形、只记录宽度的布局、
// 移动吸附的上下组合与「另一轴」阈值、缩放时左边与上边的吸附、拖角时宽高比与吸附的取舍、
// 8 种拖动边组合下对边保持不动、按下位置恰好在边距上的判定。期望值按规格文字手算。

import Testing
import EVEOPreviewCore

/// LayoutResolver 的边界用例。
struct LayoutResolverEdgeCaseTests {
    private let pilotA = Fixtures.character(Fixtures.pilotAlpha, id: 1, pid: 10)

    /// 用给定布局建一个配置方案。
    private func profile(_ layouts: [String: ThumbnailLayout] = [:]) -> Profile {
        Profile(name: "T", layouts: layouts)
    }

    /// 自动排位用 isMain 的屏幕，不取数组里的第一块：副屏排在前面时仍从主屏 (16, 49) 起排。
    @Test func autoPlacementUsesMainScreenNotFirst() {
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(),
                                          screens: [Fixtures.leftScreen, Fixtures.mainScreen], occupied: [])
        #expect(result == ResolvedLayout(frame: ScreenRect(x: 16, y: 49, width: 384, height: 216), isAutoPlaced: true))
    }

    /// 只与格子边缘相接、不相交的占用矩形不让出格子。
    @Test func touchingOccupiedRectDoesNotBlockCell() {
        let touching = ScreenRect(x: 400, y: 49, width: 100, height: 100)   // 左边正好在第一个格子的右边 x = 400
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(),
                                          screens: [Fixtures.mainScreen], occupied: [touching])
        #expect(result.frame.origin == ScreenPoint(x: 16, y: 49))
    }

    /// 只记录了宽度：高度用 defaultSize 的 216。
    @Test func widthOnlyRecord() {
        let layout = [Fixtures.pilotAlpha: ThumbnailLayout(x: 100, y: 200, width: 500, height: nil)]
        let result = LayoutResolver.frame(for: pilotA, loginIndex: 0, profile: profile(layout),
                                          screens: [Fixtures.mainScreen], occupied: [])
        #expect(result == ResolvedLayout(frame: ScreenRect(x: 100, y: 200, width: 500, height: 216), isAutoPlaced: false))
    }

    /// 登录客户端序号很大时层叠到屏幕外，被拉回主屏可用区域的右下角：
    /// (5 + 2400, 40 + 2400) → x = 1728 − 384 = 1344，y = 33 + 1084 − 216 = 901。
    @Test func largeLoginIndexPulledBack() {
        let login = Fixtures.client(5, pid: 50, .login)
        let result = LayoutResolver.frame(for: login, loginIndex: 100, profile: profile(),
                                          screens: [Fixtures.mainScreen], occupied: [])
        #expect(result.frame == ScreenRect(x: 1344, y: 901, width: 384, height: 216))
        #expect(!result.isAutoPlaced)
    }

    /// 负的序号按 0 处理。
    @Test func negativeLoginIndexTreatedAsZero() {
        let login = Fixtures.client(5, pid: 50, .login)
        let result = LayoutResolver.frame(for: login, loginIndex: -3, profile: profile(),
                                          screens: [Fixtures.mainScreen], occupied: [])
        #expect(result.frame.origin == ScreenPoint(x: 5, y: 40))
    }

    /// 登录位置在负坐标的副屏上时保持原位。
    @Test func loginPositionOnNegativeScreen() {
        var onLeft = profile()
        onLeft.loginPosition = ScreenPoint(x: -1900, y: 40)
        let login = Fixtures.client(5, pid: 50, .login)
        let result = LayoutResolver.frame(for: login, loginIndex: 1, profile: onLeft,
                                          screens: [Fixtures.mainScreen, Fixtures.leftScreen], occupied: [])
        #expect(result.frame.origin == ScreenPoint(x: -1876, y: 64))
    }

    /// 落在副屏下方空白区（副屏 1080 高，主屏 1117 高）的缩略图移回中心点最近的屏幕。
    /// 中心 (−308, 1198) 到副屏的距离是 118，到主屏是 √(308² + 81²) ≈ 318，所以移回副屏：
    /// x 保持 −500，y 夹到 1080 − 216 = 864。
    @Test func deadZoneBelowSecondaryScreen() {
        let rect = ScreenRect(x: -500, y: 1090, width: 384, height: 216)
        let result = LayoutResolver.clampToScreens(rect, screens: [Fixtures.mainScreen, Fixtures.leftScreen],
                                                   minimumVisible: 32)
        #expect(result == ScreenRect(x: -500, y: 864, width: 384, height: 216))
    }

    /// 横跨两块屏幕、每块上都露出足够多的缩略图不移动。
    @Test func straddlingTwoScreensStays() {
        let rect = ScreenRect(x: -200, y: 300, width: 384, height: 216)
        #expect(LayoutResolver.clampToScreens(rect, screens: [Fixtures.mainScreen, Fixtures.leftScreen],
                                              minimumVisible: 32) == rect)
    }

    /// 比屏幕还大的矩形移回时左上角对齐可用区域，尺寸不变。
    @Test func rectLargerThanScreen() {
        let rect = ScreenRect(x: 5000, y: 5000, width: 2000, height: 1500)
        let result = LayoutResolver.clampToScreens(rect, screens: [Fixtures.mainScreen], minimumVisible: 32)
        #expect(result == ScreenRect(x: 0, y: 33, width: 2000, height: 1500))
    }

    /// 宽高比无法与最小、最大尺寸同时满足时范围优先：比例 100 时宽封顶 960、高保底 108。
    @Test func clampSizeImpossibleRatio() {
        let size = LayoutResolver.clampSize(ScreenSize(width: 400, height: 400), settings: ThumbnailSettings(),
                                            aspectRatio: 100)
        #expect(size == ScreenSize(width: 960, height: 108))
    }
}

/// SnapEngine 的边界用例。
struct SnapEngineEdgeCaseTests {
    /// 邻居：x 400～700 之外的另一个缩略图，x 500～700，y 100～200。
    private let neighbor = ScreenRect(x: 500, y: 100, width: 200, height: 100)
    private let minimum = ScreenSize(width: 192, height: 108)
    private let maximum = ScreenSize(width: 960, height: 540)

    /// 只有一个邻居、没有屏幕的移动吸附。
    private func move(_ rect: ScreenRect) -> SnapResult {
        SnapEngine.snapMove(proposed: rect, targets: SnapTargets(neighbors: [neighbor], screens: []),
                            threshold: SnapEngine.defaultThreshold)
    }

    /// 缩放的简写，阈值 8，默认不带宽高比。
    private func resize(_ rect: ScreenRect, _ edges: ResizeEdges, _ targets: SnapTargets,
                        ratio: Double? = nil) -> SnapResult {
        SnapEngine.snapResize(proposed: rect, movingEdges: edges, targets: targets, threshold: 8,
                              minimum: minimum, maximum: maximum, aspectRatio: ratio)
    }

    // MARK: - 移动

    /// y 轴的 4 种组合：下对上、下对下、上对上（上对下已由原有用例覆盖）。
    @Test func verticalCombinations() {
        // 下边 95 贴邻居上边 100。
        let bottomToTop = move(ScreenRect(x: 520, y: 45, width: 100, height: 50))
        #expect(bottomToTop.rect.y == 50 && bottomToTop.snappedY == 100)
        // 下边 205 贴邻居下边 200。
        let bottomToBottom = move(ScreenRect(x: 520, y: 155, width: 100, height: 50))
        #expect(bottomToBottom.rect.y == 150 && bottomToBottom.snappedY == 200)
        // 上边 104 贴邻居上边 100。
        let topToTop = move(ScreenRect(x: 650, y: 104, width: 100, height: 50))
        #expect(topToTop.rect.origin == ScreenPoint(x: 650, y: 100) && topToTop.snappedY == 100)
    }

    /// 邻居在另一轴上的间隔恰好等于阈值时参与吸附，多 1 点就不参与。
    @Test func otherAxisGapBoundary() {
        // 在邻居下方 8 点：x 方向吸附到 700，y 方向的上边也在阈值内贴到 200。
        let near = move(ScreenRect(x: 705, y: 208, width: 100, height: 50))
        #expect(near.rect.origin == ScreenPoint(x: 700, y: 200))
        // 在邻居下方 9 点：x 方向不吸附，y 方向 9 点超出阈值也不吸附。
        let far = move(ScreenRect(x: 705, y: 209, width: 100, height: 50))
        #expect(far.rect.origin == ScreenPoint(x: 705, y: 209))
        #expect(far.snappedX == nil && far.snappedY == nil)
    }

    /// 吸附结果再吸附一次不变（位移为 0），拖动中反复调用不会漂移。
    @Test func snapIsStable() {
        let first = move(ScreenRect(x: 705, y: 120, width: 100, height: 50))
        let second = move(first.rect)
        #expect(second.rect == first.rect && second.snappedX == 700)
    }

    // MARK: - 缩放吸附

    /// 拖左边：左边 400 贴邻居右边 397，右边 700 不动。
    @Test func resizeLeftEdgeSnaps() {
        let line = ScreenRect(x: 300, y: 300, width: 97, height: 50)
        let r = resize(ScreenRect(x: 400, y: 300, width: 300, height: 150), .left,
                       SnapTargets(neighbors: [line], screens: []))
        #expect(r.rect == ScreenRect(x: 397, y: 300, width: 303, height: 150))
        #expect(r.snappedX == 397 && r.snappedY == nil)
    }

    /// 拖上边：上边 202 贴邻居下边 197，下边 352 不动。
    @Test func resizeTopEdgeSnaps() {
        let line = ScreenRect(x: 400, y: 100, width: 200, height: 97)
        let r = resize(ScreenRect(x: 400, y: 202, width: 300, height: 150), .top,
                       SnapTargets(neighbors: [line], screens: []))
        #expect(r.rect == ScreenRect(x: 400, y: 197, width: 300, height: 155))
        #expect(r.snappedY == 197 && r.snappedX == nil)
    }

    /// 拖下边：下边 455 贴邻居上边 460，上边 300 不动。
    @Test func resizeBottomEdgeSnaps() {
        let line = ScreenRect(x: 400, y: 460, width: 100, height: 50)
        let r = resize(ScreenRect(x: 400, y: 300, width: 300, height: 155), .bottom,
                       SnapTargets(neighbors: [line], screens: []))
        #expect(r.rect == ScreenRect(x: 400, y: 300, width: 300, height: 160))
        #expect(r.snappedY == 460)
    }

    /// 吸附后低于最小宽度：约束优先，宽度回到 192，对齐线作废。
    @Test func snapBelowMinimumDiscarded() {
        let screen = ScreenRect(x: 0, y: 0, width: 290, height: 1000)   // 右边 x = 290
        let r = resize(ScreenRect(x: 100, y: 100, width: 195, height: 150), .right,
                       SnapTargets(neighbors: [], screens: [screen]))
        #expect(r.rect == ScreenRect(x: 100, y: 100, width: 192, height: 150))
        #expect(r.snappedX == nil)
    }

    /// 拖右下角、两个方向都吸附、又锁定宽高比 2：结果满足比例，左边与上边不动；
    /// 报告的对齐线只能是结果真正落在上面的边。
    @Test func cornerSnapWithAspectRatio() {
        let screen = ScreenRect(x: 0, y: 0, width: 500, height: 305)   // 右边 500、下边 305
        let r = resize(ScreenRect(x: 100, y: 100, width: 397, height: 203), [.right, .bottom],
                       SnapTargets(neighbors: [], screens: [screen]), ratio: 2)
        #expect(r.rect.minX == 100 && r.rect.minY == 100)
        #expect(abs(r.rect.width / r.rect.height - 2) < 1e-9)
        if let x = r.snappedX { #expect(x == r.rect.minX || x == r.rect.maxX) }
        if let y = r.snappedY { #expect(y == r.rect.minY || y == r.rect.maxY) }
        // 实现的取法：拖角时以宽为准，宽 400 吸附成立，高按比例算出 200，下边的对齐作废。
        #expect(r.rect == ScreenRect(x: 100, y: 100, width: 400, height: 200))
        #expect(r.snappedX == 500 && r.snappedY == nil)
    }

    // MARK: - 8 种拖动边组合的对边不动

    /// 8 种拖动边组合（4 条边、4 个角），以原始值传入。
    static let edgeSets: [UInt8] = [1, 2, 4, 8, 1 | 4, 1 | 8, 2 | 4, 2 | 8]

    /// 缩到最小尺寸以下：没在拖的边保持原位，被拖方向的尺寸停在最小值，另一方向尺寸不变。
    @Test(arguments: edgeSets)
    func fixedEdgesHoldWhenShrinking(raw: UInt8) {
        let edges = ResizeEdges(rawValue: raw)
        let start = ScreenRect(x: 400, y: 400, width: 300, height: 200)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        // 横向往里拖 250（宽剩 50），纵向往里拖 150（高剩 50），都低于最小尺寸。
        if edges.contains(.left) { minX += 250 }
        if edges.contains(.right) { maxX -= 250 }
        if edges.contains(.top) { minY += 150 }
        if edges.contains(.bottom) { maxY -= 150 }
        let proposed = ScreenRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let r = resize(proposed, edges, .none).rect
        checkFixedEdges(r, start: start, edges: edges)
        let horizontal = !edges.isDisjoint(with: [.left, .right])
        let vertical = !edges.isDisjoint(with: [.top, .bottom])
        #expect(r.width == (horizontal ? 192 : 300))
        #expect(r.height == (vertical ? 108 : 200))
    }

    /// 放大到最大尺寸以上：没在拖的边保持原位，被拖方向的尺寸停在最大值。
    @Test(arguments: edgeSets)
    func fixedEdgesHoldWhenGrowing(raw: UInt8) {
        let edges = ResizeEdges(rawValue: raw)
        let start = ScreenRect(x: 400, y: 400, width: 300, height: 200)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX -= 1000 }
        if edges.contains(.right) { maxX += 1000 }
        if edges.contains(.top) { minY -= 1000 }
        if edges.contains(.bottom) { maxY += 1000 }
        let proposed = ScreenRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let r = resize(proposed, edges, .none).rect
        checkFixedEdges(r, start: start, edges: edges)
        let horizontal = !edges.isDisjoint(with: [.left, .right])
        let vertical = !edges.isDisjoint(with: [.top, .bottom])
        #expect(r.width == (horizontal ? 960 : 300))
        #expect(r.height == (vertical ? 540 : 200))
    }

    /// 没在拖的边与起点相同：拖左边时右边不动，拖右边时左边不动，上下同理；
    /// 某个方向一条边都没拖时，两条边都不动。
    private func checkFixedEdges(_ r: ScreenRect, start: ScreenRect, edges: ResizeEdges) {
        if !edges.contains(.left) { #expect(r.minX == start.minX, "左边应不动：\(edges.rawValue)") }
        if !edges.contains(.right) { #expect(r.maxX == start.maxX, "右边应不动：\(edges.rawValue)") }
        if !edges.contains(.top) { #expect(r.minY == start.minY, "上边应不动：\(edges.rawValue)") }
        if !edges.contains(.bottom) { #expect(r.maxY == start.maxY, "下边应不动：\(edges.rawValue)") }
    }

    // MARK: - 按下位置的判定

    /// 恰好在 12 点边距上算边缘，多 0.5 点不算；点在边线上也算。
    @Test func resizeEdgesMarginBoundary() {
        let rect = ScreenRect(x: 0, y: 0, width: 200, height: 100)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 12, y: 50), in: rect, margin: 12) == .left)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 12.5, y: 50), in: rect, margin: 12).isEmpty)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 0, y: 50), in: rect, margin: 12) == .left)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 200, y: 100), in: rect, margin: 12) == [.right, .bottom])
    }

    /// 很窄的矩形里点同时靠近左右两边时取更近的那条，距离相等时取左边。
    @Test func resizeEdgesNarrowRect() {
        let narrow = ScreenRect(x: 0, y: 0, width: 20, height: 100)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 8, y: 50), in: narrow, margin: 12) == .left)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 15, y: 50), in: narrow, margin: 12) == .right)
        #expect(SnapEngine.resizeEdges(at: ScreenPoint(x: 10, y: 50), in: narrow, margin: 12) == .left)
    }
}
