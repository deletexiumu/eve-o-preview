// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的判断与分批规则：already_in 对各目标语言的正例与反例（含中日混排、没有字母的消息）；skip_reason 的
// 4 种原因与 None；cache_key 对空白、`*`、换行的处理；next_batch 的条数、字数上限、相同原文只取一条、
// 第一条超长时仍被取出；result_phase；render_terms 只换写法不同的术语。

use super::{item, item_with, term};
use crate::chat_log::ChatLine;
use crate::intel::{IntelReport, IntelSegment, IntelSegmentKind, IntelShipMention};
use crate::model::AppLanguage;
use crate::static_data::matcher::{IntelWord, TermKind};
use crate::support::StringEnum;
use crate::translation::rules::{
    already_in, cache_key, next_batch, render_terms, result_phase, sent_length, sent_text, skip_reason,
};
use crate::translation::{Phase, SkipReason, TranslatedText};

/// 中文：汉字过半为真；含假名的是日文；英文为假。
#[test]
fn already_in_chinese() {
    assert!(already_in("吉他有红名在门口", AppLanguage::Zh));
    // 夹着一个英文词：汉字仍占字母的一半以上。
    assert!(already_in("吉他 gate 有红", AppLanguage::Zh));
    // 有假名就是日文，即使汉字不少。
    assert!(!already_in("ゲートにいる敵", AppLanguage::Zh));
    assert!(!already_in("hostile on gate", AppLanguage::Zh));
}

/// 日文要有假名且假名加汉字过半；韩文与俄文按各自文字的占比。
#[test]
fn already_in_japanese_korean_russian() {
    assert!(already_in("ゲートに敵がいる", AppLanguage::Ja));
    // 只有汉字没有假名：按中文看，日文目标仍要翻译。
    assert!(!already_in("门口有敌人", AppLanguage::Ja));
    assert!(!already_in("enemy at gate です", AppLanguage::Ja));
    assert!(already_in("게이트에 적이 있다", AppLanguage::Ko));
    assert!(!already_in("enemy at gate", AppLanguage::Ko));
    assert!(already_in("враг на гейте", AppLanguage::Ru));
    // 西里尔字母不到一半。
    assert!(!already_in("enemy на gate now", AppLanguage::Ru));
}

/// 拉丁字母的 4 种语言总是交给模型；没有字母的消息对任何目标都为真。
#[test]
fn already_in_latin_and_no_letters() {
    // 拉丁字母的几种语言之间分不清，交给模型判断，模型给的原文语言再决定是否显示。
    for target in [AppLanguage::En, AppLanguage::Fr, AppLanguage::De, AppLanguage::Es] {
        assert!(!already_in("hostile on gate", target));
        assert!(!already_in("门口有敌人", target));
    }
    // 数字、表情与符号没有字母：不用翻译。
    for &target in AppLanguage::ALL {
        assert!(already_in("7 123 :) ++ 18", target));
        assert!(already_in("", target));
    }
}

/// 建一行消息；system 为真时说话人是 EVE 系统。
fn line(text: &str, system: bool) -> ChatLine {
    ChatLine {
        time: 0.0,
        speaker: if system { "EVE System" } else { "Vex Oran" }.to_owned(),
        text: text.to_owned(),
        is_system: system,
    }
}

/// 4 种原因与 None。
#[test]
fn skip_reasons() {
    // 普通聊天：分段只有一段 Plain，不是情报。
    let plain = IntelReport::plain("x");
    let zh = AppLanguage::Zh;
    assert_eq!(
        skip_reason(&line("hello", true), &plain, zh),
        Some(SkipReason::SystemSpeaker)
    );
    assert_eq!(
        skip_reason(&line("   ", false), &plain, zh),
        Some(SkipReason::Empty)
    );
    assert_eq!(
        skip_reason(&line("门口有人", false), &plain, zh),
        Some(SkipReason::SameLanguage)
    );
    let hello = IntelReport::plain("hello there");
    // 英文聊天、目标中文：要交给模型。
    assert_eq!(skip_reason(&line("hello there", false), &hello, zh), None);

    // 只有星系、舰船与数量：剩下的文字为空，是 TermsOnly。
    let intel = IntelReport {
        segments: vec![
            IntelSegment::new("Jita", IntelSegmentKind::System(30_000_142)),
            IntelSegment::new(" ", IntelSegmentKind::Plain),
            IntelSegment::new("Sabre", IntelSegmentKind::Ship(22_456)),
            IntelSegment::new(" ", IntelSegmentKind::Plain),
            IntelSegment::new("2", IntelSegmentKind::Count(2)),
        ],
        system_ids: vec![30_000_142],
        ships: vec![IntelShipMention {
            kind: TermKind::Ship(22_456),
            count: 2,
        }],
        ..IntelReport::default()
    };
    assert_eq!(
        skip_reason(&line("Jita Sabre 2", false), &intel, zh),
        Some(SkipReason::TermsOnly)
    );

    // 情报样的消息里还有一句英文：交给模型。
    let mixed = IntelReport {
        segments: vec![
            IntelSegment::new("Jita", IntelSegmentKind::System(30_000_142)),
            IntelSegment::new(" camp on the gate", IntelSegmentKind::Plain),
        ],
        system_ids: vec![30_000_142],
        ..IntelReport::default()
    };
    assert_eq!(
        skip_reason(&line("Jita camp on the gate", false), &mixed, zh),
        None
    );
}

