// SPDX-License-Identifier: GPL-3.0-or-later
//
// 鼠标停在缩略图或浮窗的边缘带上时显示缩放光标（v1.2.1）。
// - 边缘由 Core 的 EdgeGrip 算出（ResizeEdges，Core 坐标里 top 就是屏幕上方），这里只负责换成 NSCursor。
// - macOS 15 起用系统的 frameResize 光标，八个方向都有；macOS 14 只有左右与上下两种，角上用左右光标代替。
// - 只在本类设置过光标时才恢复箭头，避免鼠标离开时把别的应用（如游戏）的光标改掉。
// - 本应用几乎不在前台，系统默认不让后台应用改光标；能否生效取决于 BackgroundCursor 是否已打开。

import AppKit
import EVEOPreviewCore

/// 缩放光标的显示与恢复。只在主线程使用。
@MainActor
enum ResizeCursor {
    /// 当前是否由本类设置了缩放光标；为真时离开边缘才恢复箭头。
    private static var isShowing = false

    /// 按边显示光标：有边时显示对应方向的缩放光标，没有边时恢复箭头（只在之前设置过时）。
    static func update(for edges: ResizeEdges) {
        guard !edges.isEmpty else {
            reset()
            return
        }
        cursor(for: edges).set()
        isShowing = true
    }

    /// 之前设置过缩放光标时恢复成箭头。鼠标离开面板、开始普通点击时调用。
    static func reset() {
        guard isShowing else { return }
        NSCursor.arrow.set()
        isShowing = false
    }

    /// 边对应的系统光标。
    private static func cursor(for edges: ResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: position(for: edges), directions: .all)
        }
        // macOS 14：只有左右、上下两种缩放光标；纯上下边用上下光标，其余（左右边与四个角）用左右光标。
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        let horizontal = edges.contains(.left) || edges.contains(.right)
        return vertical && !horizontal ? .resizeUpDown : .resizeLeftRight
    }

    /// 边集合对应的 frameResize 位置。边集合由 EdgeGrip 给出，至多一条横边加一条竖边。
    @available(macOS 15.0, *)
    private static func position(for edges: ResizeEdges) -> NSCursor.FrameResizePosition {
        switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.left), edges.contains(.right)) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .topRight
        case (_, true, true, _): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .top
        case (_, true, _, _): return .bottom
        case (_, _, true, _): return .left
        default: return .right
        }
    }
}
