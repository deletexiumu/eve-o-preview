// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的预警与翻译浮窗部分（docs/macos/design-intel-translate.md 9.3 节）：
// - startChatOverlays()：在 start() 里、startCombatAlerts() 之后调用。接上浮窗管理器与总控的回调，按配置启动。
// - chatSettingsDidChange(old:new:)：配置变了以后交给总控，并按开关重新判断后台活动（App Nap）。
// - replanOverlays()：在 replan() 里、缩略图面板应用之后调用，返回浮窗规划的 nextWakeAt。
// - InfoOverlayDelegate：拖动的上下文与结果、右键菜单的动作。
// - toggleOverlay(_:)：菜单栏的「显示预警浮窗」「显示翻译浮窗」。
// 内容更新不触发重算：总控的 onContentChanged 只把新内容交给可见的浮窗。

import EVEOPreviewCore

extension AppCoordinator {
    /// 接上浮窗管理器与总控的回调，按当前配置启动。
    func startChatOverlays() {
        overlayManager.delegate = self
        chat.onContentChanged = { [weak self] kind in self?.chatContentChanged(kind) }
        chat.onStatusChanged = { [weak self] in self?.notifyRuntimeObservers() }
        chat.start(config: config.config)
        updateBackgroundActivity()
    }

    /// 配置变化后调用：交给总控；两个功能的开关可能变了，重新判断后台活动。
    func chatSettingsDidChange(old: AppConfig, new: AppConfig) {
        chat.configDidChange(old: old, new: new)
        let oldProfile = old.activeProfile
        let newProfile = new.activeProfile
        if oldProfile.intel.enabled != newProfile.intel.enabled
            || oldProfile.translation.enabled != newProfile.translation.enabled {
            updateBackgroundActivity()
        }
    }

    /// 规划浮窗并应用（9.3 节的 5 步），返回下一次要重算的时刻（单调时钟）。
    func replanOverlays() -> Double? {
        let input = OverlayPlannerInput(clients: registry.clients, frontmost: frontmost, profile: profile,
                                        session: session, screens: screens, now: now)
        let plan = OverlayPlanner.plan(input)
        chat.setActiveCharacter(plan.activeCharacter)
        // 拖动中的浮窗被关掉时，清掉它的交互状态，否则以后的 frame 永远不会应用到面板上。
        interactingOverlays.formIntersection(Set(plan.presentations.filter(\.isVisible).map(\.kind)))
        let before = overlayManager.visibleKinds()
        overlayManager.apply(plan.presentations, interacting: interactingOverlays)
        let after = overlayManager.visibleKinds()
        chat.setVisibleKinds(after)
        // 这一次才变成可见的浮窗，补一次内容（不可见时内容更新被跳过了）。
        for kind in OverlayKind.allCases where after.contains(kind) && !before.contains(kind) {
            overlayManager.setContent(chat.content(for: kind), for: kind)
        }
        return plan.nextWakeAt
    }

    /// 菜单栏的浮窗开关：切换当前配置方案里对应功能的 `enabled`。
    func toggleOverlay(_ kind: OverlayKind) {
        config.updateActiveProfile { profile in
            switch kind {
            case .intel: profile.intel.enabled.toggle()
            case .translation: profile.translation.enabled.toggle()
            }
        }
    }

    /// 某个浮窗的内容变了：可见时交给面板，不可见时不做任何事。
    private func chatContentChanged(_ kind: OverlayKind) {
        guard !isStopped, overlayManager.visibleKinds().contains(kind) else { return }
        overlayManager.setContent(chat.content(for: kind), for: kind)
    }
}

// MARK: - 浮窗管理器的委托

extension AppCoordinator: InfoOverlayDelegate {
    /// 拖动的上下文：起点是面板当前的 frame；吸附目标是各屏幕、可见的缩略图与另一个浮窗。
    func overlayDragContext(for kind: OverlayKind) -> OverlayDragContext? {
        guard let start = overlayManager.currentFrame(for: kind) else { return nil }
        // 缩略图管理器的 visibleFrames 要排除一个窗口；0 是空窗口 ID（kCGNullWindowID），不会排除任何面板。
        let thumbnails = windowManager.visibleFrames(excluding: WindowID(rawValue: 0))
        let neighbors = thumbnails + overlayManager.visibleFrames(excluding: kind)
        return OverlayDragContext(startFrame: start, isLocked: profile.behavior.lockLayout,
                                  snapEnabled: profile.thumbnail.snapEnabled,
                                  targets: SnapTargets(neighbors: neighbors, screenInfos: screens))
    }

    /// 拖动开始：标记为交互中，规划结果不再改它的 frame。
    func overlayDragBegan(_ kind: OverlayKind) {
        interactingOverlays.insert(kind)
        setNeedsReplan()
    }

    /// 松开鼠标：把最终 frame 写进当前配置方案，同一回合清掉交互状态。
    func overlayDragEnded(_ kind: OverlayKind, frame: ScreenRect) {
        interactingOverlays.remove(kind)
        config.updateActiveProfile { profile in
            switch kind {
            case .intel: profile.intel.overlay.frame = frame
            case .translation: profile.translation.overlay.frame = frame
            }
        }
        setNeedsReplan()
    }

    /// 右键菜单的动作（8.7 节的表）。
    func overlayMenuAction(_ action: OverlayMenuAction, for kind: OverlayKind) {
        switch action {
        case .clear:
            chat.clear(kind)
        case .toggleLock:
            config.updateActiveProfile { $0.behavior.lockLayout.toggle() }
        case .resetFrame:
            config.updateActiveProfile { profile in
                switch kind {
                case .intel: profile.intel.overlay.frame = nil
                case .translation: profile.translation.overlay.frame = nil
                }
            }
        case .hide:
            config.updateActiveProfile { profile in
                switch kind {
                case .intel: profile.intel.enabled = false
                case .translation: profile.translation.enabled = false
                }
            }
        case .openSettings:
            openSettings?(kind == .intel ? .intel : .translation)
        }
    }
}