/// 连续空白并成一个，去掉首尾空白与名称后面的 `*`，保留换行，去掉空行。
#[test]
fn cache_key_normalizes() {
    assert_eq!(cache_key("  Jita*   Sabre  x2 "), "Jita Sabre x2");
    // 词中间的 `*` 保留，只去掉词尾的翻译标记。
    assert_eq!(cache_key("a*b c*"), "a*b c");
    assert_eq!(cache_key("a**"), "a*");
    assert_eq!(cache_key("line one\n\n  line\ttwo  \n"), "line one\nline two");
    // Windows 的 CRLF 与 LF 得到同一个键，缓存可以命中。
    assert_eq!(cache_key("first\r\nsecond"), "first\nsecond");
    assert_eq!(cache_key("  \n "), "");
}

/// 一批至多 20 条；max_messages 夹到 1～20。
#[test]
fn next_batch_count_limit() {
    // 30 条互不相同的短消息：只受条数上限限制。
    let items: Vec<_> = (1..=30).map(|n| item(n, &format!("message {n}"))).collect();
    assert_eq!(next_batch(&items, 20).len(), 20);
    assert_eq!(next_batch(&items, 5).len(), 5);
    // 上限给 0 也至少取一条，队列不会卡住。
    assert_eq!(next_batch(&items, 0).len(), 1);
    assert_eq!(next_batch(&items, 99).len(), 20);
}

/// 一批合计至多 6,000 个字符（每条按截断到 500 个字符计）；超过时停在前一条。
#[test]
fn next_batch_character_limit() {
    // 498 个 a 加两位数编号，每条正好 500 个字符。
    let long = "a".repeat(498);
    let items: Vec<_> = (10..=24).map(|n| item(n, &format!("{long}{n}"))).collect();
    // 每条 500 个字符，12 条正好 6,000。
    assert_eq!(next_batch(&items, 20).len(), 12);
    // 3,001 个字符的消息只发前 500 个，按 500 计。
    let huge: Vec<_> = (1..=3)
        .map(|n| item(n, &format!("{}{n}", "b".repeat(3_000))))
        .collect();
    // 超长的消息按 500 计，3 条共 1,500，都能取。
    assert_eq!(next_batch(&huge, 20).len(), 3);
}

/// 缓存键相同的只取第一条；不是 Pending 的不取；第一条超长时仍被取出。
#[test]
fn next_batch_deduplicates_and_takes_first() {
    let done = Phase::Done {
        text: "x".to_owned(),
        source_language: None,
    };
    let items = vec![
        item(1, "hello  there"),
        item(2, "hello there*"),
        item(3, "other"),
        item_with(4, "done one", done),
    ];
    // 2 与 1 的缓存键相同（空白与词尾 `*` 不计），4 已翻译，都不取。
    let ids: Vec<u64> = next_batch(&items, 20).iter().map(|i| i.id).collect();
    assert_eq!(ids, vec![1, 3]);
    let long = vec![item(1, &"z".repeat(9_000))];
    assert_eq!(next_batch(&long, 20).len(), 1);
    assert_eq!(sent_length(&long[0].message.text), 500);
    assert!(next_batch(&[], 20).is_empty());
}

/// 「字符」按字素簇计：带组合记号的字母与表情各算一个，截断不会切开它们。
#[test]
fn sent_text_counts_graphemes() {
    // é 用组合记号写成两个码位，👍🏽 是表情加肤色修饰；各算一个字符。
    let text = format!("{}é👍🏽tail", "x".repeat(498));
    assert_eq!(sent_length(&text), 500);
    assert_eq!(sent_text(&text), format!("{}é👍🏽", "x".repeat(498)));
    assert_eq!(sent_text("short"), "short");
}

