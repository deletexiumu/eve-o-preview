// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒的事件序列用例：按开关与日志目录要求启停跟踪，受击事件按角色名找客户端并延长提醒。

use eveo_core::combat_log::CombatLineKind::{IncomingDamage, IncomingMiss, OutgoingDamage};
use eveo_core::combat_log::{CombatLineKind, CombatLogEvent};
use eveo_core::model::{AppConfig, WindowId};

use super::{config, screens, started, three_characters};
use crate::coordinator::Coordinator;
use crate::event::{Effect, Event};

/// 打开战斗提醒的默认配置，日志目录按给定值。
fn enabled(directory: Option<&str>) -> AppConfig {
    let mut config = config();
    config.general.eve_log_directory = directory.map(str::to_owned);
    if let Some(profile) = config.active_profile_mut() {
        profile.combat_alert.enabled = true;
    }
    config
}

/// 效果里与游戏日志有关的部分。
fn game_log_effects(effects: &[Effect]) -> Vec<Effect> {
    effects
        .iter()
        .filter(|e| matches!(e, Effect::WatchGameLogs(_) | Effect::StopGameLogs))
        .cloned()
        .collect()
}

/// 一个角色的一批事件。
fn hit(character: &str, kind: CombatLineKind) -> Event {
    Event::CombatEvents(vec![CombatLogEvent {
        character: character.into(),
        kind,
    }])
}

/// 正在闪的客户端，按窗口编号排序。
fn flashing(coordinator: &Coordinator) -> Vec<u64> {
    let mut ids: Vec<u64> = coordinator.session.combat_alerts.keys().map(|id| id.0).collect();
    ids.sort_unstable();
    ids
}

/// 默认关闭：启动时不跟踪。打开时要求按自动位置跟踪；改目录时换目录；配置没变时不再发；关闭时停止。
#[test]
fn game_log_follows_settings() {
    let mut coordinator = Coordinator::new(config(), screens());
    assert!(game_log_effects(&coordinator.handle(Event::Started, 1.0)).is_empty());
    let effects = coordinator.handle(Event::ConfigEdited(enabled(None)), 2.0);
    assert_eq!(game_log_effects(&effects), [Effect::WatchGameLogs(None)]);
    let effects = coordinator.handle(Event::ConfigEdited(enabled(Some(r"D:\EVE\logs"))), 3.0);
    assert_eq!(
        game_log_effects(&effects),
        [Effect::WatchGameLogs(Some(r"D:\EVE\logs".into()))]
    );
    // 只改闪烁颜色：跟踪的要求没变，不发效果。
    let mut recolored = enabled(Some(r"D:\EVE\logs"));
    if let Some(profile) = recolored.active_profile_mut() {
        profile.combat_alert.color = "#00FF00".into();
    }
    assert!(game_log_effects(&coordinator.handle(Event::ConfigEdited(recolored), 4.0)).is_empty());
    let effects = coordinator.handle(Event::ConfigEdited(config()), 5.0);
    assert_eq!(game_log_effects(&effects), [Effect::StopGameLogs]);
}

/// 配置里已经打开时，启动就要求跟踪。
#[test]
fn enabled_config_watches_on_start() {
    let mut coordinator = Coordinator::new(enabled(None), screens());
    let effects = coordinator.handle(Event::Started, 1.0);
    assert_eq!(game_log_effects(&effects), [Effect::WatchGameLogs(None)]);
}

/// 受击事件让对应角色的缩略图闪烁，持续时间按当前方案；角色名先按原样比，再不区分大小写比。
#[test]
fn combat_events_flash_matching_client() {
    let mut coordinator = started(enabled(None), three_characters());
    let duration = coordinator.profile().combat_alert.duration_seconds;
    coordinator.handle(hit("Bravo", IncomingDamage(50)), 2.0);
    assert_eq!(flashing(&coordinator), [2]);
    let alert = coordinator.session.combat_alerts[&WindowId(2)];
    assert_eq!((alert.started_at, alert.until), (2.0, 2.0 + duration));
    coordinator.handle(hit("charlie", IncomingMiss), 2.5);
    assert_eq!(flashing(&coordinator), [2, 3]);
    // 持续受击时延长，开始时刻不变。
    coordinator.handle(hit("Bravo", IncomingDamage(5)), 3.0);
    let alert = coordinator.session.combat_alerts[&WindowId(2)];
    assert_eq!((alert.started_at, alert.until), (2.0, 3.0 + duration));
}

/// 不触发的事件：己方造成的伤害、低于最小伤害、关掉未命中后的未命中、没有对应客户端的角色。
#[test]
fn combat_events_filtered_by_settings() {
    let mut config = enabled(None);
    if let Some(profile) = config.active_profile_mut() {
        profile.combat_alert.minimum_damage = 100;
        profile.combat_alert.include_misses = false;
    }
    let mut coordinator = started(config, three_characters());
    coordinator.handle(hit("Alpha", OutgoingDamage(500)), 2.0);
    coordinator.handle(hit("Alpha", IncomingDamage(99)), 2.1);
    coordinator.handle(hit("Alpha", IncomingMiss), 2.2);
    coordinator.handle(hit("Delta", IncomingDamage(1_000)), 2.3);
    assert!(flashing(&coordinator).is_empty());
    coordinator.handle(hit("Alpha", IncomingDamage(100)), 2.4);
    assert_eq!(flashing(&coordinator), [1]);
}

/// 功能关着时，迟到的受击事件不生效；关掉功能时正在闪的提醒被清掉。
#[test]
fn disabled_ignores_events_and_clears_alerts() {
    let mut coordinator = started(config(), three_characters());
    coordinator.handle(hit("Alpha", IncomingDamage(50)), 2.0);
    assert!(flashing(&coordinator).is_empty());
    coordinator.handle(Event::ConfigEdited(enabled(None)), 3.0);
    coordinator.handle(hit("Alpha", IncomingDamage(50)), 3.5);
    assert_eq!(flashing(&coordinator), [1]);
    let effects = coordinator.handle(Event::ConfigEdited(config()), 4.0);
    assert_eq!(game_log_effects(&effects), [Effect::StopGameLogs]);
    assert!(flashing(&coordinator).is_empty());
}
