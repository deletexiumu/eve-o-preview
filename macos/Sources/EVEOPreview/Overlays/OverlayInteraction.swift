// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的鼠标手势（docs/macos/design-intel-translate.md 8.7 节），由 InfoOverlayPanel.sendEvent 调用 handle(_:)。
//
// | 操作 | 手势 |
// | 滚动列表 | 滚轮或触控板双指滑动（不经过这里） |
// | 移动 | 右键拖动，或 Option+左键拖动，移动超过 4 点后开始 |
// | 缩放 | 同移动，起点落在边缘 12 点内时改为缩放那条边或那个角；
// |      | 也可以不带修饰键直接用左键从边缘 6 点内拖动（EdgeGrip，v1.2.1），角区 14 点 |
// | 绕过吸附 | 拖动时按住 Shift（只绕过吸附，不保持宽高比） |
// | 菜单 | 右键按下并松开，期间移动不到 4 点 |
// | 回到最新 | 左键点新消息条 |
//
// 不带修饰键的左键：点在新消息条上时回到最新并吞掉事件；按在边缘带上时进入缩放待定（没拖动就松开时什么也不做）；
// 点在别处时交还给面板，让滚动条照常可拖，列表本身没有动作。内容视图给滚动条右侧与底部留了 6 点，不与边缘带重叠。
// 拖动中每次事件由「起点 frame + 鼠标位移」算出候选 frame，经 SnapEngine 吸附与约束后直接设给面板；
// 松开时把最终 frame 交给委托写进配置。布局锁定时吞掉这次拖动，滚动与菜单照常。
// 入口与 ThumbnailInteraction 同形（mouseDown、mouseDragged、mouseUp），V29 的退路（改在视图上重写这些方法）只需小改。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 一个浮窗的手势状态机。
@MainActor
final class OverlayInteraction {
    /// 鼠标按键。
    enum Button { case left, right }

    /// 开始拖动的最小移动距离，单位是点。
    static let dragThreshold = 4.0
    /// 起点落在边缘多少点内时改为缩放。
    static let resizeMargin = 12.0

    /// 进行中的拖动。
    private struct Drag {
        var context: OverlayDragContext
        var edges: ResizeEdges
        var current: ScreenRect
    }

    /// 手势阶段。
    private enum Phase {
        /// 没有手势。
        case idle
        /// 已按下（右键或 Option+左键），还没移动超过阈值。
        case pending(button: Button, start: ScreenPoint)
        /// 不带修饰键的左键按在边缘带上，还没移动超过阈值：拖动则缩放这些边，松开则什么也不做。
        case pendingEdge(start: ScreenPoint, edges: ResizeEdges)
        /// 正在拖动。
        case dragging(button: Button, start: ScreenPoint, drag: Drag)
        /// 布局已锁定或拿不到上下文：吞掉本次拖动，松开时什么也不做。
        case suppressed(button: Button)
    }

    /// 浮窗的种类。
    let kind: OverlayKind
    /// 委托（协调器）。
    weak var delegate: InfoOverlayDelegate?
    /// 拖动中直接设置面板 frame 的回调。
    var setLiveFrame: ((ScreenRect) -> Void)?
    /// 右键单击时弹出菜单的回调，参数是松开时的事件。
    var showMenu: ((NSEvent) -> Void)?
    /// 不带修饰键的左键按下：返回真表示已处理（点在新消息条上），事件不再分发。
    var plainClick: ((NSEvent) -> Bool)?

    private var phase = Phase.idle

    /// 建一个浮窗的手势状态机。
    init(kind: OverlayKind) {
        self.kind = kind
    }

    /// 当前鼠标位置，换算成 Core 坐标（原点在主屏左上角，y 轴向下）。
    static func mouseLocation() -> ScreenPoint {
        CoordinateConversion.screenPoint(appKitPoint: NSEvent.mouseLocation,
                                         primaryScreenHeight: CoordinateConversion.primaryScreenHeight)
    }

    // MARK: - 事件

