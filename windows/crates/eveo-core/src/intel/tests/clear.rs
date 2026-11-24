// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「安全」用语：否定、疑问、「无人机」「安全等级」这类词里的字不算「安全」，写了人数时敌对数量不是 0；
// 对照组是真正报「安全」的写法。消息是编的。

use super::parse;
use crate::intel::IntelSegmentKind::Word;
use crate::static_data::matcher::IntelWord::Clear;
use crate::static_data::matcher::TermKind;
use crate::static_data::tests::{JITA, data};

// MARK: 审查复现的误判

/// 「无人机」里的「无人」不是用语；3 是独立人数。
#[test]
fn drone_is_not_clear() {
    let data = data();
    let report = parse(&data, "Jita 3 无人机");
    assert!(!report.is_clear);
    assert_eq!(report.hostile_count, Some(3));
    assert!(report.count_is_explicit);
}

/// 「不安全」被否定；+5 是人数。
#[test]
fn negated_chinese_clear() {
    let data = data();
    let report = parse(&data, "HED-GP 不安全 +5");
    assert!(!report.is_clear);
    assert_eq!(report.hostile_count, Some(5));
}

/// 英文的否定：前面 3 个词里有 not、no、never 或以 n't 结尾的词。
#[test]
fn negated_english_clear() {
    let data = data();
    for text in [
        "Jita not clear",
        "Jita no clr",
        "Jita isn't clear",
        "Jita isn’t clr",
        "Jita NOT, clear",
        "Jita not yet clr",
        "Jita no longer clear",
        "Jita never clr",
        "Jita is not really clear",
        "Jita gate isn't fully clr",
    ] {
        assert!(!parse(&data, text).is_clear, "{text}");
    }
}

/// 往回看的边界：上一句里的否定、用语前面隔着别的段时不算否定；「no reds」里的 no 否定的是敌对。
#[test]
fn look_back_stops_and_no_hostiles() {
    let data = data();
    for text in [
        "no camp anymore. Jita clr",
        "not sure. clr",
        "no Jita clr",
        "Jita nv clr",
        "Jita no reds clr",
        "Jita no hostiles clr",
        "Jita no one, clr",
        "Jita no neuts clear",
    ] {
        assert!(parse(&data, text).is_clear, "{text}");
    }
}

/// 致意与道别（o7、gg、ty）不当人名：`X clr o7` 仍是安全，敌对数量 0。
#[test]
fn sign_offs_keep_clear() {
    let data = data();
    for text in [
        "HED-GP clr o7",
        "Jita clr GG",
        "Jita clr ty",
        "Jita clr o/",
        "Jita clr THX",
    ] {
        let report = parse(&data, text);
        assert!(report.is_clear, "{text}");
        assert!(report.pilots.is_empty(), "{text}");
        assert_eq!(report.hostile_count, Some(0), "{text}");
    }
}

/// 否定后面带人数：不是安全，数量是写明的 10。
#[test]
fn negated_clear_with_count() {
    let data = data();
    let report = parse(&data, "spike +10 not clr");
    assert!(!report.is_clear);
    assert_eq!(report.hostile_count, Some(10));
}

/// 疑问：用语后紧跟问号，或整条消息以问号结尾。
#[test]
fn question_is_not_clear() {
    let data = data();
    for text in [
        "Amarr clear?",
        "Amarr clr ?",
        "Amarr clr？",
        "Amarr clr gate?",
        "吉他 安全？",
    ] {
        assert!(!parse(&data, text).is_clear, "{text}");
    }
}

/// 「安全等级」里的「安全」后面紧跟汉字，不是用语。
#[test]
fn security_status_is_not_clear() {
    let data = data();
    let report = parse(&data, "Jita 安全等级");
    assert!(!report.is_clear);
    assert!(!report.segments.iter().any(|s| s.kind == Word(Clear)));
}

// MARK: 对照

/// 真正的「安全」：英文缩写、中文用语前后是空白、`*` 或行尾时都认得出，敌对数量是 0。
#[test]
fn real_clear() {
    let data = data();
    for text in [
        "HED-GP* clr",
        "吉他 安全",
        "吉他*安全",
        "吉他安全",
        "吉他 无人",
        "Jita clear.",
        "CLEAR Jita",
    ] {
        let report = parse(&data, text);
        assert!(report.is_clear, "{text}");
        assert_eq!(report.hostile_count, Some(0), "{text}");
    }
}

/// 有「安全」又写了人数或舰船：is_clear 仍为真，但敌对数量取写明的数，不强制为 0。
#[test]
fn clear_with_count_keeps_count() {
    let data = data();
    let report = parse(&data, "Jita clr 3");
    assert!(report.is_clear);
    assert_eq!(report.hostile_count, Some(3));
    let with_ship = parse(&data, "Jita clr Rifter");
    assert!(with_ship.is_clear);
    assert_eq!(with_ship.hostile_count, Some(1));
}

/// 字符键层面：否定字与后面的汉字都挡住匹配，前面是普通汉字时不挡。
#[test]
fn character_boundary() {
    let data = data();
    let kinds =
        |text: &str| -> Vec<TermKind> { data.matcher.matches(text).into_iter().map(|m| m.kind).collect() };
    assert!(kinds("非安全").is_empty());
    assert!(kinds("未无人").is_empty());
    assert!(kinds("安全区").is_empty());
    assert_eq!(kinds("很安全"), [TermKind::IntelWord(Clear)]);
    assert_eq!(
        kinds("吉他安全"),
        [TermKind::System(JITA), TermKind::IntelWord(Clear)]
    );
}
