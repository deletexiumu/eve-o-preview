// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图规划器（架构文档 3.3 节、5.6 节）：由全部运行时状态算出每个缩略图的呈现、
// 要捕获的窗口与规格、要持久化的自动布局，以及下一次定时重算的时刻。

import Foundation

/// 规划器。纯函数，同样的输入总是得到同样的输出（自动排位只依赖输入顺序）。
public enum ThumbnailPlanner {
    /// 由状态算出全部缩略图的呈现。
    ///
    /// - 布局：先给有记录的角色与登录客户端定位，再按客户端顺序给没有记录的角色自动排位，
    ///   使自动排位避开全部已知缩略图；每个自动排位的 frame 立即加入 occupied。
    /// - `layoutsToPersist` 只含自动排位的角色（宽高写 nil，表示用默认尺寸）；
    ///   被 `clampToScreens` 拉回的有记录布局不写回，避免拔掉显示器后覆盖保存的位置。
    /// - 外观、占位与捕获规格的规则见架构文档 5.6 节与各字段的说明。
    public static func plan(_ input: PlannerInput) -> ThumbnailPlan {
        let layout = resolveLayouts(input)
        var presentations: [ThumbnailPresentation] = []
        var captures: [WindowID: CaptureSpec] = [:]
        for client in input.clients {
            let base = layout.frames[client.id]
                ?? LayoutResolver.frame(for: client, loginIndex: 0, profile: input.profile,
                                        screens: input.screens, occupied: []).frame
            let presentation = present(client, base: base, input: input)
            presentations.append(presentation)
            if presentation.isVisible && input.permissions.screenRecording {
                captures[client.id] = captureSpec(for: client, frame: presentation.frame, input: input)
            }
        }
        return ThumbnailPlan(presentations: presentations, captures: captures,
                             layoutsToPersist: layout.toPersist, nextWakeAt: nextWakeAt(input))
    }

    /// 下一次定时重算的时刻：隐藏期限与最早的提醒到期时刻中较小的一个（反馈文档 7.7 节）。
    /// 提醒到期时重算一次，把呈现里的 `alert` 清掉，并让第 4 条可见性规则恢复生效。
    private static func nextWakeAt(_ input: PlannerInput) -> Double? {
        let candidates = [VisibilityRules.hideDeadline(input: input),
                          input.session.earliestCombatAlertExpiry(now: input.now)].compactMap { $0 }
        return candidates.min()
    }

    // MARK: - 布局

    /// 两遍定位的结果：每个窗口的基准 frame 与要持久化的自动布局。
    private struct LayoutPass {
        var frames: [WindowID: ScreenRect] = [:]
        var toPersist: [String: ThumbnailLayout] = [:]
    }

    /// 两遍定位：第一遍是有记录的角色与登录客户端，第二遍是需要自动排位的角色。
    private static func resolveLayouts(_ input: PlannerInput) -> LayoutPass {
        var pass = LayoutPass()
        var occupied: [ScreenRect] = []
        let loginIndex = loginIndices(input.clients)
        var pending: [EVEClient] = []
        for client in input.clients {
            if let name = client.characterName, input.profile.layouts[name] == nil {
                pending.append(client)
                continue
            }
            let resolved = LayoutResolver.frame(for: client, loginIndex: loginIndex[client.id] ?? 0,
                                                profile: input.profile, screens: input.screens,
                                                occupied: occupied)
            pass.frames[client.id] = resolved.frame
            occupied.append(resolved.frame)
        }
        for client in pending {
            let resolved = LayoutResolver.frame(for: client, loginIndex: 0, profile: input.profile,
                                                screens: input.screens, occupied: occupied)
            pass.frames[client.id] = resolved.frame
            occupied.append(resolved.frame)
            // 同名的多个客户端只持久化第一个的位置。
            if resolved.isAutoPlaced, let name = client.characterName, pass.toPersist[name] == nil {
                pass.toPersist[name] = ThumbnailLayout(x: resolved.frame.x, y: resolved.frame.y)
            }
        }
        return pass
    }

    /// 登录与未知客户端按 PID 升序的序号。
    private static func loginIndices(_ clients: [EVEClient]) -> [WindowID: Int] {
        let loginClients = clients.filter { $0.characterName == nil }
            .sorted { ($0.pid, $0.id.rawValue) < ($1.pid, $1.id.rawValue) }
        var result: [WindowID: Int] = [:]
        for (index, client) in loginClients.enumerated() {
            result[client.id] = index
        }
        return result
    }

    // MARK: - 呈现

