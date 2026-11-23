// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒的规则（反馈文档 7.7 节），对应 macOS 的 CombatAlertRules.swift：
// - events：一次读取里一个文件至多产生两条受击事件（伤害最大的一条与未命中各一条），其他种类不上报。
//   数字为 0 的命中按未命中对待，不会被同批里较小的正数伤害盖住。
// - triggers：按配置决定一条受击事件是否提醒。
// 提醒时段的延长（持续受击时一直延长，到期后重新开始）在 planning 的 `CombatAlertWindow::extended`。

//! 战斗提醒的规则。

use super::{CombatLineKind, CombatLogEvent};
use crate::model::CombatAlertSettings;

/// 把一次读取得到的各行归类结果合并成至多两条事件。
///
/// 有 `IncomingDamage` 时上报其中数字最大的一条；有 `IncomingMiss` 时另外上报一条。两种各自上报，
/// 所以「一次小于阈值的伤害加一次未命中」仍能按未命中触发提醒。
/// 数字为 0 的命中属于未命中一类：同批里有正数伤害时，另报一条 `IncomingMiss`，否则 0 会被较大的数字盖住；
/// 同批里没有正数伤害时，上报的伤害事件本身就是 `IncomingDamage(0)`，由 [`triggers`] 按未命中处理。
pub fn events(listener: &str, kinds: &[CombatLineKind]) -> Vec<CombatLogEvent> {
    let mut max_damage: Option<i64> = None;
    let mut saw_miss = false;
    let mut saw_zero_hit = false;
    for kind in kinds {
        match *kind {
            CombatLineKind::IncomingDamage(amount) => {
                max_damage = Some(max_damage.map_or(amount, |m| m.max(amount)));
                saw_zero_hit |= amount == 0;
            }
            CombatLineKind::IncomingMiss => saw_miss = true,
            _ => {}
        }
    }
    let event = |kind| CombatLogEvent {
        character: listener.to_owned(),
        kind,
    };
    let mut result = Vec::new();
    if let Some(amount) = max_damage {
        result.push(event(CombatLineKind::IncomingDamage(amount)));
    }
    // 最大伤害为 0 时，伤害事件已经代表这些 0 命中，不必再报一条未命中。
    if saw_miss || (saw_zero_hit && max_damage.unwrap_or(0) > 0) {
        result.push(event(CombatLineKind::IncomingMiss));
    }
    result
}

/// 一条受击事件是否提醒。
///
/// | 种类 | 条件 |
/// | --- | --- |
/// | `IncomingDamage(amount)` | `amount >= minimum_damage` |
/// | `IncomingDamage(0)` | `include_misses` 为真（数字为 0 的命中按未命中对待） |
/// | `IncomingMiss` | `include_misses` 为真 |
/// | 其他 | 不提醒 |
pub fn triggers(kind: CombatLineKind, settings: &CombatAlertSettings) -> bool {
    match kind {
        CombatLineKind::IncomingDamage(amount) => {
            amount >= settings.minimum_damage || (amount == 0 && settings.include_misses)
        }
        CombatLineKind::IncomingMiss => settings.include_misses,
        _ => false,
    }
}
