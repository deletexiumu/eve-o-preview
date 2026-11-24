// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名缓存：存取、两种期限、查到变没查到、存盘与恢复、两个容量、清空。

use std::collections::HashMap;

use super::outcomes;
use crate::intel::pilots::cache::{
    MATCHED_CAPACITY, MATCHED_TTL, PilotNameCache, UNMATCHED_CAPACITY, UNMATCHED_TTL,
};
use crate::intel::pilots::{PilotLookupOutcome, PilotNameCacheEntry};

/// 查到的结果的简写。
fn matched(id: i64, name: &str) -> PilotLookupOutcome {
    PilotLookupOutcome::matched(id, name)
}

/// 一条缓存文件里的条目。
fn entry(key: &str, id: i64, name: &str, time: f64) -> PilotNameCacheEntry {
    PilotNameCacheEntry {
        key: key.into(),
        character_id: id,
        name: name.into(),
        time,
    }
}

/// 存入与读出；键按比较键，所以大小写与空白不同的写法查到同一项。
#[test]
fn store_and_read() {
    let mut cache = PilotNameCache::new(&[], 0.0);
    assert!(cache.needs_lookup("Kael Doran", 0.0));
    cache.store(
        &outcomes(&[
            ("kael doran", matched(7, "Kael Doran")),
            ("mira", PilotLookupOutcome::NotFound),
            ("veldspar", PilotLookupOutcome::Ambiguous),
        ]),
        100.0,
    );
    assert!(!cache.needs_lookup("KAEL  DORAN", 100.0));
    let directory = cache.directory();
    assert_eq!(directory.outcome("Kael Doran"), Some(&matched(7, "Kael Doran")));
    assert_eq!(directory.outcome("Mira"), Some(&PilotLookupOutcome::NotFound));
    assert_eq!(
        directory.outcome("Veldspar"),
        Some(&PilotLookupOutcome::Ambiguous)
    );
    // 只有查到的才计数、才需要存盘。
    assert_eq!(cache.matched_count(), 1);
    assert!(cache.is_dirty());
}

/// 查到的 30 天、其余 6 小时；过期后 needs_lookup 为真，而 directory 里仍有（显示不倒退）。
#[test]
fn expiry() {
    let mut cache = PilotNameCache::new(&[], 0.0);
    cache.store(
        &outcomes(&[
            ("kael doran", matched(7, "Kael Doran")),
            ("mira", PilotLookupOutcome::NotFound),
        ]),
        0.0,
    );
    assert!(!cache.needs_lookup("Mira", UNMATCHED_TTL - 1.0));
    assert!(cache.needs_lookup("Mira", UNMATCHED_TTL));
    assert_eq!(
        cache.directory().outcome("Mira"),
        Some(&PilotLookupOutcome::NotFound)
    );
    assert!(!cache.needs_lookup("Kael Doran", MATCHED_TTL - 1.0));
    assert!(cache.needs_lookup("Kael Doran", MATCHED_TTL));
    assert!(cache.directory().outcome("Kael Doran").is_some());
}

/// 后来查不到的角色从查到的表里移出，并要重写缓存文件。
#[test]
fn matched_replaced_by_not_found() {
    let mut cache = PilotNameCache::new(&[], 0.0);
    cache.store(&outcomes(&[("kael doran", matched(7, "Kael Doran"))]), 0.0);
    // 先存一次盘，确认后面的 is_dirty 来自移出。
    cache.snapshot(0.0);
    cache.store(&outcomes(&[("kael doran", PilotLookupOutcome::NotFound)]), 10.0);
    assert_eq!(cache.matched_count(), 0);
    assert!(cache.is_dirty());
    assert_eq!(
        cache.directory().outcome("Kael Doran"),
        Some(&PilotLookupOutcome::NotFound)
    );
}

/// snapshot 只含没过期的查到的结果，并清掉 is_dirty；从条目恢复时丢掉过期的，键再算一次比较键。
#[test]
fn snapshot_and_restore() {
    let mut cache = PilotNameCache::new(&[], 0.0);
    cache.store(
        &outcomes(&[
            ("kael doran", matched(7, "Kael Doran")),
            ("mira", PilotLookupOutcome::NotFound),
        ]),
        0.0,
    );
    cache.store(&outcomes(&[("tarn vex", matched(8, "Tarn Vex"))]), 1_000.0);
    // 30 天又 10 秒之后：时刻 0 的两条已过期，时刻 1000 的 Tarn Vex 还在期限内。
    let now = MATCHED_TTL + 10.0;
    assert_eq!(cache.snapshot(now), [entry("tarn vex", 8, "Tarn Vex", 1_000.0)]);
    assert!(!cache.is_dirty());
    // 恢复：键写成大小写混合的「Tarn Vex」也能查到（旧文件或手工改过的文件）。
    let saved = [
        entry("kael doran", 7, "Kael Doran", 0.0),
        entry("Tarn Vex", 8, "Tarn Vex", 1_000.0),
    ];
    let restored = PilotNameCache::new(&saved, now);
    assert_eq!(restored.matched_count(), 1);
    assert_eq!(
        restored.directory().outcome("tarn vex"),
        Some(&matched(8, "Tarn Vex"))
    );
    // 刚从文件读出来的内容不需要再写回去。
    assert!(!restored.is_dirty());
}

/// 两个容量：超过时丢最早查到的，新存的留下。
#[test]
fn capacities() {
    let mut cache = PilotNameCache::new(&[], 0.0);
    let many: HashMap<String, PilotLookupOutcome> = (0..MATCHED_CAPACITY)
        .map(|i| (format!("m{i}"), matched(i as i64, &format!("M{i}"))))
        .collect();
    cache.store(&many, 1.0);
    // 再存一条：表满了，丢掉时刻最早的一条（时刻相同时按键排序，丢 m0）。
    cache.store(&outcomes(&[("newest", matched(1, "Newest"))]), 2.0);
    assert_eq!(cache.matched_count(), MATCHED_CAPACITY);
    assert!(cache.directory().outcome("newest").is_some());

    let other: HashMap<String, PilotLookupOutcome> = (0..UNMATCHED_CAPACITY)
        .map(|i| (format!("u{i}"), PilotLookupOutcome::NotFound))
        .collect();
    cache.store(&other, 3.0);
    // 没查到的表另有容量，满了同样丢最早的，不影响查到的表。
    cache.store(&outcomes(&[("latest", PilotLookupOutcome::NotFound)]), 4.0);
    let remaining = (0..UNMATCHED_CAPACITY)
        .filter(|i| cache.directory().outcome(&format!("u{i}")).is_some())
        .count();
    assert_eq!(remaining, UNMATCHED_CAPACITY - 1);
    assert_eq!(
        cache.directory().outcome("latest"),
        Some(&PilotLookupOutcome::NotFound)
    );
}

/// remove_all 清空全部，之后存盘写出空文件。
#[test]
fn remove_all() {
    let mut cache = PilotNameCache::new(&[entry("kael doran", 7, "Kael Doran", 0.0)], 0.0);
    cache.remove_all();
    assert_eq!(cache.matched_count(), 0);
    assert!(cache.directory().is_empty());
    assert!(cache.is_dirty());
    assert!(cache.snapshot(0.0).is_empty());
}
