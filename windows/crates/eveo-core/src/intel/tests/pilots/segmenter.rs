// SPDX-License-Identifier: GPL-3.0-or-later
//
// 分人：人名段的接回与切开、候选名字、6.9 节样例表的 9 行、选法的细则、有歧义与空缺、整条消息的数量。

use std::collections::HashMap;

use crate::intel::IntelSegmentKind::{self, Pilot, Plain, Ship, System};
use crate::intel::pilots::segmenter::{
    IntelPilot, PilotDirectory, PilotStatus, candidates, combinations, resolve, runs, segment,
};
use crate::intel::pilots::{PilotLookupOutcome, key};
use crate::intel::{IntelReport, IntelSegment};

/// 建目录：一段里查过的组合先都记 NotFound，再把 matched 的记成查到（角色 ID 从 1000 按顺序编），
/// ambiguous 的记成有歧义。
fn directory(run: &[String], matched: &[&str], ambiguous: &[&str]) -> PilotDirectory {
    let mut outcomes: HashMap<String, PilotLookupOutcome> = combinations(run)
        .iter()
        .map(|name| (key(name), PilotLookupOutcome::NotFound))
        .collect();
    for (index, name) in matched.iter().enumerate() {
        outcomes.insert(key(name), PilotLookupOutcome::matched(1_000 + index as i64, name));
    }
    for name in ambiguous {
        outcomes.insert(key(name), PilotLookupOutcome::Ambiguous);
    }
    PilotDirectory::new(outcomes)
}

/// 按空格切成词。
fn words(run: &str) -> Vec<String> {
    run.split(' ').map(str::to_owned).collect()
}

/// 分人结果的简写：(名字, 是否查到)，未核对记 None。
fn split(run: &str, matched: &[&str], ambiguous: &[&str]) -> Vec<(String, Option<bool>)> {
    let run = words(run);
    segment(&run, &directory(&run, matched, ambiguous))
        .into_iter()
        .map(|pilot| {
            let found = match pilot.status {
                PilotStatus::Matched(_) => Some(true),
                PilotStatus::NotFound => Some(false),
                PilotStatus::Unchecked => None,
            };
            (pilot.name, found)
        })
        .collect()
}

/// 只取分出的名字。
fn names(run: &str, matched: &[&str]) -> Vec<String> {
    split(run, matched, &[])
        .into_iter()
        .map(|(name, _)| name)
        .collect()
}

/// 把各段拼成报告。
fn report(parts: &[(&str, IntelSegmentKind)]) -> IntelReport {
    IntelReport {
        segments: parts
            .iter()
            .map(|(text, kind)| IntelSegment::new(text, *kind))
            .collect(),
        ..IntelReport::default()
    }
}

/// 被 6.4 节切开的 4 个词接回一串；隔两个空格、标点或术语时分开。
#[test]
fn runs_join_and_split() {
    // 解析器把 4 个词切成「3 个词 + 1 个词」两段 Pilot，中间是一个空格；分人时要当成一串重新分。
    let value = report(&[
        ("Brenn Ostvar Tyra", Pilot),
        (" ", Plain),
        ("Kelloway", Pilot),
        ("  ", Plain),
        ("Mira Voss", Pilot),
        (", ", Plain),
        ("Kael", Pilot),
        (" ", Plain),
        ("Stabber", Ship(622)),
        (" ", Plain),
        ("Jorn", Pilot),
    ]);
    let expected = [
        words("Brenn Ostvar Tyra Kelloway"),
        words("Mira Voss"),
        words("Kael"),
        words("Jorn"),
    ];
    assert_eq!(runs(&value), expected);
}

/// 一个词的人名段没有候选名字；2 个词 3 个组合，4 个词 9 个组合。
#[test]
fn candidate_counts() {
    assert!(candidates(&report(&[("Mira", Pilot)])).is_empty());
    assert!(candidates(&report(&[("Mira", Pilot), ("  ", Plain), ("Kael", Pilot)])).is_empty());
    assert_eq!(
        candidates(&report(&[("Kael Doran", Pilot)])),
        ["Kael", "Kael Doran", "Doran"]
    );
    let four = report(&[("Brenn Ostvar Tyra", Pilot), (" ", Plain), ("Kelloway", Pilot)]);
    assert_eq!(candidates(&four).len(), 9);
}

