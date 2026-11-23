// SPDX-License-Identifier: GPL-3.0-or-later
//
// 两个浮窗面板的管理器（docs/design-intel-translate.md 8.7 节）：按规划器给出的呈现建、改、关面板，
// 把内容交给面板，把拖动与右键菜单的结果交给委托（协调器）。面板不知道预警与翻译的区别。
// - apply：呈现里没有的浮窗（功能没启用）关掉面板；有的建或更新。拖动中的浮窗不应用 frame。
// - setContent：只交给已有的面板；协调器在浮窗变成可见时会再补一次内容，所以没有面板时直接丢弃。
// - visibleFrames：作为缩略图与另一个浮窗拖动时的吸附目标。

import EVEOPreviewCore

/// 浮窗右键菜单里交给协调器处理的动作（「滚动到最新」「复制这一条」「在浏览器中打开」由面板与菜单自己处理）。
enum OverlayMenuAction {
    /// 清空活动角色在这个浮窗里的缓冲。
    case clear
    /// 切换 `behavior.lockLayout`。
    case toggleLock
    /// 把 `overlay.frame` 设回 nil。
    case resetFrame
    /// 把这个功能的 `enabled` 设成假。
    case hide
    /// 打开设置窗口的对应页。
    case openSettings
}

/// 拖动开始前由委托给出的上下文。
struct OverlayDragContext {
    /// 起点：面板当前的 frame。
    var startFrame: ScreenRect
    /// 布局已锁定时忽略移动与缩放。
    var isLocked: Bool
    /// 是否吸附（`thumbnail.snapEnabled`）。
    var snapEnabled: Bool
    /// 吸附目标：各屏幕、可见的缩略图与另一个浮窗。
    var targets: SnapTargets
}

/// 浮窗管理器的委托，由协调器实现。
@MainActor protocol InfoOverlayDelegate: AnyObject {
    /// 拖动开始前要上下文；返回 nil 时不拖动。
    func overlayDragContext(for kind: OverlayKind) -> OverlayDragContext?
    /// 拖动开始。
    func overlayDragBegan(_ kind: OverlayKind)
    /// 松开鼠标，frame 是最终的位置与尺寸。
    func overlayDragEnded(_ kind: OverlayKind, frame: ScreenRect)
    /// 右键菜单里选了一项。
    func overlayMenuAction(_ action: OverlayMenuAction, for kind: OverlayKind)
}

/// 浮窗面板的管理器。全部方法在主线程调用。
@MainActor final class InfoOverlayManager {
    /// 委托；变了时同步给已有的面板。
    weak var delegate: InfoOverlayDelegate? {
        didSet {
            for controller in controllers.values { controller.delegate = delegate }
        }
    }
    /// 已建的面板控制器，按种类存放。
    private var controllers: [OverlayKind: InfoOverlayController] = [:]

    /// 按呈现建、改、关面板。interacting 里的浮窗正在拖动，不应用 frame。
    func apply(_ presentations: [OverlayPresentation], interacting: Set<OverlayKind>) {
        let wanted = Set(presentations.map(\.kind))
        for (kind, controller) in controllers where !wanted.contains(kind) {
            controller.close()
            controllers[kind] = nil
        }
        for presentation in presentations {
            let controller = controllers[presentation.kind]
                ?? InfoOverlayController(presentation: presentation, delegate: delegate)
            controllers[presentation.kind] = controller
            controller.apply(presentation, isInteracting: interacting.contains(presentation.kind))
        }
    }

    /// 把内容交给某个浮窗的面板；没有面板时丢弃。
    func setContent(_ content: OverlayContent, for kind: OverlayKind) {
        controllers[kind]?.setContent(content)
    }

    /// 当前可见的浮窗。
    func visibleKinds() -> Set<OverlayKind> {
        Set(controllers.values.filter(\.isVisible).map(\.kind))
    }

    /// 可见浮窗当前的 frame，作为吸附目标；excluding 为 nil 时全部列出。
    func visibleFrames(excluding kind: OverlayKind?) -> [ScreenRect] {
        controllers.values.filter { $0.isVisible && $0.kind != kind }.map(\.currentFrame)
    }

    /// 某个浮窗面板当前的 frame（拖动的起点）；没有面板时为 nil。
    func currentFrame(for kind: OverlayKind) -> ScreenRect? {
        controllers[kind]?.currentFrame
    }

    /// 关闭全部面板。退出前调用。
    func closeAll() {
        for controller in controllers.values { controller.close() }
        controllers.removeAll()
    }
}
