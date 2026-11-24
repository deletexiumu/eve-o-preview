// SPDX-License-Identifier: GPL-3.0-or-later
//
// 位置记录：两个来源、没变时返回假、补读只写更新的、手动位置、兜底规则、角色名的大小写、出发点。
// 角色名是虚构的；线索的正文按位置线索的句式写，星系取自星图数据的夹具。

use crate::chat_log::tracker::{CharacterLocation, LocationOrigin, LocationSource, LocationTracker};
use crate::chat_log::{LocationHint, LocationHintSource};
use crate::static_data::tests::{AMARR, HEK, JITA, PERIMETER, URLEN, data};

/// 一条游戏日志的线索（时间 100，角色 Kael Doran，运行中）。
fn hint(text: &str) -> LocationHint {
    LocationHint {
        character: "Kael Doran".into(),
        time: 100.0,
        source: LocationHintSource::GameLog,
        text: text.into(),
        is_backfill: false,
    }
}

/// 换一个时间。
fn at(mut hint: LocationHint, time: f64) -> LocationHint {
    hint.time = time;
    hint
}

/// 改成 Local 的线索。
fn local(mut hint: LocationHint) -> LocationHint {
    hint.source = LocationHintSource::LocalChannel;
    hint
}

/// 改成补读的线索。
fn backfill(mut hint: LocationHint) -> LocationHint {
    hint.is_backfill = true;
    hint
}

/// Kael Doran 所在的星系。
fn system(tracker: &LocationTracker) -> Option<i64> {
    tracker.locations().get("Kael Doran").map(|l| l.system_id)
}

/// Local 的系统消息与游戏日志的跳跃、离站记录各自生效。
#[test]
fn both_sources_apply() {
    let data = data();
    let mut tracker = LocationTracker::default();
    // Local 的系统消息：英文句式直接取星系名。
    assert!(tracker.apply(&local(hint("Channel changed to Local : Jita")), &data));
    assert_eq!(
        tracker.locations().get("Kael Doran"),
        Some(&CharacterLocation {
            system_id: JITA,
            time: 100.0,
            source: LocationSource::LocalChannel
        })
    );
    // 游戏日志的中文跳跃句：取目的星系，来源改成游戏日志。
    assert!(tracker.apply(&at(hint("从吉他*跳到皮尔米特*"), 110.0), &data));
    assert_eq!(system(&tracker), Some(PERIMETER));
    assert_eq!(tracker.locations()["Kael Doran"].source, LocationSource::GameLog);
    // 离站句：取进入的星系。
    assert!(tracker.apply(
        &at(hint("正在从 某空间站* 离站进入 赫克* 恒星系。"), 120.0),
        &data
    ));
    assert_eq!(system(&tracker), Some(HEK));
}

/// 星系与来源都没变时返回假，但时间更新。
#[test]
fn unchanged_returns_false() {
    let data = data();
    let mut tracker = LocationTracker::default();
    tracker.apply(&hint("从吉他*跳到赫克*"), &data);
    assert!(!tracker.apply(&at(hint("从吉他*跳到赫克*"), 200.0), &data));
    assert_eq!(tracker.locations()["Kael Doran"].time, 200.0);
}

/// 补读的线索只在没有记录或时间更晚时写入；运行中的线索不比较时间。
#[test]
fn backfill_only_when_newer() {
    let data = data();
    let mut tracker = LocationTracker::default();
    tracker.apply(&at(hint("从吉他*跳到赫克*"), 200.0), &data);
    // 补读的线索比记录旧：不写。
    assert!(!tracker.apply(&backfill(at(hint("从吉他*跳到艾玛*"), 150.0)), &data));
    assert_eq!(system(&tracker), Some(HEK));
    assert!(tracker.apply(&backfill(at(hint("从吉他*跳到艾玛*"), 250.0)), &data));
    assert_eq!(system(&tracker), Some(AMARR));
    // 运行中的线索时间更早也写入：游戏时间与本机时钟可能差几秒。
    assert!(tracker.apply(&at(hint("从吉他*跳到乌尔仑*"), 10.0), &data));
    assert_eq!(system(&tracker), Some(URLEN));
}