/// 按比较键去重；不足 3 个字符或含不允许字符的组合去掉；' 与 - 允许。
#[test]
fn candidate_filtering_and_dedup() {
    let value = report(&[("Kael Doran", Pilot), ("  ", Plain), ("KAEL DORAN", Pilot)]);
    assert_eq!(candidates(&value), ["Kael", "Kael Doran", "Doran"]);
    // 「Al」「Bo」单独不足 3 个字符，只有合起来的「Al Bo」够长。
    assert_eq!(candidates(&report(&[("Al Bo", Pilot)])), ["Al Bo"]);
    // 下划线不是角色名允许的字符，含它的组合都去掉。
    assert_eq!(candidates(&report(&[("Ka_el Doran", Pilot)])), ["Doran"]);
    let apostrophe = candidates(&report(&[("Kael O'Doran-Vex", Pilot)]));
    assert!(apostrophe.contains(&"Kael O'Doran-Vex".to_owned()));
}

/// 6.9 节样例表的 9 行。
#[test]
fn sample_table() {
    // 两个两词名字盖住全部 4 个词，胜过单词名字。
    assert_eq!(
        names(
            "Brenn Ostvar Tyra Kelloway",
            &["Brenn Ostvar", "Tyra Kelloway", "Brenn", "Tyra"]
        ),
        ["Brenn Ostvar", "Tyra Kelloway"]
    );
    assert_eq!(
        names("Kael Doran Mira Voss", &["Kael Doran", "Mira Voss"]),
        ["Kael Doran", "Mira Voss"]
    );
    // 3 个词的名字一个就盖住全部，名字最少。
    assert_eq!(
        names(
            "Jorn Halden Brask",
            &["Jorn Halden Brask", "Jorn Halden", "Brask"]
        ),
        ["Jorn Halden Brask"]
    );
    // 剩下的 Brask 单独没查到：状态是没查到。
    let partial = split("Jorn Halden Brask", &["Jorn Halden", "Halden Brask"], &[]);
    assert_eq!(
        partial,
        [
            ("Jorn Halden".to_owned(), Some(true)),
            ("Brask".to_owned(), Some(false))
        ]
    );
    // 没有多词名字时，空缺里每个词单独都查到：每词一人。
    let singles = split("Tarn Vex Ilya", &["Tarn", "Vex", "Ilya"], &[]);
    assert_eq!(
        singles.iter().map(|p| p.0.as_str()).collect::<Vec<_>>(),
        ["Tarn", "Vex", "Ilya"]
    );
    assert!(singles.iter().all(|p| p.1 == Some(true)));
    assert_eq!(
        names("Ilya Morrow Tarn", &["Ilya Morrow", "Tarn"]),
        ["Ilya Morrow", "Tarn"]
    );
    // 拼错的名字：只有 Kael 单独查到，不够拆，整串一人、没查到。
    assert_eq!(
        split("Kael Dorann", &["Kael"], &[]),
        [("Kael Dorann".to_owned(), Some(false))]
    );
    // 有候选名字还没有结果：整段未核对。
    let pending = segment(
        &words("Jorn Halden"),
        &PilotDirectory::new(HashMap::from([(
            "other".to_owned(),
            PilotLookupOutcome::NotFound,
        )])),
    );
    assert_eq!(pending, [IntelPilot::new("Jorn Halden", PilotStatus::Unchecked)]);
    // 一个词的人名段不查：一人，未核对。
    let single = words("Mira");
    assert_eq!(
        segment(&single, &directory(&single, &["Mira"], &[])),
        [IntelPilot::new("Mira", PilotStatus::Unchecked)]
    );
}

/// 选法的细则：盖住更多、名字更少、从左起长的优先。
#[test]
fn tie_breaks() {
    // 6 个词既能分成 3+3，也能分成 2+2+2：盖住的一样多，取名字少的。
    assert_eq!(
        names(
            "Aa Bb Cc Dd Ee Ff",
            &["Aa Bb", "Cc Dd", "Ee Ff", "Aa Bb Cc", "Dd Ee Ff"]
        ),
        ["Aa Bb Cc", "Dd Ee Ff"]
    );
    // 「Aa Bb Cc」盖 3 个词，胜过「Aa Bb」加空缺。
    assert_eq!(names("Aa Bb Cc", &["Aa Bb Cc", "Aa Bb"]), ["Aa Bb Cc"]);
    // 盖住的词与名字个数都相同时，从左起 3 个词的名字优先。
    assert_eq!(
        names("Aa Bb Cc Dd Ee", &["Aa Bb Cc", "Dd Ee", "Aa Bb", "Cc Dd Ee"]),
        ["Aa Bb Cc", "Dd Ee"]
    );
    // 完全相同时左边先取：Aa Bb 与 Bb Cc 都可用，取 Aa Bb，Cc 成空缺。
    assert_eq!(names("Aa Bb Cc", &["Aa Bb", "Bb Cc"]), ["Aa Bb", "Cc"]);
}

