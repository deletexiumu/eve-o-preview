// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的鼠标手势（架构文档 4.5 节、7.3 节）。
//
// | 操作 | 手势 |
// | 切换 | 左键按下（不带 Ctrl、Option），按下即切换，不等松开 |
// | 最小化 | Ctrl+左键按下 |
// | 菜单 | 右键按下并松开，期间移动不到 4 点 |
// | 移动 | 右键拖动，或 Option+左键拖动，移动超过 4 点后开始 |
// | 缩放 | 同移动，起点落在边缘 12 点内时改为缩放那条边或那个角 |
// | 绕过吸附 | 拖动时按住 Shift；缩放时 Shift 同时保持宽高比 |
//
// 拖动中每次鼠标事件都由「起点 frame + 鼠标原始位移」算出候选 frame，交给 SnapEngine，
// 再直接设给面板，不经过规划器与配置保存；松开时才通知协调器提交一次。
//
// 悬停放大时开始拖动：缩放边缘按面板实际显示的（放大后的）frame 判断，因为用户按住的是放大后的边；
// 判断完后面板回到基准 frame，移动、吸附、尺寸约束与保存都在基准 frame 上做（架构文档 5.6 节：
// 拖动中的窗口不放大）。这样保存的不会是放大后的尺寸，吸附也与其他未放大的缩略图对齐。
// Ctrl+左键在 macOS 上惯例是右键，这里由视图自己处理 mouseDown，不设置 NSView.menu。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 一次拖动所需的上下文，由协调器在拖动开始时给出一次。
struct ThumbnailDragContext {
    /// 拖动起点的基准 frame（不含悬停放大），Core 坐标。拖动在它上面进行。
    var startFrame: ScreenRect
    /// 开始拖动时面板实际显示的 frame，只用来判断起点是否落在缩放边缘。悬停放大时比 startFrame 大。
    var edgeFrame: ScreenRect
    /// 布局是否锁定；锁定时忽略移动与缩放。
    var isLocked: Bool
    /// 是否启用吸附。
    var snapEnabled: Bool
    /// 缩放时是否保持宽高比。
    var lockAspectRatio: Bool
    /// 是否允许缩放。登录客户端的尺寸不持久化，只允许移动。
    var allowsResize: Bool
    /// 缩放下限。
    var minimumSize: ScreenSize
    /// 缩放上限。
    var maximumSize: ScreenSize
    /// 吸附目标：其他可见缩略图与屏幕，拖动开始时取一次。
    var targets: SnapTargets
}

/// 缩略图面板把用户操作交给它的委托（协调器）。全部在主线程调用。
@MainActor
protocol ThumbnailPanelDelegate: AnyObject {
    /// 左键按下：切换到该客户端。
    func thumbnailClicked(_ id: WindowID)
    /// Ctrl+左键按下：最小化该客户端。
    func thumbnailMinimizeRequested(_ id: WindowID)
    /// 右键单击：在视图上弹出菜单。
    func thumbnailMenuRequested(_ id: WindowID, event: NSEvent, in view: NSView)
    /// 鼠标进入或离开缩略图。
    func hoverChanged(_ id: WindowID, isHovering: Bool)
    /// 拖动开始前取上下文；返回 nil 表示不能拖动。
    func dragContext(for id: WindowID) -> ThumbnailDragContext?
    /// 拖动开始（移动超过阈值之后）。
    func dragBegan(_ id: WindowID)
    /// 拖动结束，参数是面板最终的 frame。
    func dragEnded(_ id: WindowID, frame: ScreenRect)
}

/// 一个缩略图的手势状态机。
@MainActor
final class ThumbnailInteraction {
    /// 鼠标按键。
    enum Button { case left, right }

    /// 开始拖动的最小移动距离，单位是点。
    static let dragThreshold = 4.0
    /// 起点落在边缘多少点内时改为缩放。
    static let resizeMargin = 12.0

    /// 当前鼠标位置，换算成 Core 坐标（原点在主屏左上角，y 轴向下）。
    /// 换算统一交给 Platform 的 CoordinateConversion，App 不自己翻转 y 轴。
    static func mouseLocation() -> ScreenPoint {
        CoordinateConversion.screenPoint(appKitPoint: NSEvent.mouseLocation,
                                         primaryScreenHeight: CoordinateConversion.primaryScreenHeight)
    }

    /// 进行中的拖动。
    private struct Drag {
        var context: ThumbnailDragContext
        var edges: ResizeEdges
        var current: ScreenRect
    }

    /// 手势阶段。
    private enum Phase {
        /// 没有按键按下，或按下后不产生手势（如左键切换后）。
        case idle
        /// 已按下，还没移动超过阈值。
        case pending(button: Button, start: ScreenPoint)
        /// 正在拖动。
        case dragging(button: Button, start: ScreenPoint, drag: Drag)
        /// 布局已锁定：吞掉本次拖动，松开时什么也不做。
        case suppressed(button: Button)
    }

    /// 对应的窗口。
    let id: WindowID
    /// 委托（协调器）。
    weak var delegate: ThumbnailPanelDelegate?
    /// 拖动中直接设置面板 frame 的回调。
    var setLiveFrame: ((ScreenRect) -> Void)?

