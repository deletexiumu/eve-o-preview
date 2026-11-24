// SPDX-License-Identifier: GPL-3.0-or-later
//
// 术语匹配：星系、星域、舰船、分组与情报用语，多个词、`*`、复数回退、单个词的两条限制、中文边界、优先顺序。
// 星图数据用夹具，名称与 ID 取自 SDE；聊天文字是编的。

use super::*;
use crate::model::AppLanguage;
use crate::static_data::lexicon::{CASE_SENSITIVE_SHIP_NAMES, COMMON_WORD_LOCALIZED_NAMES, SHIP_ALIASES};
use crate::static_data::matcher::IntelWord::{Clear, NoVisual};
use crate::static_data::matcher::TermKind::{self, IntelWord, Region, Ship, ShipGroup, System};
use crate::static_data::matcher::TermMatcher;
use crate::static_data::{NamedRecord, ShipName, SolarSystem};

/// 匹配到的原文与种类。
fn found(matcher: &TermMatcher, text: &str) -> Vec<(String, TermKind)> {
    matcher
        .matches(text)
        .into_iter()
        .map(|m| (text[m.range].to_owned(), m.kind))
        .collect()
}

/// 只看种类。
fn kinds(matcher: &TermMatcher, text: &str) -> Vec<TermKind> {
    matcher.matches(text).into_iter().map(|m| m.kind).collect()
}

/// 带一个中文译名的星系。
fn system_zh(id: i64, name: &str, zh: &str) -> SolarSystem {
    let mut system = SolarSystem::new(id, name);
    system.localized.insert("zh".into(), zh.into());
    system
}

/// 英文与中文的星系、舰船、舰船分组、星域。
#[test]
fn basic_terms() {
    let data = data();
    let k = |text: &str| kinds(&data.matcher, text);
    assert_eq!(k("Jita"), [System(JITA)]);
    assert_eq!(k("吉他"), [System(JITA)]);
    assert_eq!(k("Rifter"), [Ship(RIFTER)]);
    assert_eq!(k("裂谷级"), [Ship(RIFTER)]);
    // 分组名同样认得，种类是 ShipGroup。
    assert_eq!(k("Interceptor"), [ShipGroup(INTERCEPTOR_GROUP)]);
    assert_eq!(k("截击舰"), [ShipGroup(INTERCEPTOR_GROUP)]);
    assert_eq!(k("伏尔戈"), [Region(THE_FORGE)]);
    // 两个词的星域名按词键匹配。
    assert_eq!(k("The Forge"), [Region(THE_FORGE)]);
}

/// 多个词的名称与最长匹配；名称后的 `*` 并入范围。
#[test]
fn multi_word_and_stars() {
    let data = data();
    assert_eq!(
        found(&data.matcher, "New Caldari* Vexor Navy Issue"),
        [
            ("New Caldari*".to_owned(), System(NEW_CALDARI)),
            ("Vexor Navy Issue".to_owned(), Ship(VEXOR_NAVY_ISSUE)),
        ]
    );
    // 名称后的多个 `*` 都并入范围。
    assert_eq!(found(&data.matcher, "娜迦级海军型**")[0].0, "娜迦级海军型**");
    assert_eq!(kinds(&data.matcher, "娜迦级海军型"), [Ship(NAGA_NAVY_ISSUE)]);
    // `wh` 只有 2 个字符，不算术语；带连字符的星系名是一个词。
    assert_eq!(found(&data.matcher, "T5ZI-S* wh")[0].0, "T5ZI-S*");
    assert_eq!(found(&data.matcher, "T5ZI-S* wh").len(), 1);
}

/// 范围是原文的字节下标：大小写与原文一致，切出来的文字就是原文。
#[test]
fn ranges_point_into_original() {
    let data = data();
    let text = "  hek* and JITA";
    let matches = data.matcher.matches(text);
    let slices: Vec<&str> = matches.iter().map(|m| &text[m.range.clone()]).collect();
    assert_eq!(slices, ["hek*", "JITA"]);
    assert_eq!(matches[1].name_in(AppLanguage::Zh), "吉他");
    assert_eq!(matches[1].english, "Jita");
    // 多字节文字前后的下标也对。
    let text = "吉他 Hek";
    let slices: Vec<String> = found(&data.matcher, text).into_iter().map(|f| f.0).collect();
    assert_eq!(slices, ["吉他", "Hek"]);
}

/// 复数回退：去掉 s 或 es 后再查。
#[test]
fn plural_fallback() {
    let data = data();
    assert_eq!(kinds(&data.matcher, "2 crows"), [Ship(CROW)]);
    assert_eq!(kinds(&data.matcher, "Machariels"), [Ship(MACHARIEL)]);
    // 去掉 es 后命中分组名 Logistics。
    assert_eq!(kinds(&data.matcher, "Logisticses"), [ShipGroup(LOGISTICS_GROUP)]);
}

