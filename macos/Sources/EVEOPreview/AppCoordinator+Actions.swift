// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的动作入口（架构文档 7.2 节）：缩略图的点击、最小化、悬停、拖动与右键菜单，
// 以及菜单栏与设置窗口调用的全局动作（全部隐藏、全部最小化、切换配置方案、恢复捕获）。

import AppKit
import EVEOPreviewCore
import EVEOPreviewPlatform

// MARK: - 切换与最小化

extension AppCoordinator {
    /// 切换到某个客户端。激活请求立即发出，结果只记日志；完成后重新判断前台并加调一次轮询。
    ///
    /// 按住循环热键时前一次激活还没完成，新的就开始了。被取代的激活返回的失败是正常情况，
    /// 只记调试日志，也不再刷新前台（由最新的那次刷新）。退出开始后完成的激活直接忽略。
    func activate(_ client: EVEClient) {
        let target = client.target
        activationSequence += 1
        let sequence = activationSequence
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.services.activator.activate(target)
            guard !self.isStopped else { return }
            guard sequence == self.activationSequence else {
                self.log.debug("切换到 PID \(target.pid) 已被取代：\(String(describing: outcome), privacy: .public)")
                return
            }
            switch outcome {
            case .activated:
                self.log.debug("已切换到 PID \(target.pid)")
            case .activatedAppOnly(let reason):
                self.log.info("只激活了进程 PID \(target.pid)：\(String(describing: reason), privacy: .public)")
            case .failed(let reason):
                self.log.error("切换失败 PID \(target.pid)：\(String(describing: reason), privacy: .public)")
            }
            self.refreshFrontmost()
            self.setNeedsReplan()
            self.pollNow()
        }
    }

    /// 最小化某个客户端。没有辅助功能权限时平台返回失败，只记日志。
    func minimize(_ client: EVEClient) {
        let target = client.target
        Task { [weak self] in
            guard let self else { return }
            if case .failure(let reason) = await self.services.activator.minimize(target) {
                self.log.error("最小化失败 PID \(target.pid)：\(String(describing: reason), privacy: .public)")
            }
            guard !self.isStopped else { return }
            self.pollNow()
        }
    }

    /// 最小化全部客户端。
    func minimizeAll() {
        // 每个客户端各发一个请求；平台的 AX 调用在后台 actor 上，互不等待。
        for client in registry.clients {
            minimize(client)
        }
    }

    // MARK: - 全局开关

    /// 切换「全部隐藏」。
    func toggleHideAll() {
        setHideAll(!session.hideAll)
    }

    /// 设置「全部隐藏」。
    func setHideAll(_ hidden: Bool) {
        guard session.hideAll != hidden else { return }
        session.hideAll = hidden
        setNeedsReplan()
    }

    /// 切换当前配置方案。
    /// 切换后协调器在 configDidChange 里清空跳过名单并重新注册热键。
    func switchProfile(to id: String) {
        guard config.config.profile(withID: id) != nil else { return }
        config.update { $0.activeProfileID = id }
    }

    /// 恢复被用户在系统录制指示器里停止的捕获。
    /// 恢复后立即重算，让捕获服务按当前规格重新建流。
    func resumeCapture(_ id: WindowID) {
        services.capture.resume(id)
        setNeedsReplan()
    }

    /// 处于「用户已停止」状态的客户端。
    var stoppedClients: [EVEClient] {
        registry.clients.filter { captureStates[$0.id] == .stoppedByUser }
    }

    // MARK: - 按角色的设置

    /// 切换某个角色在本次会话内的「跳过循环」。
    func toggleSkip(_ name: String) {
        if session.skippedCharacters.remove(name) == nil {
            session.skippedCharacters.insert(name)
        }
        setNeedsReplan()
    }

    /// 把角色加进隐藏名单（持久化到当前配置方案）。
    func hideCharacter(_ name: String) {
        config.updateActiveProfile { profile in
            if !profile.hiddenCharacters.contains(name) { profile.hiddenCharacters.append(name) }
        }
    }

    /// 清掉角色的尺寸记录，恢复默认尺寸，位置不变。
    func resetSize(_ name: String) {
        config.updateActiveProfile { profile in
            profile.layouts[name]?.width = nil
            profile.layouts[name]?.height = nil
        }
    }

    /// 登录与未知客户端按 PID 升序（再按窗口 ID）的序号，与规划器的层叠顺序一致。
    func loginIndex(of client: EVEClient) -> Int {
        let loginClients = registry.clients.filter { $0.characterName == nil }
            .sorted { ($0.pid, $0.id.rawValue) < ($1.pid, $1.id.rawValue) }
        return loginClients.firstIndex { $0.id == client.id } ?? 0
    }
}

// MARK: - 缩略图面板的回调

extension AppCoordinator: ThumbnailPanelDelegate {
    /// 左键点缩略图：切换到对应客户端。客户端已在本轮轮询中消失时忽略。
    func thumbnailClicked(_ id: WindowID) {
        guard let client = registry.client(withID: id) else { return }
        activate(client)
    }

    /// Ctrl+左键：最小化对应客户端。
    func thumbnailMinimizeRequested(_ id: WindowID) {
        guard let client = registry.client(withID: id) else { return }
        minimize(client)
    }

