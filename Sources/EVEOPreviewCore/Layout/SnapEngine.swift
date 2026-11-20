// SPDX-License-Identifier: GPL-3.0-or-later
//
// 拖动与缩放时的吸附（架构文档 5.4 节）。
// proposed 由「拖动起点的 frame + 鼠标的原始位移」算出，不由上一次吸附结果累加，
// 所以鼠标移出阈值后缩略图自然脱离，不需要额外状态。

import Foundation

/// 吸附目标：其他缩略图与屏幕。
public struct SnapTargets: Sendable, Equatable {
    /// 其他可见缩略图的 frame（不含正在拖动的这一个）。
    public var neighbors: [ScreenRect]
    /// 每块屏幕的 frame 与 visibleFrame，各作为一个矩形。
    public var screens: [ScreenRect]

    /// 用邻居与屏幕矩形建吸附目标。
    public init(neighbors: [ScreenRect], screens: [ScreenRect]) {
        self.neighbors = neighbors
        self.screens = screens
    }

    /// 没有任何目标。按住 Shift 绕过吸附、但仍要应用尺寸约束时，把它传给 `snapResize`。
    public static let none = SnapTargets(neighbors: [], screens: [])

    /// 由屏幕列表生成目标：每块屏幕贡献 frame 与 visibleFrame 两个矩形。
    public init(neighbors: [ScreenRect], screenInfos: [ScreenInfo]) {
        self.init(neighbors: neighbors, screens: screenInfos.flatMap { [$0.frame, $0.visibleFrame] })
    }
}

/// 缩放时被拖动的边。
public struct ResizeEdges: OptionSet, Sendable, Hashable {
    /// 位集合的原始值。
    public let rawValue: UInt8

    /// 用原始值建一个边集合。
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// 左边。
    public static let left = ResizeEdges(rawValue: 1)
    /// 右边。
    public static let right = ResizeEdges(rawValue: 2)
    /// 上边。
    public static let top = ResizeEdges(rawValue: 4)
    /// 下边。
    public static let bottom = ResizeEdges(rawValue: 8)
}

/// 吸附结果。
public struct SnapResult: Sendable, Equatable {
    /// 吸附与约束后的 frame。
    public var rect: ScreenRect
    /// 对齐到的竖直边的 x 坐标；没有对齐时为 nil。供以后画参考线。
    public var snappedX: Double?
    /// 对齐到的水平边的 y 坐标；没有对齐时为 nil。
    public var snappedY: Double?

    /// 用 frame 与对齐坐标建一个结果。
    public init(rect: ScreenRect, snappedX: Double?, snappedY: Double?) {
        self.rect = rect
        self.snappedX = snappedX
        self.snappedY = snappedY
    }
}

/// 吸附计算。
public enum SnapEngine {
    /// 默认吸附阈值，单位是点。
    public static let defaultThreshold = 8.0

    /// 移动时的吸附。x 轴与 y 轴各自独立，在阈值内取最近的目标边。
    ///
    /// 可对齐的组合：左对左、左对右、右对左、右对右，y 轴同理。邻居只在另一轴上与 proposed
    /// 有重叠或间隔不超过阈值时参与；屏幕的 4 条边始终参与。距离相同时取先找到的目标。
    public static func snapMove(proposed: ScreenRect, targets: SnapTargets, threshold: Double) -> SnapResult {
        let xHit = nearestLine(for: [proposed.minX, proposed.maxX],
                               lines: verticalLines(near: proposed, targets: targets, threshold: threshold),
                               threshold: threshold)
        let yHit = nearestLine(for: [proposed.minY, proposed.maxY],
                               lines: horizontalLines(near: proposed, targets: targets, threshold: threshold),
                               threshold: threshold)
        let rect = proposed.offsetBy(dx: xHit?.delta ?? 0, dy: yHit?.delta ?? 0)
        return SnapResult(rect: rect, snappedX: xHit?.line, snappedY: yHit?.line)
    }