/// 虚词、2 个字符的词、纯数字不匹配；3 个字母的名称只在首字母大写或带 `*` 时匹配。
#[test]
fn single_word_rules() {
    let data = data();
    let k = |text: &str| kinds(&data.matcher, text);
    // Hek 只有 3 个字母：小写时可能是普通词，不认。
    assert!(k("hek").is_empty());
    assert_eq!(k("Hek"), [System(HEK)]);
    assert_eq!(k("HEK"), [System(HEK)]);
    assert_eq!(k("hek*"), [System(HEK)]);
    // 虚词、纯数字、2 个字符的词都不算。
    assert!(k("to be or not 42 ab").is_empty());
}

/// 第 4 条单独核对：名字恰好是虚词、2 个字符或纯数字的星系，首字母大写也不匹配；多个词时不受限。
#[test]
fn rule_four_with_matching_names() {
    let systems = [
        SolarSystem::new(1, "Not"),
        SolarSystem::new(2, "Ab"),
        SolarSystem::new(3, "42"),
        SolarSystem::new(4, "Not Ab"),
    ];
    let matcher = TermMatcher::new(&systems, &[], &[]);
    // 名字恰好是虚词：单独出现时首字母大写也不认，两个词连在一起时认。
    assert!(matcher.matches("Not").is_empty());
    assert!(matcher.matches("AB*").is_empty());
    assert!(matcher.matches("42").is_empty());
    assert_eq!(kinds(&matcher, "Not Ab"), [System(4)]);
}

/// 中文情报用语看边界：后面紧跟汉字、前面 2 个字符里有否定字都不算；「非常」不算否定。
#[test]
fn chinese_clear_words_need_boundary() {
    let data = data();
    let k = |text: &str| kinds(&data.matcher, text);
    for text in [
        "无人机",
        "不安全",
        "没无人",
        "安全等级",
        "不太安全",
        "没有安全",
        "不 安全",
    ] {
        assert!(k(text).is_empty(), "{text}");
    }
    // 「非常」是「很」，不是否定。
    assert_eq!(k("非常安全"), [IntelWord(Clear)]);
    assert_eq!(k("安全"), [IntelWord(Clear)]);
    // 星系名带 `*`、空格后是「无人」：两处都认。
    assert_eq!(k("吉他* 无人"), [System(JITA), IntelWord(Clear)]);
}

/// 日常中文词的译名：后面紧跟 `*`，或前后都不紧挨汉字时才算；音译名照常不看边界。
#[test]
fn common_word_localized_names() {
    let systems = [
        system_zh(1, "Exit", "出口"),
        system_zh(2, "Jita", "吉他"),
        system_zh(3, "Central Point", "中心点"),
        system_zh(4, "Perimeter", "皮尔米特"),
    ];
    let regions = [NamedRecord {
        i: 10,
        n: "Cache".into(),
        l: Some([("zh".to_owned(), "地窖".to_owned())].into()),
    }];
    let matcher = TermMatcher::new(&systems, &regions, &[]);
    let k = |text: &str| kinds(&matcher, text);
    assert_eq!(k("出口"), [System(1)]);
    assert_eq!(k("出口*"), [System(1)]);
    assert_eq!(k("Jita 出口 gate"), [System(2), System(1)]);
    // 「出口」前后紧挨汉字：是普通词，不是星系 Exit。
    assert!(k("门口出口处").is_empty());
    assert!(k("出口有泡泡").is_empty());
    // 带 `*` 时紧挨汉字也认；不带时只认吉他。
    assert_eq!(k("吉他出口*"), [System(2), System(1)]);
    assert_eq!(k("吉他出口"), [System(2)]);
    assert_eq!(k("地窖 3"), [Region(10)]);
    assert!(k("酒地窖里").is_empty());
    assert_eq!(k("中心点"), [System(3)]);
    assert!(k("地图中心点附近").is_empty());
    // 音译名不在表里：紧挨汉字也认。
    assert_eq!(k("门口皮尔米特有人"), [System(4)]);
    assert_eq!(k("吉他皮尔米特"), [System(2), System(4)]);
    assert!(COMMON_WORD_LOCALIZED_NAMES.contains(&"出口"));
    assert!(!COMMON_WORD_LOCALIZED_NAMES.contains(&"皮尔米特"));
}

/// 夹具里的皮尔米特（Perimeter 在 AMBIGUOUS_SHORT_NAMES 里）不带 `*`、紧挨汉字也认得出。
#[test]
fn transliterated_ambiguous_name_matches_freely() {
    let data = data();
    assert_eq!(
        kinds(&data.matcher, "从吉他跳到皮尔米特了"),
        [System(JITA), System(PERIMETER)]
    );
}

