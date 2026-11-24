// SPDX-License-Identifier: GPL-3.0-or-later
//
// 值类型：比较键、缓存条目的 JSON 格式、状态代号与失败原因的比较。

use crate::intel::pilots::{
    PilotLookupAnswer, PilotLookupFailure, PilotLookupOutcome, PilotLookupStatus, PilotNameCacheEntry, key,
};

use super::outcomes;

/// key：去掉首尾空白，连续的空白（含制表符与换行）并成一个空格，转成小写；非 ASCII 字母也转小写。
#[test]
fn comparison_key() {
    let cases = [
        ("Brenn Ostvar", "brenn ostvar"),
        ("  Brenn   Ostvar  ", "brenn ostvar"),
        ("BRENN\tOSTVAR\n", "brenn ostvar"),
        ("Tyra  Kelloway Jr", "tyra kelloway jr"),
        ("Ölrik Ström", "ölrik ström"),
        ("x", "x"),
        ("   ", ""),
        ("", ""),
    ];
    for (name, expected) in cases {
        assert_eq!(key(name), expected, "{name:?}");
    }
}

/// 同一个名字的不同写法得到同一个键；键再算一次不变（缓存从文件恢复时会再算）。
#[test]
fn key_is_stable() {
    let stable = key("Brenn Ostvar");
    assert_eq!(key(" brenn  OSTVAR"), stable);
    assert_eq!(key(&stable), stable);
}

/// 只有结果的答复，错误额度是 None。
#[test]
fn answer_defaults() {
    let matched = PilotLookupOutcome::matched(90_000_001, "Brenn Ostvar");
    let answer = PilotLookupAnswer::new(outcomes(&[("brenn ostvar", matched.clone())]));
    assert_eq!(answer.error_limit_remain, None);
    assert_eq!(answer.error_limit_reset, None);
    assert_eq!(answer.outcomes["brenn ostvar"], matched);
}

/// 缓存条目往返一致，JSON 的键是 key、characterID、name、time（与 macOS 的 pilot-names.json 相同）。
#[test]
fn cache_entry_round_trip() {
    let entry = PilotNameCacheEntry {
        key: "tyra kelloway".into(),
        character_id: 2_100_000_042,
        name: "Tyra Kelloway".into(),
        time: 1_795_000_000.5,
    };
    // 文件里是条目的数组，这里也按数组编码，与真实文件的形状一致。
    let json = serde_json::to_string(std::slice::from_ref(&entry)).unwrap();
    let decoded: Vec<PilotNameCacheEntry> = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded, [entry]);
    // 再按普通 JSON 对象读一次，核对字段名：macOS 写的文件要能被 Windows 读，反之亦然。
    let objects: Vec<serde_json::Map<String, serde_json::Value>> = serde_json::from_str(&json).unwrap();
    let mut keys: Vec<&str> = objects[0].keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["characterID", "key", "name", "time"]);
    assert_eq!(objects[0]["characterID"], 2_100_000_042_i64);
}

/// 状态代号的 4 个值；Waiting 不带时刻，但两个不同时刻的 Waiting 不相等。
#[test]
fn status_codes() {
    assert_eq!(PilotLookupStatus::Off.code(), "off");
    assert_eq!(PilotLookupStatus::Idle.code(), "idle");
    assert_eq!(PilotLookupStatus::Resolving.code(), "resolving");
    assert_eq!(PilotLookupStatus::Waiting(1_795_000_060.0).code(), "waiting");
    assert_ne!(PilotLookupStatus::Waiting(1.0), PilotLookupStatus::Waiting(2.0));
}

/// 失败原因可以比较，关联值不同时不相等。
#[test]
fn failure_equality() {
    use PilotLookupFailure::*;
    assert_eq!(
        RateLimited { retry_after: 60.0 },
        RateLimited { retry_after: 60.0 }
    );
    assert_ne!(Server { status: 503 }, Server { status: 502 });
    assert_ne!(Rejected { status: 400 }, Server { status: 400 });
    assert_ne!(Network("timeout".into()), MalformedAnswer);
}
