// SPDX-License-Identifier: GPL-3.0-or-later
//
// 捕获规格与画面裁剪的计算（架构文档 5.6 节、6.3 节）。
// 捕获分辨率跟随缩略图而不跟随源窗口，以降低能耗。

import Foundation

/// 捕获相关的换算。
public enum CaptureMath {
    /// 由缩略图尺寸算出捕获规格。
    ///
    /// - 宽是 `缩略图宽 × scale`，高按源窗口的宽高比算出；两者都不超过源窗口的像素尺寸
    ///   （`源窗口点数 × scale`），且都向上取到偶数（超过源像素尺寸时改为向下取偶数），至少为 2。
    /// - 源窗口尺寸无效（宽或高不大于 0）时，改用缩略图的宽高比，也不做源尺寸上限。
    /// - 帧率夹到 1～60。
    ///
    /// - Parameters:
    ///   - thumbnailSize: 缩略图尺寸（已含悬停放大），单位是点。
    ///   - sourceSize: 源窗口尺寸，单位是点。
    ///   - scale: 缩略图所在屏幕的 scale；不是正数时按 1 处理。
    ///   - frameRate: 期望帧率，单位是帧每秒。
    public static func spec(thumbnailSize: ScreenSize, sourceSize: ScreenSize, scale: Double,
                            frameRate: Int) -> CaptureSpec {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        let sourceValid = sourceSize.width > 0 && sourceSize.height > 0
        let ratio: Double   // 高 ÷ 宽
        if sourceValid {
            ratio = sourceSize.height / sourceSize.width
        } else if thumbnailSize.width > 0, thumbnailSize.height > 0 {
            ratio = thumbnailSize.height / thumbnailSize.width
        } else {
            ratio = 9.0 / 16.0
        }
        // 源窗口的像素上限；源尺寸无效时不设上限。
        let maxWidth = sourceValid ? sourceSize.width * factor : .infinity
        let maxHeight = sourceValid ? sourceSize.height * factor : .infinity

        var width = min(max(thumbnailSize.width, 0) * factor, maxWidth)
        var height = width * ratio
        if height > maxHeight {
            height = maxHeight
            width = height / ratio
        }
        return CaptureSpec(pixelWidth: evenPixels(width, limit: maxWidth),
                           pixelHeight: evenPixels(height, limit: maxHeight),
                           framesPerSecond: min(max(frameRate, 1), 60))
    }

    /// 从画面顶部裁掉 titleBarCropHeight 点后的显示范围。
    ///
    /// 返回值的原点在画面左上角、y 轴向下（见 `UnitRect`）。裁剪高度不是正数、
    /// 源高度无效，或裁剪高度不小于源高度时返回整个画面。
    /// 「全屏窗口不裁」由调用方判断后传 0（规划器按源窗口高度不小于所在屏幕高度判断）。
    public static func contentsRect(sourceSize: ScreenSize, titleBarCropHeight: Double) -> UnitRect {
        guard titleBarCropHeight > 0, sourceSize.height > 0, titleBarCropHeight < sourceSize.height else {
            return .full
        }
        let top = titleBarCropHeight / sourceSize.height
        return UnitRect(x: 0, y: top, width: 1, height: 1 - top)
    }

    /// 向上取偶数；超过 limit 时改为 limit 向下取偶数；结果至少为 2。
    ///
    /// 先减去一个极小量再取整，避免 768.0000001 这类浮点误差被进位成 770。
    private static func evenPixels(_ value: Double, limit: Double) -> Int {
        let tolerance = 1e-6
        // NaN 或无穷大不能转成 Int，直接给最小值。
        guard value.isFinite else { return 2 }
        var result = (value / 2 - tolerance).rounded(.up) * 2
        if result > limit + tolerance {
            result = (limit / 2 + tolerance).rounded(.down) * 2
        }
        return max(2, Int(result))
    }
}
