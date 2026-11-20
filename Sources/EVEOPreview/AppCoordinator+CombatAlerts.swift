// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的战斗提醒部分（反馈文档 7.7 节）：
// - startCombatAlerts()：在 start() 里调用。设置 services.combatLog 的两个回调，再按配置启动或停止跟踪。
// - applyCombatLogSettings()：当前配置方案的 combatAlert.enabled 为真时按 general.eveLogDirectory 启动跟踪，
//   否则停止。是否读日志只在这里把关，规划器不看 enabled。
// - combatSettingsDidChange(old:new:)：enabled、eveLogDirectory 或活动配置方案变了时重新应用。
// - combatEventsArrived(_:)：过 CombatAlertRules.triggers，按收听者找客户端，延长它的提醒，然后重算。
// - pruneCombatAlerts()：在每次重算开头删掉 until <= now 的项。
// - testCombatAlert()：给当前全部客户端（含登录客户端）各设一条提醒，供「测试闪烁」按钮使用。
// 提醒对全部客户端生效，包括活动客户端（用户的决定）。系统日志里的角色名按 .private 记录。

import Foundation
import EVEOPreviewCore

extension AppCoordinator {
    /// 接上游戏日志服务的回调并按配置启动跟踪。
    func startCombatAlerts() {
        services.combatLog.onEvents = { [weak self] events in self?.combatEventsArrived(events) }
        services.combatLog.onStatusChange = { [weak self] status in self?.combatLogStatusChanged(status) }
        combatLogStatus = services.combatLog.status
        applyCombatLogSettings()
    }

    /// 按当前配置方案启动或停止跟踪。目录与上次相同时，跟踪服务自己不做任何事。
    func applyCombatLogSettings() {
        guard !isStopped else { return }
        if profile.combatAlert.enabled {
            services.combatLog.start(directory: config.config.general.eveLogDirectory)
        } else {
            services.combatLog.stop()
            // 关掉功能后，正在闪的提醒随之清掉，不等它到期。
            if !session.combatAlerts.isEmpty {
                session.combatAlerts = [:]
                setNeedsReplan()
            }
        }
        updateBackgroundActivity()
    }

    /// 配置变化后调用，参数是变化前后的完整配置。
    func combatSettingsDidChange(old: AppConfig, new: AppConfig) {
        let changed = old.activeProfileID != new.activeProfileID
            || old.activeProfile.combatAlert.enabled != new.activeProfile.combatAlert.enabled
            || old.general.eveLogDirectory != new.general.eveLogDirectory
        if changed {
            applyCombatLogSettings()
        }
    }

    /// 删掉到期的战斗提醒。每次重算开头调用。
    func pruneCombatAlerts() {
        let current = now
        guard session.combatAlerts.values.contains(where: { !$0.isActive(at: current) }) else { return }
        session.combatAlerts = session.combatAlerts.filter { $0.value.isActive(at: current) }
    }

    /// 给当前全部客户端（含登录客户端）各设一条提醒，时长取 `combatAlert.durationSeconds`。
    /// 不要求 `enabled` 为真，供「提醒」页的「测试闪烁」按钮使用。
    func testCombatAlert() {
        let duration = profile.combatAlert.durationSeconds
        let current = now
        for client in registry.clients {
            session.combatAlerts[client.id] = CombatAlertRules.extended(
                session.combatAlerts[client.id], now: current, duration: duration)
        }
        setNeedsReplan()
    }

    // MARK: - 回调

    /// 一批受击事件：按配置过滤，找到角色对应的客户端后延长它的提醒。
    private func combatEventsArrived(_ events: [CombatLogEvent]) {
        let settings = profile.combatAlert
        // 关掉功能后，已经排在主线程队列里的事件不再生效。
        guard !isStopped, settings.enabled else { return }
        let current = now
        var changed = false
        for event in events where CombatAlertRules.triggers(event.kind, settings: settings) {
            let matches = clients(forCharacter: event.character)
            if matches.isEmpty {
                log.debug("受击事件没有对应的客户端：\(event.character, privacy: .private)")
            }
            for client in matches {
                session.combatAlerts[client.id] = CombatAlertRules.extended(
                    session.combatAlerts[client.id], now: current, duration: settings.durationSeconds)
                changed = true
            }
        }
        if changed {
            setNeedsReplan()
        }
    }

    /// 跟踪服务的状态变了：记下并通知设置窗口。
    private func combatLogStatusChanged(_ status: CombatLogStatus) {
        guard combatLogStatus != status else { return }
        combatLogStatus = status
        notifyRuntimeObservers()
    }

    /// 按 7.5 节的比较办法找角色的客户端：先按原样比较，没有相等的再不区分大小写比较。
    private func clients(forCharacter name: String) -> [EVEClient] {
        let exact = registry.clients.filter { $0.characterName == name }
        if !exact.isEmpty { return exact }
        return registry.clients.filter {
            $0.characterName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