    /// 处理一个鼠标按键事件；返回真表示已处理，面板不再分发。
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown: return mouseDown(event, button: .left)
        case .rightMouseDown: return mouseDown(event, button: .right)
        case .leftMouseDragged: return mouseDragged(event, button: .left)
        case .rightMouseDragged: return mouseDragged(event, button: .right)
        case .leftMouseUp: return mouseUp(event, button: .left)
        case .rightMouseUp: return mouseUp(event, button: .right)
        default: return false
        }
    }

    /// 按下：右键与 Option+左键进入待定；不带修饰键的左键只在新消息条上有动作。
    func mouseDown(_ event: NSEvent, button: Button) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch button {
        case .left where !flags.contains(.option):
            phase = .idle
            if plainClick?(event) == true { return true }
            // 布局锁定时没有边缘带，事件交还给面板。
            let start = Self.mouseLocation()
            guard let context = delegate?.overlayDragContext(for: kind),
                  case .resize(let edges) = EdgeGrip.plainPress(at: start, in: context.startFrame,
                                                                 allowsResize: true, isLocked: context.isLocked)
            else { return false }
            phase = .pendingEdge(start: start, edges: edges)
            return true
        case .left, .right:
            phase = .pending(button: button, start: Self.mouseLocation())
            return true
        }
    }

    /// 拖动：超过阈值后开始移动或缩放，之后每次事件更新面板 frame。没有手势时交还给面板（如拖动滚动条）。
    func mouseDragged(_ event: NSEvent, button: Button) -> Bool {
        let point = Self.mouseLocation()
        switch phase {
        case .pending(let pressed, let start) where pressed == button:
            guard hypot(point.x - start.x, point.y - start.y) > OverlayInteraction.dragThreshold else { return true }
            beginDrag(button: button, start: start)
            update(to: point)
            return true
        case .pendingEdge(let start, let edges) where button == .left:
            guard hypot(point.x - start.x, point.y - start.y) > OverlayInteraction.dragThreshold else { return true }
            // 用按下时判定的边，不再按 12 点重新判断。
            beginDrag(button: .left, start: start, forcedEdges: edges)
            update(to: point)
            return true
        case .dragging(let pressed, _, _) where pressed == button:
            update(to: point)
            return true
        case .suppressed(let pressed):
            return pressed == button
        default:
            return false
        }
    }

    /// 松开：右键没拖动时弹出菜单；拖动中则提交最终 frame。
    func mouseUp(_ event: NSEvent, button: Button) -> Bool {
        let current = phase
        switch current {
        case .pending(let pressed, _) where pressed == button:
            phase = .idle
            if button == .right { showMenu?(event) }
            return true
        case .pendingEdge where button == .left:
            // 边缘带上的单击：没拖动，吞掉即可（浮窗的左键单击本来就没有动作）。
            phase = .idle
            return true
        case .dragging(let pressed, _, let drag) where pressed == button:
            phase = .idle
            delegate?.overlayDragEnded(kind, frame: drag.current)
            // 松开时鼠标可能已不在边缘（尺寸上下限、吸附），按当前位置刷新光标。
            ResizeCursor.update(for: hoverEdges())
            return true
        case .suppressed(let pressed) where pressed == button:
            phase = .idle
            return true
        default:
            return false
        }
    }

    /// 鼠标停在浮窗上（没有按键按下）时应显示缩放光标的边；不在边缘带或布局锁定时为空。
    /// 由内容视图在 mouseMoved 里调用，规则与左键按下时一致。
    func hoverEdges() -> ResizeEdges {
        guard case .idle = phase, let context = delegate?.overlayDragContext(for: kind),
              !context.isLocked else { return [] }
        return EdgeGrip.edges(at: Self.mouseLocation(), in: context.startFrame)
    }

    /// 取消进行中的手势，不提交。面板在拖动中被隐藏或关闭时调用；之后的拖动与松开事件交还给面板。
    func cancel() {
        phase = .idle
    }

    // MARK: - 拖动

    /// 开始拖动：取上下文，按起点决定移动还是缩放，通知委托。
    ///
    /// - Parameter forcedEdges: 不带修饰键的左键从边缘带开始时，按下时已判定的边；nil 时按 12 点边缘重新判断。
    private func beginDrag(button: Button, start: ScreenPoint, forcedEdges: ResizeEdges? = nil) {
        guard let context = delegate?.overlayDragContext(for: kind), !context.isLocked else {
            phase = .suppressed(button: button)
            return
        }
        let edges = forcedEdges
            ?? SnapEngine.resizeEdges(at: start, in: context.startFrame, margin: OverlayInteraction.resizeMargin)
        phase = .dragging(button: button, start: start, drag: Drag(context: context, edges: edges,
                                                                  current: context.startFrame))
        delegate?.overlayDragBegan(kind)
    }

    /// 按鼠标的当前位置算出新 frame 并设给面板。
    private func update(to point: ScreenPoint) {
        guard case .dragging(let button, let start, var drag) = phase else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let bypassSnap = NSEvent.modifierFlags.contains(.shift) || !drag.context.snapEnabled
        drag.current = drag.edges.isEmpty
            ? movedFrame(drag.context, dx: dx, dy: dy, bypassSnap: bypassSnap)
            : resizedFrame(drag.context, edges: drag.edges, dx: dx, dy: dy, bypassSnap: bypassSnap)
        phase = .dragging(button: button, start: start, drag: drag)
        setLiveFrame?(drag.current)
    }

    /// 移动：起点 frame 平移后吸附；按住 Shift 或关闭吸附时不吸附。
    private func movedFrame(_ context: OverlayDragContext, dx: Double, dy: Double, bypassSnap: Bool) -> ScreenRect {
        let proposed = context.startFrame.offsetBy(dx: dx, dy: dy)
        guard !bypassSnap else { return proposed }
        return SnapEngine.snapMove(proposed: proposed, targets: context.targets,
                                   threshold: SnapEngine.defaultThreshold).rect
    }

    /// 缩放：只移动被拖动的边，再交给 SnapEngine 吸附，尺寸夹在 OverlayPlanner 的上下限之间，不保持宽高比。
    private func resizedFrame(_ context: OverlayDragContext, edges: ResizeEdges,
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
        return SnapEngine.snapResize(proposed: proposed, movingEdges: edges,
                                     targets: bypassSnap ? SnapTargets.none : context.targets,
                                     threshold: SnapEngine.defaultThreshold,
                                     minimum: OverlayPlanner.minimumSize, maximum: OverlayPlanner.maximumSize,
                                     aspectRatio: nil).rect
    }
}