    /// 缩放时的吸附。只移动 movingEdges 里的边，对边不动。
    ///
    /// 先吸附，再按 minimum、maximum 与 aspectRatio 约束，约束优先于吸附：约束改动了被吸附的边时，
    /// 对应的 snappedX 或 snappedY 置为 nil。约束改变尺寸时，固定边保持原位、由它反推原点。
    /// 只拖左右边时以宽算高（上边固定），只拖上下边时以高算宽（左边固定），拖角时以宽为准，
    /// 但只有竖直方向吸附成功时以高为准。
    ///
    /// - Parameter aspectRatio: 宽 ÷ 高；`lockAspectRatio` 打开或按住 Shift 时传拖动开始时的比例，否则 nil。
    ///   按住 Shift 时调用方传 `SnapTargets.none`，只应用约束。
    public static func snapResize(proposed: ScreenRect, movingEdges: ResizeEdges, targets: SnapTargets,
                                  threshold: Double, minimum: ScreenSize, maximum: ScreenSize,
                                  aspectRatio: Double?) -> SnapResult {
        let snapped = snapMovingEdges(proposed, movingEdges: movingEdges, targets: targets, threshold: threshold)
        var minX = snapped.minX, maxX = snapped.maxX, minY = snapped.minY, maxY = snapped.maxY

        let driveByHeight = movingEdges.isDisjoint(with: [.left, .right])
            || (snapped.snappedY != nil && snapped.snappedX == nil && !movingEdges.isDisjoint(with: [.top, .bottom]))
        let size = constrainedSize(width: maxX - minX, height: maxY - minY, driveByHeight: driveByHeight,
                                   minimum: minimum, maximum: maximum, aspectRatio: aspectRatio)
        // 只拖左边时右边固定；其余情况左边固定。竖直方向同理。
        if movingEdges.contains(.left) && !movingEdges.contains(.right) {
            minX = maxX - size.width
        } else {
            maxX = minX + size.width
        }
        if movingEdges.contains(.top) && !movingEdges.contains(.bottom) {
            minY = maxY - size.height
        } else {
            maxY = minY + size.height
        }
        let rect = ScreenRect(x: minX, y: minY, width: size.width, height: size.height)
        return SnapResult(rect: rect,
                          snappedX: snapped.snappedX.flatMap { isEdge($0, of: [rect.minX, rect.maxX]) },
                          snappedY: snapped.snappedY.flatMap { isEdge($0, of: [rect.minY, rect.maxY]) })
    }

    /// 鼠标按下的位置落在哪些边的 margin 范围内，用来决定缩放哪条边或哪个角。
    ///
    /// 点在矩形外时返回空集合。矩形太窄、点同时靠近左右两边时，取更近的那条边；上下同理。
    public static func resizeEdges(at point: ScreenPoint, in rect: ScreenRect, margin: Double) -> ResizeEdges {
        guard point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else {
            return []
        }
        var edges: ResizeEdges = []
        let left = point.x - rect.minX, right = rect.maxX - point.x
        let top = point.y - rect.minY, bottom = rect.maxY - point.y
        if left <= margin || right <= margin { edges.insert(left <= right ? .left : .right) }
        if top <= margin || bottom <= margin { edges.insert(top <= bottom ? .top : .bottom) }
        return edges
    }

    // MARK: - 私有：目标边

    /// 一次命中：目标线的坐标与需要的位移。
    private struct Hit {
        var line: Double
        var delta: Double
    }

    /// 参与 x 方向吸附的竖直线：在 y 方向与 proposed 重叠或接近的邻居的左右边，以及全部屏幕的左右边。
    private static func verticalLines(near proposed: ScreenRect, targets: SnapTargets, threshold: Double) -> [Double] {
        let neighbors = targets.neighbors.filter {
            $0.minY <= proposed.maxY + threshold && $0.maxY >= proposed.minY - threshold
        }
        return (neighbors + targets.screens).flatMap { [$0.minX, $0.maxX] }
    }