    private var phase = Phase.idle

    init(id: WindowID) {
        self.id = id
    }

    // MARK: - 事件

    /// 按下：左键无修饰键立即切换；Ctrl+左键立即最小化；Option+左键与右键进入待定。
    func mouseDown(_ event: NSEvent, button: Button) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let start = Self.mouseLocation()
        switch button {
        case .left where flags.contains(.control):
            phase = .idle
            delegate?.thumbnailMinimizeRequested(id)
        case .left where flags.contains(.option):
            phase = .pending(button: .left, start: start)
        case .left:
            phase = .idle
            delegate?.thumbnailClicked(id)
        case .right:
            phase = .pending(button: .right, start: start)
        }
    }

    /// 拖动：超过阈值后开始移动或缩放，之后每次事件更新面板 frame。
    func mouseDragged(_ event: NSEvent, button: Button) {
        let point = Self.mouseLocation()
        switch phase {
        case .pending(let pressed, let start) where pressed == button:
            let distance = hypot(point.x - start.x, point.y - start.y)
            guard distance > ThumbnailInteraction.dragThreshold else { return }
            beginDrag(button: button, start: start)
            update(to: point)
        case .dragging(let pressed, _, _) where pressed == button:
            update(to: point)
        default:
            break
        }
    }

    /// 松开：右键没拖动时弹出菜单；拖动中则提交最终 frame。
    func mouseUp(_ event: NSEvent, button: Button, in view: NSView) {
        let current = phase
        phase = .idle
        switch current {
        case .pending(.right, _) where button == .right:
            delegate?.thumbnailMenuRequested(id, event: event, in: view)
        case .dragging(let pressed, _, let drag) where pressed == button:
            delegate?.dragEnded(id, frame: drag.current)
        default:
            break
        }
    }

    /// 取消进行中的手势，不提交。面板在拖动中被隐藏时由面板控制器调用；之后的拖动与松开事件都被忽略。
    func cancel() {
        phase = .idle
    }

    // MARK: - 拖动

    /// 开始拖动：取上下文，按显示的 frame 判断移动还是缩放，再把面板放回基准 frame。
    private func beginDrag(button: Button, start: ScreenPoint) {
        guard let context = delegate?.dragContext(for: id), !context.isLocked else {
            phase = .suppressed(button: button)
            return
        }
        var edges = ResizeEdges()
        if context.allowsResize {
            edges = SnapEngine.resizeEdges(at: start, in: context.edgeFrame, margin: ThumbnailInteraction.resizeMargin)
        }
        phase = .dragging(button: button, start: start,
                          drag: Drag(context: context, edges: edges, current: context.startFrame))
        setLiveFrame?(context.startFrame)
        delegate?.dragBegan(id)
    }

    /// 按鼠标的当前位置算出新 frame 并设给面板。
    private func update(to point: ScreenPoint) {
        guard case .dragging(let button, let start, var drag) = phase else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let bypassSnap = NSEvent.modifierFlags.contains(.shift)
        drag.current = drag.edges.isEmpty
            ? movedFrame(drag.context, dx: dx, dy: dy, bypassSnap: bypassSnap)
            : resizedFrame(drag.context, edges: drag.edges, dx: dx, dy: dy, bypassSnap: bypassSnap)
        phase = .dragging(button: button, start: start, drag: drag)
        setLiveFrame?(drag.current)
    }

    /// 移动：起点 frame 平移后吸附；按住 Shift 或关闭吸附时不吸附。
    private func movedFrame(_ context: ThumbnailDragContext, dx: Double, dy: Double, bypassSnap: Bool) -> ScreenRect {
        let proposed = context.startFrame.offsetBy(dx: dx, dy: dy)
        guard context.snapEnabled, !bypassSnap else { return proposed }
        return SnapEngine.snapMove(proposed: proposed, targets: context.targets,
                                   threshold: SnapEngine.defaultThreshold).rect
    }

    /// 缩放：只移动被拖动的边，再交给 SnapEngine 吸附并按尺寸与宽高比约束。
    ///
    /// 按住 Shift 时吸附目标为空（只做约束），并保持拖动开始时的宽高比。
    private func resizedFrame(_ context: ThumbnailDragContext, edges: ResizeEdges,
                              dx: Double, dy: Double, bypassSnap: Bool) -> ScreenRect {
        var proposed = context.startFrame
        if edges.contains(.left) {
            proposed.x += dx
            proposed.width -= dx
        }
        if edges.contains(.right) { proposed.width += dx }
        if edges.contains(.top) {
            proposed.y += dy
            proposed.height -= dy
        }
        if edges.contains(.bottom) { proposed.height += dy }
        let keepAspect = context.lockAspectRatio || bypassSnap
        let targets = (context.snapEnabled && !bypassSnap) ? context.targets : SnapTargets.none
        return SnapEngine.snapResize(proposed: proposed, movingEdges: edges, targets: targets,
                                     threshold: SnapEngine.defaultThreshold,
                                     minimum: context.minimumSize, maximum: context.maximumSize,
                                     aspectRatio: keepAspect ? context.startFrame.size.aspectRatio : nil).rect
    }
}