/// 原样抄回（按缓存键比较）是 SameLanguage；拉丁字母的目标语言看模型给的原文语言；其余是 Done。
#[test]
fn result_phases() {
    let same = Phase::Skipped(SkipReason::SameLanguage, None);
    let translated = |text: &str, lang: Option<&str>| TranslatedText {
        text: text.to_owned(),
        source_language: lang.map(str::to_owned),
    };
    // 模型只改了空白和 `*`：仍算原样抄回。
    let echoed = translated("  gate camp  in Jita*", None);
    assert_eq!(result_phase(&echoed, "gate camp in Jita", AppLanguage::Zh), same);
    let real = translated("吉他有人蹲门", Some("en"));
    assert_eq!(
        result_phase(&real, "gate camp in Jita", AppLanguage::Zh),
        Phase::Done {
            text: "吉他有人蹲门".to_owned(),
            source_language: Some("en".to_owned())
        }
    );
    // 目标英文、原文也是英文（带地区）：模型只是改写了，不当译文显示。
    let rewritten = translated("Gate camp in Jita.", Some("en-US"));
    assert_eq!(
        result_phase(&rewritten, "gate camp in jita", AppLanguage::En),
        same
    );
    // 目标德文、原文英文：是真正的译文。
    let german = translated("Torcamp in Jita", Some("en"));
    assert!(matches!(
        result_phase(&german, "gate camp in Jita", AppLanguage::De),
        Phase::Done { .. }
    ));
    // 非拉丁的目标语言不看 lang。
    let chinese = translated("吉他蹲门", Some("zh"));
    assert!(matches!(
        result_phase(&chinese, "吉他门口蹲", AppLanguage::Zh),
        Phase::Done { .. }
    ));
}

/// 只换写法不同的术语；`*` 随替换去掉；写法相同（不区分大小写）的不动。
#[test]
fn render_terms_replaces_only_different_spellings() {
    let text = "Jita* sabre x2 HED-GP";
    let matches = [
        term("Jita*", text, TermKind::System(1), "Jita", &[("zh", "吉他")]),
        term("sabre", text, TermKind::Ship(2), "Sabre", &[("zh", "剑齿虎级")]),
        term("HED-GP", text, TermKind::System(3), "HED-GP", &[]),
    ];
    assert_eq!(
        render_terms(text, &matches, AppLanguage::Zh),
        "吉他 剑齿虎级 x2 HED-GP"
    );
    // 目标是英文：Jita 与 sabre 只差 `*` 或大小写，原样不动。
    // HED-GP 没有译名，任何语言下都不变。
    assert_eq!(render_terms(text, &matches, AppLanguage::En), text);
}

/// 情报用语只在有目标语言的译名时才换；重叠的匹配忽略；越界的匹配忽略。
#[test]
fn render_terms_intel_words_and_overlaps() {
    let text = "Naga clr";
    let clear = TermKind::IntelWord(IntelWord::Clear);
    // clr 没有英文以外的译名：英文目标下不换成 clear。
    let clr = term("clr", text, clear, "clear", &[]);
    assert_eq!(render_terms(text, &[clr], AppLanguage::En), "Naga clr");
    let localized = term("clr", text, clear, "clear", &[("zh", "安全")]);
    assert_eq!(
        render_terms(text, std::slice::from_ref(&localized), AppLanguage::Zh),
        "Naga 安全"
    );
    // 越界的范围（来自别的文字）忽略，不会切坏字符串。
    let mut stray = localized;
    stray.range = 6..40;
    assert_eq!(render_terms(text, &[stray], AppLanguage::Zh), text);

    // 同一起点的长短两处匹配：长的优先，短的因重叠被忽略。
    let overlap = "Naga Navy Issue";
    let full = term(
        overlap,
        overlap,
        TermKind::Ship(1),
        overlap,
        &[("zh", "娜迦级海军型")],
    );
    let short = term("Naga", overlap, TermKind::Ship(2), "Naga", &[("zh", "娜迦级")]);
    assert_eq!(
        render_terms(overlap, &[short, full], AppLanguage::Zh),
        "娜迦级海军型"
    );
    assert_eq!(AppLanguage::Zh.raw(), "zh");
}