    /// 生成一个客户端的呈现。
    private static func present(_ client: EVEClient, base: ScreenRect, input: PlannerInput) -> ThumbnailPresentation {
        let profile = input.profile
        let session = input.session
        let isHovered = session.hoveredWindow == client.id
        let isInteracting = session.interactingWindows.contains(client.id)
        // 拖动中不放大：放大会改变 frame，与交互控制器直接设置的面板位置冲突。
        let zoom = isHovered && profile.thumbnail.zoomEnabled && !isInteracting
        let frame = zoom
            ? ZoomMath.zoomedFrame(base: base, factor: profile.thumbnail.zoomFactor, anchor: profile.thumbnail.zoomAnchor)
            : base
        let isActive = client.pid == activePID(input)
        // 高亮只画在活动客户端上；按角色的颜色优先，登录与未知客户端没有角色名，用全局颜色。
        var highlight: String?
        if profile.overlay.highlightEnabled && isActive {
            highlight = client.characterName.flatMap { profile.highlightColors[$0] } ?? profile.overlay.highlightColor
        }
        // 中性边框不看是否活动，与高亮同时给出，由视图按「先高亮、后边框」选用（反馈文档 4.1 节）。
        let border = profile.overlay.borderEnabled ? profile.overlay.borderColor : nil
        // 提醒不看 combatAlert.enabled：是否读日志由协调器把关，「测试闪烁」在关闭时也要能显示。
        let hasAlert = session.hasActiveCombatAlert(client.id, now: input.now)
        let alert = hasAlert ? ThumbnailAlert(color: profile.combatAlert.color, style: profile.combatAlert.style) : nil
        return ThumbnailPresentation(
            id: client.id, pid: client.pid, frame: frame,
            isVisible: VisibilityRules.isVisible(client: client, input: input),
            title: TitleParser.title(for: client.identity, pid: client.pid),
            showsTitle: profile.overlay.showTitle, titleFontSize: profile.overlay.titleFontSize,
            titleColor: profile.overlay.titleColor,
            // 悬停或有提醒时不透明，提醒中的缩略图在默认透明度 0.5 下也能看清。
            opacity: isHovered || hasAlert ? 1.0 : profile.thumbnail.opacity,
            highlightColor: highlight, highlightThickness: Double(profile.overlay.highlightThickness),
            isActive: isActive,
            isSkipped: client.characterName.map { session.skippedCharacters.contains($0) } ?? false,
            isAlwaysOnTop: profile.behavior.alwaysOnTop, isZoomed: zoom,
            contentsRect: CaptureMath.contentsRect(sourceSize: client.windowFrame.size,
                                                   titleBarCropHeight: cropHeight(for: client, input: input)),
            placeholder: placeholder(for: client, input: input),
            borderColor: border, borderThickness: Double(profile.overlay.borderThickness), alert: alert,
            isOverFullScreen: profile.behavior.alwaysOnTop && isFrontmostFullScreen(input))
    }

    /// 活动客户端的 PID：前台是客户端时取它，否则取最后一次处于前台的客户端。
    private static func activePID(_ input: PlannerInput) -> Int32? {
        if case .client(let pid) = input.frontmost { return pid }
        return input.session.lastActivePID
    }

    /// 前台是否是原生全屏的客户端。只在这时提高面板层级：客户端全屏、用户却在普通桌面时，
    /// 缩略图不该盖住 Dock、菜单栏与系统对话框（v1.1.1 复审）。前台变化是事件驱动的，会立即重算。
    private static func isFrontmostFullScreen(_ input: PlannerInput) -> Bool {
        guard case .client(let pid) = input.frontmost else { return false }
        return input.clients.contains { $0.pid == pid && $0.isFullScreen == true }
    }

    /// 标题栏裁剪高度：原生全屏（`isFullScreen`）或源窗口高度不小于所在屏幕高度时视为全屏，不裁。
    /// 原生全屏的窗口范围不含菜单栏那一条，高度比屏幕矮，只按高度判断会漏掉（v1.1.1 实测）。
    private static func cropHeight(for client: EVEClient, input: PlannerInput) -> Double {
        if client.isFullScreen == true { return 0 }
        let configured = input.profile.capture.titleBarCropHeight
        let screen = input.screens.screen(containing: client.windowFrame.center) ?? input.screens.mainScreen
        if let screen, client.windowFrame.height >= screen.frame.height { return 0 }
        return configured
    }

    /// 按顺序取第一个成立的占位。
    private static func placeholder(for client: EVEClient, input: PlannerInput) -> ThumbnailPlaceholder {
        let state = input.captureStates[client.id] ?? .idle
        // 权限问题排最前：没有权限时其他状态都无意义，用户首先要知道该去授权。
        if !input.permissions.screenRecording || state == .permissionDenied { return .needsScreenRecording }
        if state == .stoppedByUser { return .captureStopped }
        if client.isMinimized == true { return .minimized }
        // running 时有画面；windowGone 的客户端会在下一轮轮询中消失，不必显示占位。
        switch state {
        case .idle, .starting, .retrying: return .waitingForFrame
        default: return .none
        }
    }

    // MARK: - 捕获

    /// 捕获规格：scale 取缩略图中心点所在屏幕的值，找不到时取主屏，没有屏幕时取 1。
    private static func captureSpec(for client: EVEClient, frame: ScreenRect, input: PlannerInput) -> CaptureSpec {
        let screen = input.screens.screen(containing: frame.center) ?? input.screens.mainScreen
        return CaptureMath.spec(thumbnailSize: frame.size, sourceSize: client.windowFrame.size,
                                scale: screen?.scale ?? 1, frameRate: input.profile.capture.frameRate)
    }
}