/// Ambiguous 不可用；空缺里只有部分词可用时不拆；ESI 的写法替换原文的大小写。
#[test]
fn ambiguous_and_partial_gaps() {
    // 「Kael Doran」同时是物品名：不当作角色，两个词各自查到，分成两人。
    let value = split("Kael Doran", &["Kael", "Doran"], &["Kael Doran"]);
    assert_eq!(
        value.iter().map(|p| p.0.as_str()).collect::<Vec<_>>(),
        ["Kael", "Doran"]
    );
    // 空缺「Kael Doran Tarn」里只有 Kael 查到：拆开会凭空多出两个没查到的人，所以整串作一人。
    let gap = split("Mira Voss Kael Doran Tarn", &["Mira Voss", "Kael"], &[]);
    assert_eq!(
        gap,
        [
            ("Mira Voss".to_owned(), Some(true)),
            ("Kael Doran Tarn".to_owned(), Some(false))
        ]
    );
    // 消息里写成小写，ESI 返回规范写法，显示时用后者。
    let lower = words("kael doran");
    let dir = PilotDirectory::new(HashMap::from([
        ("kael".to_owned(), PilotLookupOutcome::NotFound),
        ("doran".to_owned(), PilotLookupOutcome::NotFound),
        (
            "kael doran".to_owned(),
            PilotLookupOutcome::matched(7, "Kael Doran"),
        ),
    ]));
    assert_eq!(
        segment(&lower, &dir),
        [IntelPilot::new("Kael Doran", PilotStatus::Matched(7))]
    );
}

/// resolve：目录为空时不变；人数变多时取新人数、不算写明；不超过写明的数量时不变；只报安全时仍是 0。
#[test]
fn resolve_counts() {
    let mut inferred = report(&[
        ("Jita", System(1)),
        (" ", Plain),
        ("Kael Doran Mira", Pilot),
        (" ", Plain),
        ("Voss", Pilot),
    ]);
    inferred.pilots = vec!["Kael Doran Mira".into(), "Voss".into()];
    inferred.hostile_count = Some(2);
    // 联网核对关着（目录为空）：沿用解析器的人名与数量，全部未核对。
    let unchanged = resolve(&inferred, &PilotDirectory::default());
    assert_eq!(
        unchanged.pilots,
        [
            IntelPilot::new("Kael Doran Mira", PilotStatus::Unchecked),
            IntelPilot::new("Voss", PilotStatus::Unchecked)
        ]
    );
    assert_eq!(unchanged.hostile_count, Some(2));

    // 4 个单词名字各自查到：分成 4 人，数量从 2 变成 4。
    let run = words("Kael Doran Mira Voss");
    let more = resolve(
        &inferred,
        &directory(&run, &["Kael", "Doran", "Mira", "Voss"], &[]),
    );
    assert_eq!(more.pilots.len(), 4);
    assert_eq!(more.hostile_count, Some(4));
    assert!(!more.count_is_explicit);

    // 消息写明 6 个人，只认出 2 个人名：数量保持 6，仍算写明。
    let mut explicit = inferred.clone();
    explicit.hostile_count = Some(6);
    explicit.count_is_explicit = true;
    let same = resolve(&explicit, &directory(&run, &["Kael Doran", "Mira Voss"], &[]));
    let same_names: Vec<&str> = same.pilots.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(same_names, ["Kael Doran", "Mira Voss"]);
    assert_eq!(same.hostile_count, Some(6));
    assert!(same.count_is_explicit);

    // 只报安全、没有人名的消息：没有人名段可分，数量保持 0。
    let clear = IntelReport {
        segments: vec![IntelSegment::new("Jita", System(1))],
        system_ids: vec![1],
        hostile_count: Some(0),
        is_clear: true,
        ..IntelReport::default()
    };
    let not_found = PilotDirectory::new(HashMap::from([("x".to_owned(), PilotLookupOutcome::NotFound)]));
    assert_eq!(resolve(&clear, &not_found).hostile_count, Some(0));
}
