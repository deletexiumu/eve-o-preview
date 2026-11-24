// SPDX-License-Identifier: GPL-3.0-or-later
//
// 分段、人数与人名：6.4 节样例表的 8 行，13 种人数写法与边界，数量的归属，人名的合并与条件，remainder。

use super::parse;
use crate::intel::IntelSegmentKind::{Count, Pilot, Plain};
use crate::intel::parser::{is_pilot_candidate, parse_with, remainder};
use crate::intel::{IntelSegment, IntelShipMention};
use crate::static_data::matcher::TermKind::Ship;
use crate::static_data::tests::*;

/// 一艘船的数量。
fn ship(id: i64, count: i64) -> IntelShipMention {
    IntelShipMention {
        kind: Ship(id),
        count,
    }
}

// MARK: 6.4 节样例表的 8 行

/// 中文舰船名带数量；`1门口有泡泡` 里的 1 成为一段人数，其余是普通文字。
#[test]
fn sample_chinese_ships_with_counts() {
    let data = data();
    let report = parse(&data, "1DQ1-A ess 娜迦级海军型 3  剑齿虎级 1门口有泡泡");
    assert_eq!(report.system_ids, [ONE_DQ]);
    assert_eq!(report.ships, [ship(NAGA_NAVY_ISSUE, 3), ship(SABRE, 1)]);
    assert!(report.pilots.is_empty());
    // 3 归给前面的娜迦级海军型，1 归给前面的剑齿虎级：船数之和 4，没有独立人数与人名，所以是 4。
    assert_eq!(report.hostile_count, Some(4));
    // 最大的数来自归给舰船的写明数量，算「写明」。
    assert!(report.count_is_explicit);
    assert!(!report.is_clear && !report.is_no_visual);
    assert!(report.segments.contains(&IntelSegment::new("1", Count(1))));
    assert_eq!(
        report.segments.last(),
        Some(&IntelSegment::new("门口有泡泡", Plain))
    );
}

/// 人名后面括号里是舰船；两个空格分开两个人名。
#[test]
fn sample_pilots_with_ships_in_parentheses() {
    let data = data();
    let report = parse(&data, "Kael Doran (Stabber)  Mira Voss (Astarte)  T5ZI-S* wh");
    assert_eq!(report.system_ids, [T5ZI]);
    assert_eq!(report.ships, [ship(STABBER, 1), ship(ASTARTE, 1)]);
    assert_eq!(report.pilots, ["Kael Doran", "Mira Voss"]);
    // 两个人名、两艘船指的是同一批人：取最大值 2，不相加成 4。
    assert_eq!(report.hostile_count, Some(2));
    // 消息里没有写人数，2 是数出来的，不算「写明」。
    assert!(!report.count_is_explicit);
}

/// 两个空格分开的人名与带 `*` 的中文舰船名。
#[test]
fn sample_pilots_separated_by_double_spaces() {
    let data = data();
    let report = parse(&data, "HED-GP*  Tarn Vex  Ilya Morrow  长剑级*  黑鸦级*");
    assert_eq!(report.system_ids, [HED_GP]);
    assert_eq!(report.ships, [ship(RAPIER, 1), ship(CROW, 1)]);
    // 两个空格不满足「正好一个空格」，所以 Tarn Vex 与 Ilya Morrow 是两个人名，不并成一个 4 个词的串。
    assert_eq!(report.pilots, ["Tarn Vex", "Ilya Morrow"]);
    assert_eq!(report.hostile_count, Some(2));
    assert!(!report.count_is_explicit);
}

/// 一个人名加「未见」。
#[test]
fn sample_pilot_no_visual() {
    let data = data();
    let report = parse(&data, "T5ZI-S Jorn Halden nv");
    assert_eq!(report.system_ids, [T5ZI]);
    assert!(report.ships.is_empty());
    assert_eq!(report.pilots, ["Jorn Halden"]);
    assert_eq!(report.hostile_count, Some(1));
    assert!(!report.count_is_explicit);
    assert!(report.is_no_visual && !report.is_clear);
}

/// 「安全」：敌对数量是 0。
#[test]
fn sample_clear() {
    let data = data();
    let report = parse(&data, "HED-GP* clr");
    assert_eq!(report.system_ids, [HED_GP]);
    assert!(report.pilots.is_empty());
    assert_eq!(report.hostile_count, Some(0));
    assert!(report.is_clear);
}

/// `+5` 是写明的人数。
#[test]
fn sample_plus_count() {
    let data = data();
    let report = parse(&data, "1DQ1-A +5");
    assert_eq!(report.system_ids, [ONE_DQ]);
    assert_eq!(report.hostile_count, Some(5));
    assert!(report.count_is_explicit);
}

/// `3x` 归给后面的舰船。
#[test]
fn sample_leading_count_for_ship() {
    let data = data();
    let report = parse(&data, "3x Naga Jita gate");
    assert_eq!(report.system_ids, [JITA]);
    assert_eq!(report.ships, [ship(NAGA_SHIP, 3)]);
    assert!(report.pilots.is_empty());
    assert_eq!(report.hostile_count, Some(3));
    assert!(report.count_is_explicit);
}

/// 全小写的闲聊：认出星系，但没有人名，敌对数量判断不出。
#[test]
fn sample_lowercase_chat() {
    let data = data();
    let report = parse(&data, "anyone want to roam to Jita later");
    assert_eq!(report.system_ids, [JITA]);
    assert!(report.pilots.is_empty());
    assert_eq!(report.hostile_count, None);
}