/// 舰船与舰船分组小写也算；CASE_SENSITIVE_SHIP_NAMES 与 AMBIGUOUS_SHORT_NAMES 里的键仍要大写或 `*`，
/// 复数回退得到的键也按这条判断。
#[test]
fn lowercase_ship_names() {
    let ships: Vec<ShipName> = ["Moa", "Nyx", "Sin", "Imp", "Ark", "Curse", "Hel"]
        .iter()
        .enumerate()
        .map(|(i, name)| ShipName::new(i as i64 + 1, Some(25), name))
        .collect();
    let matcher = TermMatcher::new(&[SolarSystem::new(9, "Hek")], &[], &ships);
    let k = |text: &str| kinds(&matcher, text);
    assert_eq!(k("moa"), [Ship(1)]);
    // 舰船名小写、复数都认。
    assert_eq!(k("2 moas"), [Ship(1)]);
    assert_eq!(k("nyx"), [Ship(2)]);
    assert!(k("sin").is_empty());
    // 复数回退命中 sin：仍要大写或带 `*`。
    assert!(k("sins").is_empty());
    assert_eq!(k("Sin"), [Ship(3)]);
    assert!(k("imp ark").is_empty());
    // 大写的 Imp 与带 `*` 的 Ark 都认。
    assert_eq!(k("Imp Ark*"), [Ship(4), Ship(5)]);
    assert!(k("curse").is_empty());
    assert!(k("hel").is_empty());
    assert_eq!(k("Curse"), [Ship(6)]);
    // 星系仍受第 5 条限制。
    assert!(k("hek").is_empty());
    assert_eq!(k("Hel"), [Ship(7)]);
    assert_eq!(CASE_SENSITIVE_SHIP_NAMES, ["sin", "imp", "ark", "hel"]);
}

/// AMBIGUOUS_SHORT_NAMES 里的名称：小写不算，首字母大写算。
#[test]
fn ambiguous_names() {
    let data = data();
    // perimeter 也是普通词：小写不认，首字母大写认。
    assert!(kinds(&data.matcher, "inside the perimeter").is_empty());
    assert_eq!(kinds(&data.matcher, "Perimeter gate"), [System(PERIMETER)]);
}

/// 与舰船同名的星系认作舰船；日文名相同的两个星系取 ID 小的。
#[test]
fn priorities() {
    let data = data();
    // 舰船优先于星系；中文名不同，「纳伽」只能是星系。
    assert_eq!(kinds(&data.matcher, "Naga"), [Ship(NAGA_SHIP)]);
    assert_eq!(kinds(&data.matcher, "纳伽"), [System(NAGA_SYSTEM)]);
    assert_eq!(kinds(&data.matcher, "オンスー"), [System(ONSOOH)]);
}

/// 缩写表的词：小写也算，找到对应的舰船或分组；夹具里没有的目标不收。
#[test]
fn aliases() {
    let data = data();
    let k = |text: &str| kinds(&data.matcher, text);
    assert_eq!(k("dic"), [ShipGroup(INTERDICTOR_GROUP)]);
    assert_eq!(k("2 dictors"), [ShipGroup(INTERDICTOR_GROUP)]);
    assert_eq!(k("ceptors"), [ShipGroup(INTERCEPTOR_GROUP)]);
    assert_eq!(k("logi"), [ShipGroup(LOGISTICS_GROUP)]);
    assert_eq!(k("mach"), [Ship(MACHARIEL)]);
    assert_eq!(k("vni"), [Ship(VEXOR_NAVY_ISSUE)]);
    // 夹具里没有 Stealth Bomber：这条缩写不收。
    assert!(k("bomber").is_empty());
    assert!(SHIP_ALIASES.iter().all(|(alias, _)| *alias != "bs"));
}

/// 情报用语：clr 与 nv 不受长度与大小写的限制；no visual 是两个词。
#[test]
fn intel_words() {
    let data = data();
    let k = |text: &str| kinds(&data.matcher, text);
    assert_eq!(k("clr"), [IntelWord(Clear)]);
    assert_eq!(k("nv"), [IntelWord(NoVisual)]);
    assert_eq!(k("no visual"), [IntelWord(NoVisual)]);
    assert_eq!(k("安全"), [IntelWord(Clear)]);
    // 情报用语不受大小写限制。
    assert_eq!(k("CLEAR").first(), Some(&IntelWord(Clear)));
}

/// 连在一起、没有空格的中文名称；匹配互不重叠且按位置排序。两个词之间隔两个空格时不算连续。
#[test]
fn adjacency_and_spacing() {
    let data = data();
    assert_eq!(
        kinds(&data.matcher, "吉他剑齿虎级黑鸦级"),
        [System(JITA), Ship(SABRE), Ship(CROW)]
    );
    let matches = data.matcher.matches("Jita 吉他 Hek");
    assert!(matches.windows(2).all(|w| w[0].range.end <= w[1].range.start));
    // 两个空格隔开的词不连续：New 与 Caldari 单独都不是术语。
    assert!(kinds(&data.matcher, "New  Caldari").is_empty());
    assert!(kinds(&data.matcher, "Vexor Navy  Issue").is_empty());
}

/// 没有任何名称时只认情报用语；空文字返回空数组。
#[test]
fn empty_input() {
    let data = data();
    assert!(data.matcher.matches("").is_empty());
    // 没有星图数据时仍认情报用语。
    let empty = TermMatcher::new(&[], &[], &[]);
    assert_eq!(kinds(&empty, "clr"), [IntelWord(Clear)]);
}
