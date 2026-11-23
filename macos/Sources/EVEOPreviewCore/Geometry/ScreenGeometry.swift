// SPDX-License-Identifier: GPL-3.0-or-later
//
// Core 的几何类型。全部使用全局屏幕坐标：单位是点，原点在主屏左上角，y 轴向下，
// 与 CGWindowList、AX、ScreenCaptureKit 的窗口坐标一致（见架构文档 4.2 节）。
// 这里不引用 CoreGraphics，Platform 负责与 CGRect、AppKit frame 互换。

import Foundation

/// 全局屏幕坐标中的一个点，单位是点。
///
/// 原点在主屏左上角，y 轴向下；副屏在主屏左侧或上方时坐标可以是负数。
public struct ScreenPoint: Sendable, Hashable, Codable {
    /// 水平坐标，单位是点。
    public var x: Double
    /// 垂直坐标，单位是点，向下为正。
    public var y: Double

    /// 用水平、垂直坐标建一个点。
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 解码时缺失的键取 0，保证旧配置或手改的配置能读出来。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
    }
}

/// 一个尺寸，单位是点。宽高可以是 0，负数没有意义，由调用方夹取。
public struct ScreenSize: Sendable, Hashable, Codable {
    /// 宽度，单位是点。
    public var width: Double
    /// 高度，单位是点。
    public var height: Double

    /// 用宽、高建一个尺寸。
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// 解码时缺失的键取 0；越界值由 `ConfigValidator` 改正。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
    }

    /// 宽高比（宽 ÷ 高）。高度不大于 0 时返回 nil，避免除零。
    public var aspectRatio: Double? {
        height > 0 ? width / height : nil
    }
}

/// 全局屏幕坐标中的矩形，(x, y) 是左上角，单位是点。
///
/// JSON 键名固定为 `x`、`y`、`width`、`height`，不用 CGRect 默认的嵌套数组格式。
public struct ScreenRect: Sendable, Hashable, Codable {
    /// 左边的 x 坐标。
    public var x: Double
    /// 上边的 y 坐标（y 轴向下，所以是最小的 y）。
    public var y: Double
    /// 宽度，单位是点。
    public var width: Double
    /// 高度，单位是点。
    public var height: Double

    /// 用左上角与宽高建一个矩形。
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 用左上角与尺寸建一个矩形。
    public init(origin: ScreenPoint, size: ScreenSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// 解码时缺失的键取 0。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
    }
}

// MARK: - 边与派生量

extension ScreenRect {
    /// 左边的 x 坐标，同 `x`。
    public var minX: Double { x }
    /// 右边的 x 坐标。
    public var maxX: Double { x + width }
    /// 上边的 y 坐标，同 `y`。
    public var minY: Double { y }
    /// 下边的 y 坐标（y 轴向下，所以是最大的 y）。
    public var maxY: Double { y + height }
    /// 水平中点。
    public var midX: Double { x + width / 2 }
    /// 垂直中点。
    public var midY: Double { y + height / 2 }
    /// 左上角。
    public var origin: ScreenPoint { ScreenPoint(x: x, y: y) }
    /// 尺寸。
    public var size: ScreenSize { ScreenSize(width: width, height: height) }
    /// 中心点。
    public var center: ScreenPoint { ScreenPoint(x: midX, y: midY) }
    /// 面积，单位是平方点；宽或高不大于 0 时为 0。
    public var area: Double { max(width, 0) * max(height, 0) }
    /// 宽或高不大于 0 时为真。
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

// MARK: - 运算

extension ScreenRect {
    /// 两个矩形的交集。不相交或只共享一条边时返回 nil。
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        let left = max(minX, other.minX)
        let right = min(maxX, other.maxX)
        let top = max(minY, other.minY)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return ScreenRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 两个矩形是否有面积大于 0 的重叠。只共享一条边不算相交。
    public func intersects(_ other: ScreenRect) -> Bool {
        intersection(other) != nil
    }

    /// 点是否落在矩形内。左边、上边算在内，右边、下边不算，与像素网格的惯例一致。
    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// 平移后的矩形，尺寸不变。
    public func offsetBy(dx: Double, dy: Double) -> ScreenRect {
        ScreenRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// 以给定点为不动点，宽高同时乘以 factor。
    ///
    /// - Parameters:
    ///   - factor: 放大倍数；小于 1 时为缩小。
    ///   - anchor: 不动点在矩形内的相对位置，(0, 0) 是左上角，(1, 1) 是右下角。
    public func scaled(by factor: Double, anchor: (x: Double, y: Double)) -> ScreenRect {
        let newWidth = width * factor
        let newHeight = height * factor
        // 不动点的绝对坐标在缩放前后相同，由此反推新的左上角。
        let fixedX = x + width * anchor.x
        let fixedY = y + height * anchor.y
        return ScreenRect(x: fixedX - newWidth * anchor.x, y: fixedY - newHeight * anchor.y,
                          width: newWidth, height: newHeight)
    }
}

/// 归一化矩形，各分量在 0～1 之间，用于 `CALayer.contentsRect`。
///
/// 约定：原点在画面左上角，y 轴向下，与 Core 的屏幕坐标同向。
/// App 设置 `contentsRect` 前，应按图层的坐标系自行换算（macOS 的 CALayer 默认 y 轴向上）。
public struct UnitRect: Sendable, Hashable {
    /// 左边，0 表示画面左边缘。
    public var x: Double
    /// 上边，0 表示画面上边缘。
    public var y: Double
    /// 宽度占画面宽度的比例。
    public var width: Double
    /// 高度占画面高度的比例。
    public var height: Double

    /// 用归一化的左上角与宽高建一个矩形。
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 整个画面：(0, 0, 1, 1)。
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
}

/// 一块显示器的几何信息，坐标是全局屏幕坐标。
public struct ScreenInfo: Sendable, Hashable {
    /// 整块屏幕的范围。
    public var frame: ScreenRect
    /// 去掉菜单栏与程序坞后的可用范围。
    public var visibleFrame: ScreenRect
    /// 每点对应的像素数（Retina 屏为 2.0）。
    public var scale: Double
    /// 是否为主屏（原点所在的屏幕）。
    public var isMain: Bool

    /// 用屏幕范围、可用范围、缩放系数与是否主屏建一个屏幕描述。
    public init(frame: ScreenRect, visibleFrame: ScreenRect, scale: Double, isMain: Bool) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isMain = isMain
    }
}

extension Array where Element == ScreenInfo {
    /// 主屏；没有标记为主屏的屏幕时取第一块，空数组返回 nil。
    public var mainScreen: ScreenInfo? {
        first(where: \.isMain) ?? first
    }

    /// 包含该点的屏幕；点不在任何屏幕内时返回 nil。
    public func screen(containing point: ScreenPoint) -> ScreenInfo? {
        first { $0.frame.contains(point) }
    }
}
