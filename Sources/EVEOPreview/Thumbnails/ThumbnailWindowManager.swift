// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图面板的管理器（架构文档 7.3 节）：按 ThumbnailPlan.presentations 的差异建、改、删面板控制器。
// 客户端变成活动时把它的面板放到最上面，所以重叠的缩略图里最近活动的在最上面；
// 悬停放大的面板也放到最上面，避免被相邻的缩略图挡住。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

/// 缩略图面板的管理器。
@MainActor
final class ThumbnailWindowManager {
    /// 面板的委托（协调器）。
    weak var delegate: ThumbnailPanelDelegate?
    private var controllers: [WindowID: ThumbnailPanelController] = [:]

    /// 按呈现列表更新面板。
    ///
    /// - Parameters:
    ///   - presentations: 规划器给出的全部呈现。
    ///   - interacting: 正在拖动的窗口，它们的 frame 不应用。
    func apply(_ presentations: [ThumbnailPresentation], interacting: Set<WindowID>) {
        let wanted = Set(presentations.map(\.id))
        for (id, controller) in controllers where !wanted.contains(id) {
            controller.close()
            controllers[id] = nil
        }
        var raise: [ThumbnailPanelController] = []
        for presentation in presentations {
            let existing = controllers[presentation.id]
            let controller = existing ?? ThumbnailPanelController(presentation: presentation, delegate: delegate)
            controllers[presentation.id] = controller
            let wasActive = existing?.presentation.isActive ?? false
            let wasZoomed = existing?.presentation.isZoomed ?? false
            controller.apply(presentation, isInteracting: interacting.contains(presentation.id))
            if (presentation.isActive && !wasActive) || (presentation.isZoomed && !wasZoomed) {
                raise.append(controller)
            }
        }
        // 活动的先上，放大的最后上，放大的面板总在最上面。
        for controller in raise.sorted(by: { !$0.presentation.isZoomed && $1.presentation.isZoomed }) {
            controller.bringToFront()
        }
    }

    /// 把一帧画面交给对应的面板；面板不存在时丢弃。
    func display(_ frame: CapturedFrame, for id: WindowID) {
        controllers[id]?.display(frame)
    }

    /// 按窗口 ID 取面板控制器。
    func controller(for id: WindowID) -> ThumbnailPanelController? {
        controllers[id]
    }

    /// 其他可见面板当前的 frame，作为吸附目标。
    func visibleFrames(excluding id: WindowID) -> [ScreenRect] {
        controllers.values.filter { $0.id != id && $0.isVisible }.map(\.currentFrame)
    }

    /// 关闭全部面板。退出前调用。
    func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
    }
}
