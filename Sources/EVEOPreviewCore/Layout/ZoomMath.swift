// SPDX-License-Identifier: GPL-3.0-or-later
//
// 悬停放大的几何计算（架构文档 5.4 节）。

import Foundation

/// 悬停放大。
public enum ZoomMath {
    /// 宽高乘以 factor，anchor 指定的那个点保持不动。
    ///
    /// `nw` 表示左上角不动，`center` 表示中心不动，`se` 表示右下角不动，其余同理。
    /// 放大后的尺寸不受 `maximumSize` 限制，也不拉回屏幕内（放大是临时的）。
    /// factor 不大于 1 时原样返回 base。
    public static func zoomedFrame(base: ScreenRect, factor: Int, anchor: ZoomAnchor) -> ScreenRect {
        guard factor > 1 else { return base }
        return base.scaled(by: Double(factor), anchor: anchor.unitPosition)
    }
}
