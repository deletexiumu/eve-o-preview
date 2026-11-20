// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图基准 frame 的计算（架构文档 5.4 节）：有记录用记录，没有记录自动排位，
// 登录客户端从 loginPosition 层叠；最后都拉回屏幕内，显示器拔掉后缩略图不会留在屏幕外。

import Foundation

/// `LayoutResolver.frame` 的结果。
public struct ResolvedLayout: Sendable, Equatable {
    /// 缩略图的基准 frame（不含悬停放大），全局屏幕坐标。
    public var frame: ScreenRect
    /// 是否为自动排出的位置。为真时规划器把它写进 `layoutsToPersist`，以后位置固定。
    public var isAutoPlaced: Bool

    /// 用 frame 与是否自动排位建一个结果。
    public init(frame: ScreenRect, isAutoPlaced: Bool) {
        self.frame = frame
        self.isAutoPlaced = isAutoPlaced
    }
}

/// 缩略图布局计算。
public enum LayoutResolver {
    /// 自动排位时距可用区域边缘的距离，单位是点。
    public static let autoPlaceMargin = 16.0
    /// 自动排位时相邻缩略图的间距，单位是点。
    public static let autoPlaceSpacing = 8.0
    /// 登录客户端每个序号的层叠偏移，单位是点（x、y 各加这么多）。
    public static let loginCascadeOffset = 24.0
    /// 缩略图在任何屏幕上至少要露出的边长，单位是点。
    public static let minimumVisible = 32.0

    /// 取客户端缩略图的基准 frame（不含悬停放大）。occupied 是本轮已分配的 frame。
    ///
    /// 1. 角色在 `profile.layouts` 里有记录：用记录的位置；宽高为 nil 时用 `defaultSize`；
    ///    尺寸经 `clampSize`；`isAutoPlaced = false`。
    /// 2. 角色没有记录：在主屏 `visibleFrame` 内从左上角起向下排，边距 16 点，间距 8 点，
    ///    排满换下一列，跳过与 `occupied` 相交的格子；`isAutoPlaced = true`。
    ///    全部格子都被占用时取第一个格子。
    /// 3. 登录或未知的客户端：`loginPosition` 加 `(24 × loginIndex, 24 × loginIndex)`，
    ///    尺寸用 `defaultSize`，`isAutoPlaced = false`。
    /// 4. 结果都经过 `clampToScreens(_, screens, minimumVisible: 32)`。
    ///
    /// - Parameter loginIndex: 该客户端在登录与未知客户端里按 PID 升序的序号，从 0 起；角色客户端忽略它。
    public static func frame(for client: EVEClient, loginIndex: Int, profile: Profile,
                             screens: [ScreenInfo], occupied: [ScreenRect]) -> ResolvedLayout {
        let settings = profile.thumbnail
        let defaultSize = clampSize(settings.defaultSize, settings: settings, aspectRatio: nil)
        let raw: ResolvedLayout
        switch client.identity {
        case .character(let name):
            if let layout = profile.layouts[name] {
                let wanted = ScreenSize(width: layout.width ?? defaultSize.width,
                                        height: layout.height ?? defaultSize.height)
                let size = clampSize(wanted, settings: settings, aspectRatio: nil)
                raw = ResolvedLayout(frame: ScreenRect(x: layout.x, y: layout.y, width: size.width,
                                                       height: size.height), isAutoPlaced: false)
            } else {
                raw = ResolvedLayout(frame: autoPlace(size: defaultSize, screens: screens, occupied: occupied),
                                     isAutoPlaced: true)
            }
        case .login, .unknown:
            let offset = loginCascadeOffset * Double(max(loginIndex, 0))
            let origin = ScreenPoint(x: profile.loginPosition.x + offset, y: profile.loginPosition.y + offset)
            raw = ResolvedLayout(frame: ScreenRect(origin: origin, size: defaultSize), isAutoPlaced: false)
        }
        let clamped = clampToScreens(raw.frame, screens: screens, minimumVisible: minimumVisible)
        return ResolvedLayout(frame: clamped, isAutoPlaced: raw.isAutoPlaced)
    }

