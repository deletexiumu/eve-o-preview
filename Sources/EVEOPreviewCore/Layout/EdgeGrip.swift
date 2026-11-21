// SPDX-License-Identifier: GPL-3.0-or-later
//
// 不带修饰键的左键在缩略图、浮窗边缘拖动缩放（v1.2.1，用户反馈「鼠标放到窗口边缘时能够拖拽缩放」）。
//
// 右键拖动与 Option+左键拖动沿用 SnapEngine.resizeEdges 的 12 点边缘；不带修饰键的左键在缩略图上是「切换」，
// 在浮窗上要留给滚动条，所以只认更窄的边缘带（默认 6 点）。命中边缘带之后，再按 14 点的角区判断是
// 单条边还是角，这样角上的命中范围比边缘带宽一些，更容易抓住。
//
// 本文件只做纯计算，供 App 层的手势状态机（ThumbnailInteraction、OverlayInteraction）与光标显示共用，
// 方便在 Core 里单元测试。坐标都是 Core 坐标（原点在主屏左上角，y 轴向下）。

import Foundation

/// 不带修饰键的左键的边缘判断。
public enum EdgeGrip {
    /// 边缘带的宽度，单位是点：点到某条边的距离不超过它时算抓住边缘。
    public static let bandWidth = 6.0
    /// 角区沿边的长度，单位是点：抓住边缘后，离相邻边也在这个距离内时算抓住角。
    public static let cornerLength = 14.0

    /// 左键按下时该做什么。
    public enum PlainPress: Sendable, Equatable {
        /// 普通点击：缩略图切换客户端，浮窗交还给面板（滚动条等）。
        case click
        /// 按在边缘带上：拖动超过阈值后缩放这些边。
        case resize(ResizeEdges)
    }

    /// 点落在哪些边的边缘带上；不在边缘带内（或不在矩形内）时为空。
    ///
    /// - 边缘带收窄到矩形短边的 1/4 以内、角区收窄到 1/3 以内：很小的矩形中间总留着能点击的区域。
    /// - 先判断离最近的边是否不超过 band，命中后交给 SnapEngine.resizeEdges 按 corner 判角。
    ///
    /// - Parameters:
    ///   - point: 鼠标位置。
    ///   - rect: 面板实际显示的 frame（悬停放大时是放大后的）。
    ///   - band: 边缘带宽度。
    ///   - corner: 角区长度。
    public static func edges(at point: ScreenPoint, in rect: ScreenRect,
                             band: Double = bandWidth, corner: Double = cornerLength) -> ResizeEdges {
        let shortSide = min(rect.width, rect.height)
        guard shortSide > 0, point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else { return [] }
        let effectiveBand = min(band, shortSide / 4)
        // 点到四条边的最短距离。
        let nearest = min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
        guard nearest <= effectiveBand else { return [] }
        // 角区不小于边缘带，否则贴边的点会判不出那条边。
        let effectiveCorner = max(effectiveBand, min(corner, shortSide / 3))
        return SnapEngine.resizeEdges(at: point, in: rect, margin: effectiveCorner)
    }

    /// 不带修饰键的左键按下时的决定：布局锁定或不允许缩放时总是普通点击；否则按在边缘带上时缩放。
    ///
    /// - Parameters:
    ///   - point: 按下的位置。
    ///   - rect: 面板实际显示的 frame。
    ///   - allowsResize: 是否允许缩放（登录客户端的缩略图不允许）。
    ///   - isLocked: 布局是否已锁定。
    public static func plainPress(at point: ScreenPoint, in rect: ScreenRect,
                                  allowsResize: Bool, isLocked: Bool) -> PlainPress {
        guard allowsResize, !isLocked else { return .click }
        let hit = edges(at: point, in: rect)
        return hit.isEmpty ? .click : .resize(hit)
    }
}
