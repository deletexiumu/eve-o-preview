// SPDX-License-Identifier: GPL-3.0-or-later
//
// 提醒规则与历史回放过滤的用例，对应 macOS 的 CombatAlertRulesTests.swift、CombatLogReplayTests.swift，
// 以及 CombatLogEdgeCaseTests.swift 里事件合并的部分。提醒时段的延长在 planning 里，有它自己的用例。

use crate::combat_log::replay::{TOLERANCE, should_keep};
use crate::combat_log::rules::{events, triggers};
use crate::combat_log::{CombatLineKind, CombatLineKind::*, CombatLogEvent};
use crate::model::CombatAlertSettings;

/// 角色 X 的一条事件。
fn event(kind: CombatLineKind) -> CombatLogEvent {
    CombatLogEvent {
        character: "X".into(),
        kind,
    }
}

/// 默认设置（最小伤害 1，未命中也提醒），按需改两项。
fn settings(minimum_damage: i64, include_misses: bool) -> CombatAlertSettings {
    CombatAlertSettings {
        minimum_damage,
        include_misses,
        ..CombatAlertSettings::default()
    }
}

/// 合并一批行后，是否至少有一条事件会提醒。
fn alerts(kinds: &[CombatLineKind], settings: &CombatAlertSettings) -> bool {
    events("X", kinds).iter().any(|e| triggers(e.kind, settings))
}

/// 一次读取里只上报伤害最大的一条与一条未命中；其他种类不上报。
#[test]
fn events_coalesced() {
    let kinds = [
        IncomingDamage(12),
        OutgoingDamage(900),
        IncomingDamage(87),
        IncomingMiss,
        IncomingMiss,
        IncomingDamage(3),
        OtherCombat,
        Other,
        OutgoingMiss,
    ];
    assert_eq!(
        events("Aurora Vale", &kinds),
        [
            CombatLogEvent {
                character: "Aurora Vale".into(),
                kind: IncomingDamage(87)
            },
            CombatLogEvent {
                character: "Aurora Vale".into(),
                kind: IncomingMiss
            },
        ]
    );
}

/// 只有己方的行或非战斗行时没有事件；只有未命中时只有一条；数字为 0 的命中的几种组合。
#[test]
fn events_only_for_incoming_and_zero_hits() {
    assert!(events("X", &[OutgoingDamage(5), Other, OtherCombat]).is_empty());
    assert_eq!(events("X", &[IncomingMiss]), [event(IncomingMiss)]);
    assert_eq!(events("X", &[IncomingDamage(0)]), [event(IncomingDamage(0))]);
    // 0 加正数伤害：「最大伤害 + 未命中」两条，仍不超过两条；只有 0 时只有一条伤害事件。
    assert_eq!(
        events("X", &[IncomingDamage(0), IncomingDamage(5)]),
        [event(IncomingDamage(5)), event(IncomingMiss)]
    );
    assert_eq!(
        events("X", &[IncomingDamage(0), IncomingDamage(0)]),
        [event(IncomingDamage(0))]
    );
    assert_eq!(
        events("X", &[IncomingDamage(0), IncomingMiss, IncomingDamage(5)]).len(),
        2
    );
}

/// 触发表的每一行；关掉未命中后，未命中与数字为 0 的伤害都不提醒，正常伤害照常提醒。
#[test]
fn trigger_table() {
    let defaults = CombatAlertSettings::default();
    assert!(triggers(IncomingDamage(1), &defaults));
    assert!(triggers(IncomingDamage(0), &defaults));
    assert!(triggers(IncomingMiss, &defaults));
    for kind in [OutgoingDamage(500), OutgoingMiss, OtherCombat, Other] {
        assert!(!triggers(kind, &defaults), "{kind:?}");
    }
    let no_misses = settings(1, false);
    assert!(!triggers(IncomingMiss, &no_misses));
    assert!(!triggers(IncomingDamage(0), &no_misses));
    assert!(triggers(IncomingDamage(1), &no_misses));
}