    /// 把尺寸夹到 `minimumSize`～`maximumSize` 之间。
    ///
    /// - Parameter aspectRatio: 宽 ÷ 高。非 nil 时先按宽算高，高越界时改按高的边界算宽，
    ///   再把宽夹一次；最小与最大尺寸无法同时满足比例时，范围优先于比例。
    public static func clampSize(_ size: ScreenSize, settings: ThumbnailSettings, aspectRatio: Double?) -> ScreenSize {
        let minSize = settings.minimumSize
        let maxSize = settings.maximumSize
        var width = clamp(size.width, minSize.width, maxSize.width)
        var height = clamp(size.height, minSize.height, maxSize.height)
        if let ratio = aspectRatio, ratio.isFinite, ratio > 0 {
            height = width / ratio
            if height < minSize.height {
                height = minSize.height
                width = height * ratio
            } else if height > max(maxSize.height, minSize.height) {
                height = max(maxSize.height, minSize.height)
                width = height * ratio
            }
            width = clamp(width, minSize.width, maxSize.width)
        }
        return ScreenSize(width: width, height: height)
    }

    /// 缩略图在任何屏幕上的可见部分不足 minimumVisible 时，把它移回最近的屏幕内。
    ///
    /// 「可见」指与某块屏幕 frame 的交集宽高都不小于 minimumVisible（缩略图本身更小时以其边长为准）。
    /// 移回时选中心点距离最近的屏幕，把缩略图整体放进该屏幕的 `visibleFrame`；放不下时左上角对齐。
    /// 没有屏幕信息时原样返回。尺寸不变。
    public static func clampToScreens(_ rect: ScreenRect, screens: [ScreenInfo], minimumVisible: Double) -> ScreenRect {
        guard !screens.isEmpty else { return rect }
        let needWidth = min(minimumVisible, rect.width)
        let needHeight = min(minimumVisible, rect.height)
        for screen in screens {
            if let visible = rect.intersection(screen.frame),
               visible.width >= needWidth, visible.height >= needHeight {
                return rect
            }
        }
        let center = rect.center
        let nearest = screens.min { distance(from: center, to: $0.frame) < distance(from: center, to: $1.frame) }
        guard let target = nearest else { return rect }
        let area = target.visibleFrame.isEmpty ? target.frame : target.visibleFrame
        let x = clamp(rect.x, area.minX, area.maxX - rect.width)
        let y = clamp(rect.y, area.minY, area.maxY - rect.height)
        return ScreenRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    // MARK: - 私有

    /// 自动排位：在主屏可用区域里按列从上到下找第一个不与 occupied 相交的格子。
    private static func autoPlace(size: ScreenSize, screens: [ScreenInfo], occupied: [ScreenRect]) -> ScreenRect {
        guard let main = screens.mainScreen else {
            return ScreenRect(x: autoPlaceMargin, y: autoPlaceMargin, width: size.width, height: size.height)
        }
        let area = main.visibleFrame.isEmpty ? main.frame : main.visibleFrame
        let first = ScreenRect(x: area.minX + autoPlaceMargin, y: area.minY + autoPlaceMargin,
                               width: size.width, height: size.height)
        guard size.width > 0, size.height > 0 else { return first }
        var x = first.x
        while x + size.width <= area.maxX - autoPlaceMargin {
            var y = first.y
            while y + size.height <= area.maxY - autoPlaceMargin {
                let cell = ScreenRect(x: x, y: y, width: size.width, height: size.height)
                if !occupied.contains(where: { $0.intersects(cell) }) { return cell }
                y += size.height + autoPlaceSpacing
            }
            x += size.width + autoPlaceSpacing
        }
        // 屏幕已排满（或缩略图比屏幕大）：叠放在第一个格子，用户可再拖开。
        return first
    }

    /// 点到矩形的距离；点在矩形内时为 0。
    private static func distance(from point: ScreenPoint, to rect: ScreenRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 夹到 [lower, upper]；upper 小于 lower 时以 lower 为准。
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), max(upper, lower))
    }
}