/// 手动位置被之后的线索覆盖；set_manual(None) 删除；manual_locations 只含手动的记录；
/// 补读的线索比恢复出来的手动位置旧时不写入。
#[test]
fn manual_locations() {
    let data = data();
    let manual = CharacterLocation {
        system_id: JITA,
        time: 50.0,
        source: LocationSource::Manual,
    };
    let mut tracker = LocationTracker::new([("Kael Doran".to_owned(), manual)].into(), None);
    assert_eq!(tracker.manual_locations().len(), 1);
    assert!(tracker.set_manual("Mira Voss", Some(HEK), 60.0));
    // 大小写不同的同一个角色：记录没变。
    assert!(!tracker.set_manual("MIRA VOSS", Some(HEK), 70.0));
    let keys = |t: &LocationTracker| t.manual_locations().into_keys().collect::<Vec<_>>();
    assert_eq!(keys(&tracker), ["Kael Doran", "Mira Voss"]);
    // 自动来源覆盖了 Kael Doran 的手动位置，它不再写进 state.json。
    tracker.apply(&at(hint("从吉他*跳到艾玛*"), 80.0), &data);
    assert_eq!(keys(&tracker), ["Mira Voss"]);
    assert!(tracker.set_manual("mira voss", None, 90.0));
    assert!(!tracker.set_manual("Mira Voss", None, 90.0));
    assert!(tracker.manual_locations().is_empty());

    // 从 state.json 恢复的手动位置比补读的线索新：保留手动位置。
    let restored = CharacterLocation {
        time: 500.0,
        ..manual
    };
    let mut tracker = LocationTracker::new([("Kael Doran".to_owned(), restored)].into(), None);
    assert!(!tracker.apply(&backfill(at(hint("从吉他*跳到赫克*"), 400.0)), &data));
    assert_eq!(tracker.locations()["Kael Doran"].source, LocationSource::Manual);
}

/// 句式不认识时取正文里的星系；星系名查不到时不改记录。
#[test]
fn fallback_and_unknown() {
    let data = data();
    let mut tracker = LocationTracker::default();
    // 俄文句式不在表里：兜底找到 2 个星系，取后一个。
    assert!(tracker.apply(&hint("Прыжок из Jita в Perimeter"), &data));
    assert_eq!(system(&tracker), Some(PERIMETER));
    // 目的星系名查不到：游戏日志的行里只认得出出发的吉他（1 个星系），不用这条线索。
    assert!(!tracker.apply(&at(hint("从吉他*跳到不存在*"), 200.0), &data));
    assert_eq!(system(&tracker), Some(PERIMETER));
    let mut empty = LocationTracker::default();
    assert!(!empty.apply(&hint("Jumping from Nowhere to Elsewhere"), &data));
    assert!(empty.locations().is_empty());
}

/// 兜底按星系个数：2 个取后一个（日文、韩文动词在句末）；1 个只认 Local、且星系在正文末尾；3 个以上不用。
#[test]
fn fallback_conditions() {
    let data = data();
    let mut tracker = LocationTracker::default();
    assert!(tracker.apply(&hint("Saut de Jita vers Hek."), &data));
    assert_eq!(system(&tracker), Some(HEK));
    // 日文语序：目的星系后面还有动词，仍取后一个。
    assert!(tracker.apply(&at(hint("Jita から Amarr へジャンプしています"), 110.0), &data));
    assert_eq!(system(&tracker), Some(AMARR));
    assert!(tracker.apply(&at(hint("赫克에서 乌尔仑(으)로 점프 중입니다"), 120.0), &data));
    assert_eq!(system(&tracker), Some(URLEN));
    // 游戏日志只有 1 个星系：设置目的地、请求停靠都不是位置。
    assert!(!tracker.apply(&at(hint("Autopilot destination set to Hek"), 130.0), &data));
    assert!(!tracker.apply(&at(hint("Jita 정거장 도킹 요청이 수락되었습니다"), 140.0), &data));
    // 3 个星系：分不清哪个是位置。
    assert!(!tracker.apply(&at(hint("Jita Hek Amarr"), 150.0), &data));
    assert_eq!(system(&tracker), Some(URLEN));
    // Local 的线索只有 1 个星系、后面只有全角标点和空格：用。
    assert!(tracker.apply(&local(at(hint("Sprung nach Amarr！ "), 160.0)), &data));
    assert_eq!(system(&tracker), Some(AMARR));
    // 星系后面还有词：不用。
    assert!(!tracker.apply(&local(at(hint("Hek gate camp"), 170.0)), &data));
    assert_eq!(system(&tracker), Some(AMARR));
}

/// 角色名先原样比较，再不区分大小写比较；出发点的 3 种结果。
#[test]
fn character_keys_and_origins() {
    let data = data();
    let mut tracker = LocationTracker::default();
    assert_eq!(tracker.origin(Some("Kael Doran")), LocationOrigin::Unknown);
    assert_eq!(tracker.origin(None), LocationOrigin::Unknown);
    tracker.reference_system_id = Some(AMARR);
    assert_eq!(
        tracker.origin(Some("Kael Doran")),
        LocationOrigin::Reference(AMARR)
    );
    tracker.apply(&hint("从吉他*跳到赫克*"), &data);
    let mut shouting = at(hint("从吉他*跳到艾玛*"), 200.0);
    shouting.character = "KAEL DORAN".into();
    // 全大写的角色名写进同一条记录。
    tracker.apply(&shouting, &data);
    assert_eq!(tracker.locations().len(), 1);
    assert_eq!(tracker.origin(Some("kael doran")).system_id(), Some(AMARR));
    assert_eq!(tracker.origin(None), LocationOrigin::Reference(AMARR));
    assert_eq!(LocationOrigin::Unknown.system_id(), None);
}