    /// 参与 y 方向吸附的水平线：在 x 方向与 proposed 重叠或接近的邻居的上下边，以及全部屏幕的上下边。
    private static func horizontalLines(near proposed: ScreenRect, targets: SnapTargets, threshold: Double) -> [Double] {
        let neighbors = targets.neighbors.filter {
            $0.minX <= proposed.maxX + threshold && $0.maxX >= proposed.minX - threshold
        }
        return (neighbors + targets.screens).flatMap { [$0.minY, $0.maxY] }
    }

    /// 在阈值内找离任一条边最近的目标线。距离相同时保留先找到的。
    private static func nearestLine(for edges: [Double], lines: [Double], threshold: Double) -> Hit? {
        var best: Hit?
        for edge in edges {
            for line in lines {
                let delta = line - edge
                guard abs(delta) <= threshold else { continue }
                if best == nil || abs(delta) < abs(best!.delta) {
                    best = Hit(line: line, delta: delta)
                }
            }
        }
        return best
    }

    /// 只对被拖动的边做吸附，返回四条边的新坐标与对齐线。
    private static func snapMovingEdges(_ proposed: ScreenRect, movingEdges: ResizeEdges, targets: SnapTargets,
                                        threshold: Double)
        -> (minX: Double, maxX: Double, minY: Double, maxY: Double, snappedX: Double?, snappedY: Double?) {
        let xLines = verticalLines(near: proposed, targets: targets, threshold: threshold)
        let yLines = horizontalLines(near: proposed, targets: targets, threshold: threshold)
        var minX = proposed.minX, maxX = proposed.maxX, minY = proposed.minY, maxY = proposed.maxY
        var snappedX: Double?, snappedY: Double?
        if movingEdges.contains(.left), let hit = nearestLine(for: [minX], lines: xLines, threshold: threshold) {
            minX = hit.line; snappedX = hit.line
        } else if movingEdges.contains(.right), let hit = nearestLine(for: [maxX], lines: xLines, threshold: threshold) {
            maxX = hit.line; snappedX = hit.line
        }
        if movingEdges.contains(.top), let hit = nearestLine(for: [minY], lines: yLines, threshold: threshold) {
            minY = hit.line; snappedY = hit.line
        } else if movingEdges.contains(.bottom), let hit = nearestLine(for: [maxY], lines: yLines, threshold: threshold) {
            maxY = hit.line; snappedY = hit.line
        }
        return (minX, maxX, minY, maxY, snappedX, snappedY)
    }

    // MARK: - 私有：约束

    /// 按最小、最大尺寸与宽高比约束尺寸。比例与范围冲突时范围优先。
    private static func constrainedSize(width: Double, height: Double, driveByHeight: Bool,
                                        minimum: ScreenSize, maximum: ScreenSize, aspectRatio: Double?) -> ScreenSize {
        var w = clamp(width, minimum.width, maximum.width)
        var h = clamp(height, minimum.height, maximum.height)
        guard let ratio = aspectRatio, ratio.isFinite, ratio > 0 else {
            return ScreenSize(width: w, height: h)
        }
        if driveByHeight {
            w = clamp(h * ratio, minimum.width, maximum.width)
            h = clamp(w / ratio, minimum.height, maximum.height)
        } else {
            h = clamp(w / ratio, minimum.height, maximum.height)
            w = clamp(h * ratio, minimum.width, maximum.width)
        }
        return ScreenSize(width: w, height: h)
    }

    /// value 与 edges 中某一条边重合（容差 1e-9）时返回 value，否则返回 nil。
    private static func isEdge(_ value: Double, of edges: [Double]) -> Double? {
        edges.contains { abs($0 - value) < 1e-9 } ? value : nil
    }

    /// 夹到 [lower, upper]；upper 小于 lower 时以 lower 为准。
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), max(upper, lower))
    }
}