/// 最小伤害的边界：等于阈值提醒，小于阈值不提醒（数字为 0 仍按未命中处理）；极大的数字照常比较。
#[test]
fn minimum_damage_boundary() {
    let s = settings(100, true);
    assert!(triggers(IncomingDamage(100), &s));
    assert!(!triggers(IncomingDamage(99), &s));
    assert!(triggers(IncomingDamage(0), &s));
    assert!(!triggers(IncomingDamage(0), &settings(100, false)));
    let top = settings(100_000, true);
    assert!(alerts(&[IncomingDamage(i64::MAX)], &top));
    assert!(alerts(&[IncomingDamage(100_000)], &top));
    assert!(!alerts(&[IncomingDamage(99_999)], &top));
}

/// 小于阈值的伤害加一次未命中按未命中提醒；数字为 0 的命中不会被同批里较小的正数伤害盖住。
#[test]
fn coalescing_with_threshold() {
    let s = settings(100, true);
    assert!(alerts(&[IncomingDamage(5), IncomingMiss], &s));
    assert!(!alerts(&[IncomingDamage(5)], &s));
    assert!(alerts(&[IncomingDamage(0)], &s));
    assert!(alerts(&[IncomingDamage(0), IncomingDamage(5)], &s));
    assert!(alerts(&[IncomingDamage(5), IncomingDamage(0)], &s));
    // 关掉未命中后：0 加小伤害不提醒，0 加不小于阈值的伤害提醒。
    let no_misses = settings(100, false);
    assert!(!alerts(&[IncomingDamage(0), IncomingDamage(5)], &no_misses));
    assert!(!alerts(&[IncomingDamage(0)], &no_misses));
    assert!(alerts(&[IncomingDamage(0), IncomingDamage(150)], &no_misses));
}

/// 2026-11-20 12:34:56 UTC 的秒数（与 macOS 的用例相同，不经过任何时区换算）。
const NOON: f64 = 1_795_178_096.0;

/// 带指定时间的一行受到伤害。
fn line(time: &str) -> String {
    format!(
        "[ {time} ] (combat) <color=0xffcc0000><b>19</b> <color=0x77ffffff><font size=10>from</font> Sample Pilot"
    )
}

/// 比接入时刻早很多的行丢弃，新写入的行保留；接入之后才写的行保留。
#[test]
fn replay_old_line_dropped_fresh_line_kept() {
    assert!(!should_keep(&line("2026.11.20 11:00:00"), NOON, TOLERANCE));
    assert!(!should_keep(&line("2026.10.22 10:30:13"), NOON, TOLERANCE));
    assert!(should_keep(&line("2026.11.20 12:34:56"), NOON, TOLERANCE));
    assert!(should_keep(&line("2026.11.20 12:35:30"), NOON, TOLERANCE));
    // 1 小时前后的 UTC 时间串：不论本机时区，结论固定。
    assert!(!should_keep(&line("2026.11.20 11:34:56"), NOON, TOLERANCE));
    assert!(should_keep(&line("2026.11.20 13:34:56"), NOON, TOLERANCE));
}

/// 边界：正好等于「接入时刻减容差」的行保留，早 1 秒的丢弃；容差覆盖保险定时器与时间戳粒度。
#[test]
fn replay_boundary_is_inclusive() {
    assert_eq!(TOLERANCE, 5.0);
    assert!(should_keep(&line("2026.11.20 12:34:51"), NOON, TOLERANCE));
    assert!(!should_keep(&line("2026.11.20 12:34:50"), NOON, TOLERANCE));
    assert!(should_keep(&line("2026.11.20 12:34:46"), NOON, 10.0));
    assert!(!should_keep(&line("2026.11.20 12:34:45"), NOON, 10.0));
    assert!(should_keep(&line("2026.11.20 12:34:53"), NOON, TOLERANCE));
}

/// 时间解析不出来的行丢弃；带 BOM 与 CRLF 的行照常判断。
#[test]
fn replay_unparseable_and_bom() {
    for bad in [
        "not a log line".to_owned(),
        String::new(),
        line("2026.13.20 12:34:56"),
        line("2026.11.20 25:00:00"),
        "[ 2026-11-20 12:34:56 ] (combat) x".to_owned(),
    ] {
        assert!(!should_keep(&bad, NOON, TOLERANCE), "{bad}");
    }
    assert!(should_keep(
        &format!("\u{FEFF}{}\r", line("2026.11.20 12:34:56")),
        NOON,
        TOLERANCE
    ));
    assert!(!should_keep(
        &format!("\u{FEFF}{}\r", line("2026.11.20 10:00:00")),
        NOON,
        TOLERANCE
    ));
}
