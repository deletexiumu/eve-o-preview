// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的战斗提醒部分，对应 macOS 的 AppCoordinator+CombatAlerts.swift（反馈文档 7.7 节）：
// - apply_game_log_settings：当前配置方案的 combatAlert.enabled 为真时按 general.eveLogDirectory 要求跟踪，
//   否则要求停止并清掉正在闪的提醒。要求没变时不发效果；是否读日志只在这里把关，规划器不看 enabled。
// - combat_events：过一遍提醒规则（最小伤害、未命中），按收听者找客户端，延长它的提醒，然后重算。
// - test_combat_alert：「测试闪烁」，给全部客户端各设一条提醒，不要求功能已打开。
// 提醒对全部客户端生效，包括活动客户端（用户的决定）。

use eveo_core::combat_log::CombatLogEvent;
use eveo_core::combat_log::rules::triggers;
use eveo_core::model::WindowId;
use eveo_core::planning::CombatAlertWindow;

use super::Coordinator;
use crate::event::Effect;

impl Coordinator {
    /// 按当前配置方案要求开始、切换或停止跟踪游戏日志。在启动与每次配置变化后调用。
    pub(super) fn apply_game_log_settings(&mut self) {
        let target = self
            .profile()
            .combat_alert
            .enabled
            .then(|| self.config.general.eve_log_directory.clone());
        if target == self.game_log {
            return;
        }
        match &target {
            Some(directory) => self.effects.push(Effect::WatchGameLogs(directory.clone())),
            None => {
                self.effects.push(Effect::StopGameLogs);
                // 关掉功能后，正在闪的提醒随之清掉，不等它到期。
                if !self.session.combat_alerts.is_empty() {
                    self.session.combat_alerts.clear();
                    self.needs_replan = true;
                }
            }
        }
        self.game_log = target;
    }

    /// 一批受击事件：按配置过滤，找到角色对应的客户端后延长它的提醒。
    pub(super) fn combat_events(&mut self, events: &[CombatLogEvent]) {
        let settings = self.profile().combat_alert.clone();
        // 关掉功能后，已经排在队列里的事件不再生效。
        if !settings.enabled {
            return;
        }
        for event in events.iter().filter(|e| triggers(e.kind, &settings)) {
            for id in self.clients_for_character(&event.character) {
                let existing = self.session.combat_alerts.get(&id).copied();
                self.session.combat_alerts.insert(
                    id,
                    CombatAlertWindow::extended(existing, self.now, settings.duration_seconds),
                );
                self.needs_replan = true;
            }
        }
    }

    /// 「测试闪烁」：给当前全部客户端（含登录界面的客户端）各设一条提醒，同 macOS 的 testCombatAlert。
    /// 正在闪的客户端按规则延长，不会缩短。到期由重算开头清掉，唤醒时刻由规划给出。
    pub(super) fn test_combat_alert(&mut self) {
        let duration = self.profile().combat_alert.duration_seconds;
        let now = self.now;
        for client in self.registry.clients() {
            let existing = self.session.combat_alerts.get(&client.id).copied();
            self.session
                .combat_alerts
                .insert(client.id, CombatAlertWindow::extended(existing, now, duration));
        }
        self.needs_replan = true;
    }

    /// 按 7.5 节的比较办法找角色的客户端：先按原样比较，没有相等的再不区分大小写比较。
    fn clients_for_character(&self, name: &str) -> Vec<WindowId> {
        let clients = self.registry.clients();
        let exact: Vec<WindowId> = clients
            .iter()
            .filter(|c| c.character_name() == Some(name))
            .map(|c| c.id)
            .collect();
        if !exact.is_empty() {
            return exact;
        }
        let lower = name.to_lowercase();
        clients
            .iter()
            .filter(|c| c.character_name().is_some_and(|n| n.to_lowercase() == lower))
            .map(|c| c.id)
            .collect()
    }
}