// MARK: 人数

/// 13 种人数写法（`x` 的大小写各算一种）。
#[test]
fn count_forms() {
    let data = data();
    for word in [
        "+3", "＋3", "x3", "X3", "×3", "3", "3x", "3×", "3+", "3人", "3个", "3只", "3艘", "3名",
    ] {
        let report = parse(&data, &format!("Jita {word}"));
        assert!(
            report.segments.contains(&IntelSegment::new(word, Count(3))),
            "{word}"
        );
        assert_eq!(report.hostile_count, Some(3), "{word}");
        assert!(report.count_is_explicit, "{word}");
    }
}

/// 数值是 0 与 501、超过 3 位时不算人数；末尾的标点不算在人数里。
#[test]
fn count_bounds() {
    let data = data();
    assert_eq!(parse(&data, "Jita 0").hostile_count, None);
    assert_eq!(parse(&data, "Jita 501").hostile_count, None);
    assert_eq!(parse(&data, "Jita 1000").hostile_count, None);
    let report = parse(&data, "Jita 500,");
    assert_eq!(report.hostile_count, Some(500));
    assert!(report.segments.contains(&IntelSegment::new("500", Count(500))));
}

/// 两个数字分别归给前后的舰船；没有归属的人数取最大的独立人数；前缀写法不归给后面的舰船。
#[test]
fn count_attribution() {
    let data = data();
    let report = parse(&data, "2 Naga 3 Machariel");
    assert_eq!(report.ships, [ship(NAGA_SHIP, 2), ship(MACHARIEL, 3)]);
    assert_eq!(report.hostile_count, Some(5));
    // +2 前面是星系，不归给舰船；+7 归给前面的 Rifter。
    let mixed = parse(&data, "Jita +2 Rifter +7");
    assert_eq!(mixed.ships, [ship(RIFTER, 7)]);
    assert_eq!(mixed.hostile_count, Some(7));
    let prefix = parse(&data, "Jita +3 Rifter");
    assert_eq!(prefix.ships.first().map(|s| s.count), Some(1));
    assert_eq!(prefix.hostile_count, Some(3));
}

// MARK: 人名

/// 隔两个空格的人名不合并；一个人名至多 3 个词，超出的另成一段，中间的空格单独成一段 Plain。
#[test]
fn pilot_grouping() {
    let data = data();
    let report = parse(&data, "Jita  Brenn Ostvar Tyra Kelloway");
    assert_eq!(report.pilots, ["Brenn Ostvar Tyra", "Kelloway"]);
    assert_eq!(
        report.segments[report.segments.len() - 3..],
        [
            IntelSegment::new("Brenn Ostvar Tyra", Pilot),
            IntelSegment::new(" ", Plain),
            IntelSegment::new("Kelloway", Pilot),
        ]
    );
    assert_eq!(report.hostile_count, Some(2));
    assert_eq!(parse(&data, "Jita Kael  Doran").pilots, ["Kael", "Doran"]);
}

/// 标点把人名分开，标点本身是普通文字（与相邻的空白并成一段）。
#[test]
fn punctuation_splits_pilots() {
    let data = data();
    let report = parse(&data, "Jita Mira, Voss");
    assert_eq!(report.pilots, ["Mira", "Voss"]);
    assert!(!report.segments.contains(&IntelSegment::new(",", Plain)));
    assert!(
        report
            .segments
            .iter()
            .any(|s| s.kind == Plain && s.text.contains(','))
    );
}

/// 没有字母的词（时刻 `15:30`、`1/2`）不是人名的候选；有字母和数字的仍是。
#[test]
fn pilot_needs_letter() {
    let data = data();
    assert!(parse(&data, "Jita Rifter 15:30").pilots.is_empty());
    assert!(parse(&data, "Jita Rifter 1/2").pilots.is_empty());
    assert_eq!(parse(&data, "Jita Rifter Kael7").pilots, ["Kael7"]);
    assert!(!is_pilot_candidate("15:30"));
    assert!(is_pilot_candidate("Kael7"));
}

/// 全小写的句子没有人名；没有认出星系或舰船时不推断人名；中文词与常见情报词不是人名。
#[test]
fn pilot_preconditions() {
    let data = data();
    assert!(parse(&data, "Jita gate camp hostile").pilots.is_empty());
    let no_terms = parse(&data, "Kael Doran says hello");
    assert!(no_terms.pilots.is_empty());
    assert_eq!(
        no_terms.segments,
        [IntelSegment::new("Kael Doran says hello", Plain)]
    );
    assert!(parse(&data, "Jita 有人 Gate RED").pilots.is_empty());
    assert_eq!(parse(&data, "Jita K4el").pilots, ["K4el"]);
}

/// remainder：人名不超过 3 个词时不含人名，超过时含。
#[test]
fn remainder_includes_long_pilot_runs() {
    let data = data();
    assert_eq!(remainder(&parse(&data, "Jita Kael Doran gate")), "gate");
    assert!(remainder(&parse(&data, "Jita Kael Doran Mira Voss gate")).contains("Kael Doran Mira"));
}

/// 没有术语的消息只有一段 Plain；空文字没有段。
#[test]
fn plain_messages() {
    let data = data();
    assert_eq!(
        parse(&data, "hello  there").segments,
        [IntelSegment::new("hello  there", Plain)]
    );
    assert!(parse_with("", &data).segments.is_empty());
}
