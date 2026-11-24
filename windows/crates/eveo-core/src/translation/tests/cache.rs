// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存：命中与未命中；容量满时丢最久没用的；读取会刷新新旧顺序；snapshot 清掉改动标记；从条目恢复；
// 合并旧条目；大量写入；缓存文件的编码与解码。

use crate::model::AppLanguage;
use crate::translation::TranslatedText;
use crate::translation::cache::{CacheEntry, TranslationCache, decode_file, encode_file};

/// 一条译文，原文语言是英文。
fn value(text: &str) -> TranslatedText {
    TranslatedText {
        text: text.to_owned(),
        source_language: Some("en".to_owned()),
    }
}

/// 一条缓存条目，目标语言中文。
fn entry(key: &str, text: &str, source: Option<&str>) -> CacheEntry {
    CacheEntry {
        target: "zh".to_owned(),
        key: key.to_owned(),
        text: text.to_owned(),
        source_language: source.map(str::to_owned),
    }
}

/// 命中按缓存键比对（空白与 `*` 的差别不算新句子）；目标语言不同不命中。
#[test]
fn hit_and_miss() {
    let zh = AppLanguage::Zh;
    let mut cache = TranslationCache::default();
    assert_eq!(cache.value("hello there", zh), None);
    cache.store(&value("你好"), "hello  there*", zh);
    // 首尾空白、连续空白与词尾 `*` 不同的同一句话命中同一条。
    assert_eq!(cache.value(" hello there ", zh), Some(value("你好")));
    // 同一句话的日文译文是另一条。
    assert_eq!(cache.value("hello there", AppLanguage::Ja), None);
    assert_eq!(cache.len(), 1);
    // 空的原文或空的译文不存。
    cache.store(&value("x"), "   ", zh);
    cache.store(&value(""), "y", zh);
    assert_eq!(cache.len(), 1);
}

/// 容量满时丢最久没用的；读取刷新顺序。
#[test]
fn evicts_least_recently_used() {
    let zh = AppLanguage::Zh;
    let mut cache = TranslationCache::new(2, Vec::new());
    cache.store(&value("A"), "a", zh);
    cache.store(&value("B"), "b", zh);
    // a 变成最近用过的，再存 c 时丢 b。
    cache.value("a", zh);
    cache.store(&value("C"), "c", zh);
    assert_eq!(cache.value("b", zh), None);
    assert_eq!(cache.value("a", zh), Some(value("A")));
    assert_eq!(cache.value("c", zh), Some(value("C")));
    assert_eq!(cache.len(), 2);
}

/// snapshot 按「最近用过的在后」给出条目，并清掉改动标记；清空算改动。
#[test]
fn snapshot_clears_dirty() {
    let zh = AppLanguage::Zh;
    let mut cache = TranslationCache::default();
    assert!(!cache.is_dirty());
    cache.store(&value("A"), "a", zh);
    cache.store(&value("B"), "b", zh);
    cache.value("a", zh);
    assert!(cache.is_dirty());
    // 最近读过的 a 排在后面。
    let entries = cache.snapshot();
    let keys: Vec<&str> = entries.iter().map(|e| e.key.as_str()).collect();
    assert_eq!(keys, vec!["b", "a"]);
    assert_eq!(entries[0], entry("b", "B", Some("en")));
    assert!(!cache.is_dirty());
    cache.clear();
    assert!(cache.is_dirty() && cache.is_empty());
}

/// 从条目恢复：不算改动；超过容量时只留最后的；同键后面的为准。
#[test]
fn restores_from_entries() {
    let entries = vec![
        entry("a", "A1", None),
        entry("b", "B", None),
        entry("a", "A2", Some("en")),
        entry("c", "C", None),
    ];
    // 容量 2：只留最后的 a（A2）与 c。
    let mut cache = TranslationCache::new(2, entries);
    assert!(!cache.is_dirty());
    assert_eq!(cache.len(), 2);
    assert_eq!(cache.value("a", AppLanguage::Zh), Some(value("A2")));
    assert_eq!(cache.value("b", AppLanguage::Zh), None);
}

/// 合并文件里的旧条目：现有的同键条目为准，旧条目排在前面，改动标记不变。
#[test]
fn merge_older_entries() {
    let mut cache = TranslationCache::new(3, Vec::new());
    cache.store(&value("NEW"), "a", AppLanguage::Zh);
    // 启动时后台读到的旧文件：a 已在内存里有新译文，以内存为准。
    cache.merge_older(vec![entry("a", "OLD", None), entry("b", "B", None)]);
    assert!(cache.is_dirty());
    let texts: Vec<String> = cache.ordered_entries().into_iter().map(|e| e.text).collect();
    assert_eq!(texts, vec!["B", "NEW"]);
}

/// 大量写入时容量保持不变，最后写入的都在；序号队列的整理不丢有效条目。
#[test]
fn many_writes_stay_within_capacity() {
    let en = AppLanguage::En;
    // 容量 100、写 5,000 条：反复淘汰与整理序号队列。
    let mut cache = TranslationCache::new(100, Vec::new());
    for index in 0..5_000 {
        cache.store(&value(&format!("v{index}")), &format!("k{index}"), en);
        if index % 3 == 0 {
            cache.value(&format!("k{index}"), en);
        }
    }
    assert_eq!(cache.len(), 100);
    assert_eq!(cache.value("k4999", en), Some(value("v4999")));
    assert_eq!(cache.value("k0", en), None);
}

/// 缓存文件：编码后能原样解回；没有原文语言时不写这个键；格式号不对、不是 JSON 时从空开始。
#[test]
fn cache_file_round_trip() {
    let entries = vec![entry("a", "A", None), entry("b", "B", Some("en"))];
    // 键的顺序随结构体字段：format、entries；条目里是 target、key、text、sourceLanguage。
    let bytes = encode_file(entries.clone());
    let text = String::from_utf8(bytes.clone()).unwrap();
    assert!(text.starts_with(r#"{"format":1,"entries":["#));
    assert!(text.contains(r#"{"target":"zh","key":"a","text":"A"}"#));
    assert!(text.contains(r#""sourceLanguage":"en""#));
    assert_eq!(decode_file(&bytes), entries);
    assert!(decode_file(br#"{"format":2,"entries":[]}"#).is_empty());
    assert!(decode_file(b"not json").is_empty());
    // macOS 写的文件（带 sourceLanguage: null 也能读）。
    let mac = br#"{"entries":[{"target":"zh","key":"k","text":"T","sourceLanguage":null}],"format":1}"#;
    assert_eq!(decode_file(mac), vec![entry("k", "T", None)]);
}
