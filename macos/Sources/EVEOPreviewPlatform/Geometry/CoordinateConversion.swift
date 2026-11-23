// SPDX-License-Identifier: GPL-3.0-or-later
//
// 坐标换算（架构文档 4.2 节）。Core 只用全局屏幕坐标：原点在主屏左上角，y 轴向下，
// 与 CGWindowList、AX、ScreenCaptureKit 一致；AppKit 的 NSWindow.frame 与 NSScreen.frame
// 以主屏左下角为原点、y 轴向上。整个项目只在本文件翻转 y 轴，其他文件不自己换算。

import AppKit
import EVEOPreviewCore

/// Core 坐标与 CoreGraphics、AppKit 坐标的互换。
public enum CoordinateConversion {
    /// 把 CGWindowList、AX 或 ScreenCaptureKit 给出的 `CGRect` 原样转成 Core 的矩形。
    /// 两者原点、方向相同（都是左上角、y 向下），只换类型。
    public static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: Double(rect.origin.x), y: Double(rect.origin.y),
                   width: Double(rect.size.width), height: Double(rect.size.height))
    }

    /// 把 Core 的矩形换成 AppKit 的 frame（左下角原点、y 向上）。
    ///
    /// - Parameters:
    ///   - rect: 全局屏幕坐标中的矩形。
    ///   - primaryScreenHeight: 主屏（`NSScreen.screens[0]`，原点所在的屏幕）的高度，单位是点。
    ///     两套坐标都以主屏为基准，所以只需要主屏的高度。
    public static func appKitFrame(_ rect: ScreenRect, primaryScreenHeight: Double) -> NSRect {
        // Core 的上边 y 对应 AppKit 的上边 primaryHeight - y；AppKit 的原点是下边，再减去高度。
        NSRect(x: rect.x, y: primaryScreenHeight - rect.y - rect.height,
               width: rect.width, height: rect.height)
    }

    /// 把 AppKit 的 frame 换成 Core 的矩形，是 `appKitFrame(_:primaryScreenHeight:)` 的逆运算。
    public static func screenRect(appKitFrame frame: NSRect, primaryScreenHeight: Double) -> ScreenRect {
        ScreenRect(x: Double(frame.origin.x),
                   y: primaryScreenHeight - Double(frame.origin.y) - Double(frame.size.height),
                   width: Double(frame.size.width), height: Double(frame.size.height))
    }

    /// 把 AppKit 的点（例如 `NSEvent.mouseLocation`）换成 Core 的点。
    public static func screenPoint(appKitPoint point: NSPoint, primaryScreenHeight: Double) -> ScreenPoint {
        ScreenPoint(x: Double(point.x), y: primaryScreenHeight - Double(point.y))
    }

    /// 当前主屏的高度，单位是点。没有屏幕（例如无头环境）时返回 0，此时换算结果只是平移。
    @MainActor public static var primaryScreenHeight: Double {
        // NSScreen.screens 的第一项固定是原点所在的主屏；NSScreen.main 是键盘焦点所在的屏幕，不能用。
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    /// 用当前主屏高度把 Core 的矩形换成 AppKit 的 frame。
    @MainActor public static func appKitFrame(_ rect: ScreenRect) -> NSRect {
        appKitFrame(rect, primaryScreenHeight: primaryScreenHeight)
    }

    /// 用当前主屏高度把 AppKit 的 frame 换成 Core 的矩形。
    @MainActor public static func screenRect(appKitFrame frame: NSRect) -> ScreenRect {
        screenRect(appKitFrame: frame, primaryScreenHeight: primaryScreenHeight)
    }

    /// 把一块 `NSScreen` 换成 Core 的屏幕描述。
    ///
    /// - Parameters:
    ///   - screen: 要换算的屏幕。
    ///   - isMain: 是否为主屏（`NSScreen.screens` 的第一项）。
    @MainActor public static func screenInfo(_ screen: NSScreen, isMain: Bool) -> ScreenInfo {
        let height = primaryScreenHeight
        return ScreenInfo(frame: screenRect(appKitFrame: screen.frame, primaryScreenHeight: height),
                          visibleFrame: screenRect(appKitFrame: screen.visibleFrame, primaryScreenHeight: height),
                          scale: Double(screen.backingScaleFactor), isMain: isMain)
    }
}
