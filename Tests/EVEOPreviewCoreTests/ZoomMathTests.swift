// SPDX-License-Identifier: GPL-3.0-or-later
//
// ZoomMath 的用例（架构文档 5.4 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 悬停放大：9 个锚点各一例。基准 (100, 100, 200, 100)，放大 2 倍后是 400×200。
struct ZoomMathTests {
    private static let base = ScreenRect(x: 100, y: 100, width: 200, height: 100)

    /// 每个锚点放大后的左上角。
    private static let expectedOrigins: [(ZoomAnchor, ScreenPoint)] = [
        (.nw, ScreenPoint(x: 100, y: 100)), (.n, ScreenPoint(x: 0, y: 100)), (.ne, ScreenPoint(x: -100, y: 100)),
        (.w, ScreenPoint(x: 100, y: 50)), (.center, ScreenPoint(x: 0, y: 50)), (.e, ScreenPoint(x: -100, y: 50)),
        (.sw, ScreenPoint(x: 100, y: 0)), (.s, ScreenPoint(x: 0, y: 0)), (.se, ScreenPoint(x: -100, y: 0)),
    ]

    /// 锚点指定的点保持不动，宽高乘以倍数。
    @Test(arguments: ZoomAnchor.allCases)
    func anchorStaysFixed(anchor: ZoomAnchor) throws {
        let zoomed = ZoomMath.zoomedFrame(base: Self.base, factor: 2, anchor: anchor)
        let expected = try #require(Self.expectedOrigins.first { $0.0 == anchor }?.1)
        #expect(zoomed == ScreenRect(origin: expected, size: ScreenSize(width: 400, height: 200)))
    }

    /// 放大不受最大尺寸限制；倍数不大于 1 时原样返回。
    @Test func factorEdgeCases() {
        let big = ZoomMath.zoomedFrame(base: ScreenRect(x: 0, y: 0, width: 960, height: 540), factor: 10, anchor: .nw)
        #expect(big.size == ScreenSize(width: 9600, height: 5400))
        #expect(ZoomMath.zoomedFrame(base: Self.base, factor: 1, anchor: .center) == Self.base)
    }
}