    /// 悬停变化。离开时只清掉自己的悬停，避免相邻缩略图的进入事件先到、被这里覆盖。
    func hoverChanged(_ id: WindowID, isHovering: Bool) {
        if isHovering {
            session.hoveredWindow = id
        } else if session.hoveredWindow == id {
            session.hoveredWindow = nil
        }
        setNeedsReplan()
    }

    /// 拖动开始前给出上下文：基准 frame、显示的 frame、吸附与尺寸约束、吸附目标（其他可见缩略图与屏幕）。
    ///
    /// 悬停放大时面板显示的是放大后的 frame：缩放边缘按它判断（用户按住的是放大后的边），
    /// 拖动本身从基准 frame 开始，否则松开后会把放大的尺寸存下来（架构文档 5.6 节：拖动中不放大）。
    func dragContext(for id: WindowID) -> ThumbnailDragContext? {
        guard let client = registry.client(withID: id),
              let controller = windowManager.controller(for: id) else { return nil }
        let presentation = controller.presentation
        let settings = profile.thumbnail
        let displayed = controller.currentFrame
        // 起点取规划器给出的精确 frame，不取 panel.frame：AppKit 会把面板的原点向下取整、尺寸向上取整，
        // 带小数的布局在每次拖动开始时会跳动最多 1 点。显示的 frame 只用于判断按住的是哪条边。
        var start = presentation.frame
        if presentation.isZoomed {
            start = start.scaled(by: 1.0 / Double(settings.zoomFactor), anchor: settings.zoomAnchor.unitPosition)
        }
        return ThumbnailDragContext(
            startFrame: start, edgeFrame: displayed,
            isLocked: profile.behavior.lockLayout, snapEnabled: settings.snapEnabled,
            lockAspectRatio: settings.lockAspectRatio, allowsResize: client.characterName != nil,
            minimumSize: settings.minimumSize, maximumSize: settings.maximumSize,
            // 吸附目标另加可见的预警与翻译浮窗（docs/macos/design-intel-translate.md 9.3 节）。
            targets: SnapTargets(neighbors: windowManager.visibleFrames(excluding: id)
                                    + overlayManager.visibleFrames(excluding: nil), screenInfos: screens))
    }

    /// 拖动开始：标记为交互中，规划器不再放大它，面板管理器不再改它的 frame。
    func dragBegan(_ id: WindowID) {
        session.interactingWindows.insert(id)
        setNeedsReplan()
    }

    /// 松开鼠标：把最终 frame 写进当前配置方案，并在同一回合清掉拖动状态，下一次重算即用新布局。
    ///
    /// 角色写 `layouts[角色名]`，尺寸与默认尺寸相同时宽高写 nil；
    /// 登录与未知客户端写 `loginPosition`，扣掉层叠偏移。
    func dragEnded(_ id: WindowID, frame: ScreenRect) {
        session.interactingWindows.remove(id)
        defer { setNeedsReplan() }
        guard let client = registry.client(withID: id) else { return }
        let defaultSize = profile.thumbnail.defaultSize
        // 尺寸与默认尺寸相差不到半点时视为默认，写 nil，以后改默认尺寸时这个缩略图跟着变。
        let isDefaultSize = abs(frame.width - defaultSize.width) < 0.5 && abs(frame.height - defaultSize.height) < 0.5
        if let name = client.characterName {
            config.updateActiveProfile { profile in
                profile.layouts[name] = ThumbnailLayout(x: frame.x, y: frame.y,
                                                        width: isDefaultSize ? nil : frame.width,
                                                        height: isDefaultSize ? nil : frame.height)
            }
        } else {
            let offset = LayoutResolver.loginCascadeOffset * Double(loginIndex(of: client))
            config.updateActiveProfile { $0.loginPosition = ScreenPoint(x: frame.x - offset, y: frame.y - offset) }
        }
    }

    /// 右键单击：按当前状态构建菜单并弹出。菜单项的执行回到 perform(_:on:)。
    func thumbnailMenuRequested(_ id: WindowID, event: NSEvent, in view: NSView) {
        guard let client = registry.client(withID: id) else { return }
        let name = client.characterName
        let model = ThumbnailContextMenu.Model(
            canMinimize: permissions.accessibility, characterName: name,
            isSkipped: name.map { session.skippedCharacters.contains($0) } ?? false,
            hasCustomSize: name.flatMap { profile.layouts[$0]?.width } != nil,
            isCaptureStopped: captureStates[id] == .stoppedByUser)
        let menu = ThumbnailContextMenu.make(model) { [weak self] action in
            self?.perform(action, on: client)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// 执行右键菜单里选中的动作。
    private func perform(_ action: ThumbnailContextMenu.Action, on client: EVEClient) {
        // 按角色的动作对登录客户端没有意义，菜单里已置灰；这里再判断一次。
        let name = client.characterName
        switch action {
        case .minimize: minimize(client)
        case .minimizeAll: minimizeAll()
        case .toggleSkip: if let name { toggleSkip(name) }
        case .hide: if let name { hideCharacter(name) }
        case .resetSize: if let name { resetSize(name) }
        case .resumeCapture: resumeCapture(client.id)
        case .openSettings: openSettings?(.previews)
        }
    }
}
