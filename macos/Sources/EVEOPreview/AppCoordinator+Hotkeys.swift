// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的热键部分（架构文档 5.5 节、6.5 节，反馈文档 6.7 节）。
// HotkeyPlanner 每次规划都从 1 起重新编号，所以注册用的规划与回调查找用的规划必须是同一份：
// 只有 rebuildHotkeys() 改 hotkeyPlan，并且改的同时调用 replaceAll。
// 作用范围是 game 的热键随前台启用或停用：前台变化与权限变化都经这里推给注册器。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 按当前配置方案重新规划热键。规划与当前的相同时不重新注册，避免每次配置变化都注销再注册。
    func rebuildHotkeys() {
        let plan = HotkeyPlanner.plan(for: profile)
        guard plan != hotkeyPlan else { return }
        hotkeyPlan = plan
        reregisterHotkeys()
    }

    /// 前台变化后调用（`refreshFrontmost()` 更新 `frontmost` 之后，每次轮询都会经过这里）。
    ///
    /// 注册器在值没变时不做任何事，所以这里不另外去重；失败项变了才通知设置窗口。
    func frontmostDidChange() {
        updateHotkeyFailures(services.hotkeys.setGameFrontmost(isGameFrontmost))
    }

    /// 权限状态变化后调用（轮询与 `refreshPermissions()` 发现变化时）。
    ///
    /// 辅助功能权限变了就用当前规划重新注册：授权后鼠标绑定自动生效，撤销后事件监听被拆掉，
    /// 鼠标绑定显示「需要辅助功能权限」（反馈文档 6.6 节）。不能走 rebuildHotkeys()：规划没变时它直接返回。
    func permissionsDidChange(old: PermissionStatus, new: PermissionStatus) {
        guard old.accessibility != new.accessibility else { return }
        log.info("辅助功能权限变成 \(new.accessibility)，重新注册热键")
        reregisterHotkeys()
    }

    /// 巡检热键后端：先重读权限（辅助功能权限变了会重新注册），再让注册器检查鼠标事件监听。
    /// 由巡检循环每个轮询周期调用一次，注册器报告问题（`onStateChange`）时也调用。
    func checkHotkeyHealth() {
        guard !isStopped else { return }
        refreshPermissions()
        updateHotkeyFailures(services.hotkeys.checkHealth())
    }

    /// 前台是不是 EVE 客户端。前台是本应用（设置窗口）时不算，作用范围是 game 的热键不生效。
    private var isGameFrontmost: Bool {
        if case .client = frontmost { return true }
        return false
    }

    /// 用当前规划调 replaceAll，再按当前前台补调一次 setGameFrontmost，保证新绑定按前台状态启用。
    /// 失败项取后一次调用的结果，它包含全部当前失败的项。
    private func reregisterHotkeys() {
        services.hotkeys.replaceAll(with: hotkeyPlan.bindings)
        hotkeyFailures = services.hotkeys.setGameFrontmost(isGameFrontmost)
        if !hotkeyFailures.isEmpty {
            log.error("有 \(self.hotkeyFailures.count) 个热键不能生效")
        }
        updateBackgroundActivity()
        notifyRuntimeObservers()
    }

    /// 失败项变了才更新并通知观察者，避免每次轮询都刷新设置窗口。
    private func updateHotkeyFailures(_ failures: [HotkeyRegistrationFailure]) {
        guard failures != hotkeyFailures else { return }
        hotkeyFailures = failures
        updateBackgroundActivity()
        notifyRuntimeObservers()
    }

    /// 录制热键结束后恢复全局热键，并记下恢复时注册失败的项，设置窗口据此提示。
    func resumeHotkeys() {
        // 退出开始后热键保持暂停（stop() 里暂停的），录制窗口此时结束也不恢复。
        guard !isStopped else { return }
        // 录制期间前台可能变过（注册器在暂停期间照样记下前台），恢复时按当前状态注册。
        hotkeyFailures = services.hotkeys.resume()
        if !hotkeyFailures.isEmpty {
            log.error("恢复热键时有 \(self.hotkeyFailures.count) 个注册失败")
        }
        // 鼠标绑定的失败项可能变了，后台活动跟着调整（与其他写 hotkeyFailures 的地方一致）。
        updateBackgroundActivity()
        notifyRuntimeObservers()
    }

    /// 热键触发：在当前规划里按 id 查绑定，再执行动作。退出开始后忽略。
    func hotkeyFired(id: HotkeyBinding.ID) {
        guard !isStopped else { return }
        guard let binding = hotkeyPlan.binding(withID: id) else {
            log.error("收到未知的热键 id \(id)")
            return
        }
        perform(binding.action)
    }

    /// 执行热键动作。
    func perform(_ action: HotkeyAction) {
        switch action {
        case .cycle(let groupID, let direction):
            cycle(groupID: groupID, direction: direction)
        case .activateCharacter(let name):
            if let client = registry.client(named: name) { activate(client) }
        case .cycleLoginClients:
            // 登录客户端循环只有前进方向（上游没有后退热键）。
            cycleLoginClients(direction: .forward)
        case .toggleHideAll:
            toggleHideAll()
        case .minimizeAll:
            minimizeAll()
        }
    }

    /// 活动客户端的 PID：前台是客户端时取它，否则取最近一次处于前台的客户端。
    var activePID: Int32? {
        if case .client(let pid) = frontmost { return pid }
        return session.lastActivePID
    }

    /// 在循环组里前进或后退一步。起点是活动客户端的角色名（见 6.5 节）。
    func cycle(groupID: String, direction: CycleDirection) {
        guard let group = profile.cycleGroups.first(where: { $0.id == groupID }) else { return }
        // 起点：活动客户端的角色名；活动的是登录客户端或没有活动客户端时为 nil，从组的第一个成员开始。
        let active = activePID.flatMap { registry.client(withPID: $0)?.characterName }
        // 只在在线的角色之间循环，离线成员自动跳过。
        let running = Set(registry.clients.compactMap(\.characterName))
        guard let next = CycleEngine.next(in: group.members, direction: direction, active: active,
                                          running: running, skipped: session.skippedCharacters),
              let client = registry.client(named: next) else { return }
        activate(client)
    }

    /// 在登录与未知客户端之间循环，按 PID 升序。
    func cycleLoginClients(direction: CycleDirection) {
        // 登录与未知客户端都参与，按 PID 升序，与缩略图的层叠顺序一致。
        let pids = registry.clients.filter { $0.characterName == nil }.map(\.pid).sorted()
        guard let pid = CycleEngine.nextLoginClient(pids: pids, activePID: activePID, direction: direction),
              let client = registry.client(withPID: pid) else { return }
        activate(client)
    }
}
