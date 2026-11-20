// SPDX-License-Identifier: GPL-3.0-or-later
//
// CaptureMath 的用例（架构文档 5.6 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 捕获规格与裁剪：像素换算、偶数取整、不超过源尺寸、标题栏裁剪。
struct CaptureMathTests {
    /// 默认缩略图在 Retina 屏上：宽 768 像素，高按源窗口 1728×1018 的比例算出并取偶数。
    @Test func pixelConversion() {
        let spec = CaptureMath.spec(thumbnailSize: ScreenSize(width: 384, height: 216),
                                    sourceSize: Fixtures.mainWindowSize, scale: 2, frameRate: 15)
        // 768 × 1018 ÷ 1728 = 452.4，向上取偶数是 454。
        #expect(spec == CaptureSpec(pixelWidth: 768, pixelHeight: 454, framesPerSecond: 15))
    }

    /// 奇数像素向上取到偶数。
    @Test func roundsUpToEven() {
        let spec = CaptureMath.spec(thumbnailSize: ScreenSize(width: 383, height: 200),
                                    sourceSize: ScreenSize(width: 1000, height: 500), scale: 1, frameRate: 30)
        #expect(spec.pixelWidth == 384)
        #expect(spec.pixelHeight == 192)
        #expect(spec.pixelWidth % 2 == 0 && spec.pixelHeight % 2 == 0)
    }

    /// 缩略图比源窗口大时，以源窗口的像素尺寸为上限。
    @Test func neverExceedsSource() {
        let spec = CaptureMath.spec(thumbnailSize: ScreenSize(width: 4000, height: 2000),
                                    sourceSize: Fixtures.mainWindowSize, scale: 2, frameRate: 15)
        #expect(spec.pixelWidth == 3456 && spec.pixelHeight == 2036)
    }

    /// 源像素尺寸是奇数时，上限向下取偶数。
    @Test func oddSourceLimit() {
        let spec = CaptureMath.spec(thumbnailSize: ScreenSize(width: 2000, height: 1000),
                                    sourceSize: ScreenSize(width: 1001, height: 501), scale: 1, frameRate: 15)
        #expect(spec.pixelWidth == 1000 && spec.pixelHeight == 500)
    }

    /// 帧率夹到 1～60；scale 无效时按 1；源尺寸无效时按缩略图比例。
    @Test func degenerateInputs() {
        let low = CaptureMath.spec(thumbnailSize: ScreenSize(width: 100, height: 50), sourceSize: .init(width: 0, height: 0),
                                   scale: 0, frameRate: 0)
        #expect(low == CaptureSpec(pixelWidth: 100, pixelHeight: 50, framesPerSecond: 1))
        let high = CaptureMath.spec(thumbnailSize: ScreenSize(width: 100, height: 50),
                                    sourceSize: ScreenSize(width: 1000, height: 500), scale: 1, frameRate: 120)
        #expect(high.framesPerSecond == 60)
    }

    /// 标题栏裁剪：从顶部裁掉 28 点，原点在左上角。
    @Test func titleBarCrop() {
        let rect = CaptureMath.contentsRect(sourceSize: Fixtures.mainWindowSize, titleBarCropHeight: 28)
        #expect(rect.x == 0 && rect.width == 1)
        #expect(abs(rect.y - 28.0 / 1018.0) < 1e-12)
        #expect(abs(rect.y + rect.height - 1) < 1e-12)
    }

    /// 不裁的情况：裁剪高度为 0、不小于源高度、源高度无效。
    @Test func noCrop() {
        #expect(CaptureMath.contentsRect(sourceSize: Fixtures.mainWindowSize, titleBarCropHeight: 0) == .full)
        #expect(CaptureMath.contentsRect(sourceSize: ScreenSize(width: 100, height: 20), titleBarCropHeight: 28) == .full)
        #expect(CaptureMath.contentsRect(sourceSize: ScreenSize(width: 100, height: 0), titleBarCropHeight: 28) == .full)
    }

    /// 全屏窗口（高度不小于所在屏幕高度）由规划器传 0，不裁。
    @Test func fullScreenWindowNotCroppedByPlanner() {
        let fullScreen = Fixtures.client(1, pid: 10, .character("A"),
                                         frame: ScreenRect(x: 0, y: 0, width: 1728, height: 1117))
        let windowed = Fixtures.client(2, pid: 11, .character("B"))
        let plan = ThumbnailPlanner.plan(Fixtures.plannerInput(clients: [fullScreen, windowed]))
        #expect(plan.presentations[0].contentsRect == .full)
        #expect(plan.presentations[1].contentsRect.y > 0)
    }
}
