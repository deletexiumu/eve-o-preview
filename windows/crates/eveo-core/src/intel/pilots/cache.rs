// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的缓存，对应 macOS 的 PilotNameCache.swift（设计文档 6.10 节）。键是比较键（pilots::key）。
// - Matched 的结果保留 30 天，存进 pilot-names.json（由 app 层读写文件）。
// - Ambiguous 与 NotFound 保留 6 小时，只留在内存里：这些词多半不是人名，是消息正文的片段，不该落盘。
// - needs_lookup：没有结果或结果已过期时为真。过期的结果在新结果到达之前仍在 directory 里，显示不倒退
//   （否则已经分好的人名会在重新核对的几秒里退回成未核对）。
// - 容量：Matched 至多 5,000 条，其余至多 5,000 条，超过时丢最早查到的。
// - snapshot：要存盘的条目（只有查到的、没过期的），并清掉 is_dirty。
// 时刻都用墙上时钟（1970 年以来的秒数），由调用方传入，测试不依赖真实时间。

//! 人名核对结果的缓存。

use std::collections::HashMap;

use super::segmenter::PilotDirectory;
use super::{PilotLookupOutcome, PilotNameCacheEntry, key};

/// 查到的结果的期限：30 天。
pub const MATCHED_TTL: f64 = 2_592_000.0;
/// 没查到与有歧义的结果的期限：6 小时。
pub const UNMATCHED_TTL: f64 = 21_600.0;
/// 查到的结果至多几条。
pub const MATCHED_CAPACITY: usize = 5_000;
/// 其余结果至多几条。
pub const UNMATCHED_CAPACITY: usize = 5_000;

/// 一条结果与查到它的时刻。
#[derive(Debug, Clone)]
struct Record {
    /// 结果。
    outcome: PilotLookupOutcome,
    /// 查到的时刻。
    time: f64,
}

/// 人名核对的缓存。
#[derive(Debug, Clone, Default)]
pub struct PilotNameCache {
    /// 查到的结果。
    matched: HashMap<String, Record>,
    /// 没查到与有歧义的结果。
    unmatched: HashMap<String, Record>,
    /// 两者合起来的结果表，directory 直接借出它（不在每次刷新时重建）。
    table: PilotDirectory,
    /// 查到的结果有改动、还没存盘。
    is_dirty: bool,
}

impl PilotNameCache {
    /// 用缓存文件里的条目建缓存；过期的与角色 ID 为负的条目丢掉，同一个键留最新的，超过容量时留最新的。
    /// 条目里的键再算一次比较键：文件可能是旧版本或手工改过的。
    pub fn new(entries: &[PilotNameCacheEntry], now: f64) -> Self {
        let mut cache = Self::default();
        for entry in entries {
            if now - entry.time >= MATCHED_TTL || entry.character_id < 0 {
                continue;
            }
            let entry_key = key(&entry.key);
            if entry_key.is_empty()
                || cache
                    .matched
                    .get(&entry_key)
                    .is_some_and(|r| r.time >= entry.time)
            {
                continue;
            }
            let record = Record {
                outcome: PilotLookupOutcome::matched(entry.character_id, &entry.name),
                time: entry.time,
            };
            cache.matched.insert(entry_key, record);
        }
        trim(&mut cache.matched, MATCHED_CAPACITY);
        for (record_key, record) in &cache.matched {
            cache.table.insert(record_key.clone(), record.outcome.clone());
        }
        cache
    }

    /// 存入一批结果。查到的进 matched（从 unmatched 移出）；其余进 unmatched（从 matched 移出）。
    /// 只有 matched 的变化才需要存盘，所以只在那时置 is_dirty。
    pub fn store(&mut self, outcomes: &HashMap<String, PilotLookupOutcome>, now: f64) {
        for (raw_key, outcome) in outcomes {
            let record_key = key(raw_key);
            if record_key.is_empty() {
                continue;
            }
            let record = Record {
                outcome: outcome.clone(),
                time: now,
            };
            if matches!(outcome, PilotLookupOutcome::Matched { .. }) {
                self.matched.insert(record_key.clone(), record);
                self.unmatched.remove(&record_key);
                self.is_dirty = true;
            } else {
                // 以前查到、现在查不到（角色改名或删除）：从存盘的表里移出，文件要重写。
                if self.matched.remove(&record_key).is_some() {
                    self.is_dirty = true;
                }
                self.unmatched.insert(record_key.clone(), record);
            }
            self.table.insert(record_key, outcome.clone());
        }
        let mut dropped = trim(&mut self.matched, MATCHED_CAPACITY);
        dropped.extend(trim(&mut self.unmatched, UNMATCHED_CAPACITY));
        // 被挤掉的键若另一张表里也没有，结果表里也去掉。
        for dropped_key in dropped {
            if !self.matched.contains_key(&dropped_key) && !self.unmatched.contains_key(&dropped_key) {
                self.table.remove(&dropped_key);
            }
        }
    }

    /// 没有结果或结果已过期时为真。
    pub fn needs_lookup(&self, name: &str, now: f64) -> bool {
        let record_key = key(name);
        if let Some(record) = self.matched.get(&record_key) {
            return now - record.time >= MATCHED_TTL;
        }
        if let Some(record) = self.unmatched.get(&record_key) {
            return now - record.time >= UNMATCHED_TTL;
        }
        true
    }

    /// 全部结果（含已过期、还没被新结果替换的），给分人用。
    pub fn directory(&self) -> &PilotDirectory {
        &self.table
    }

    /// 查到的结果的条数（「预警」页显示的「已保存的角色名个数」）。
    pub fn matched_count(&self) -> usize {
        self.matched.len()
    }

    /// 查到的结果有改动、还没存盘。
    pub fn is_dirty(&self) -> bool {
        self.is_dirty
    }

    /// 要存盘的条目（只有查到的、没过期的），按比较键排序，并清掉 is_dirty。排序让文件内容稳定，便于比较。
    pub fn snapshot(&mut self, now: f64) -> Vec<PilotNameCacheEntry> {
        self.is_dirty = false;
        let mut entries: Vec<PilotNameCacheEntry> = self
            .matched
            .iter()
            .filter(|(_, record)| now - record.time < MATCHED_TTL)
            .filter_map(|(record_key, record)| match &record.outcome {
                PilotLookupOutcome::Matched { character_id, name } => Some(PilotNameCacheEntry {
                    key: record_key.clone(),
                    character_id: *character_id,
                    name: name.clone(),
                    time: record.time,
                }),
                _ => None,
            })
            .collect();
        entries.sort_by(|a, b| a.key.cmp(&b.key));
        entries
    }

    /// 清空全部结果。之后存盘会写出空文件（置 is_dirty）。
    pub fn remove_all(&mut self) {
        self.matched.clear();
        self.unmatched.clear();
        self.table = PilotDirectory::default();
        self.is_dirty = true;
    }
}

/// 超过容量时丢最早查到的（时刻相同时按键排序，结果确定），返回丢掉的键。
fn trim(records: &mut HashMap<String, Record>, capacity: usize) -> Vec<String> {
    if records.len() <= capacity {
        return Vec::new();
    }
    let excess = records.len() - capacity;
    let mut order: Vec<(f64, &String)> = records.iter().map(|(k, r)| (r.time, k)).collect();
    order.sort_by(|a, b| a.0.total_cmp(&b.0).then_with(|| a.1.cmp(b.1)));
    let dropped: Vec<String> = order.into_iter().take(excess).map(|(_, k)| k.clone()).collect();
    for dropped_key in &dropped {
        records.remove(dropped_key);
    }
    dropped
}
