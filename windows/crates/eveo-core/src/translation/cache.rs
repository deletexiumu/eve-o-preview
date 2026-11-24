// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存，对应 macOS 的 TranslationCache.swift（设计文档 7.8 节）：键是（目标语言代码，cache_key(原文)），
// 至多 10,000 条，最近用过的留下。存盘由应用安排（有改动时满 30 秒存一次，退出时存一次），文件的读写在应用层；
// 这里另有缓存文件内容的编码与解码（`{"format": 1, "entries": [...]}`，与 macOS 的 translation-cache.json 相同）。
//
// 做法：散列表存条目与「最近使用的序号」，另有一条按使用先后排列的序号队列；淘汰时从队头取，
// 序号已过时（那一条之后又被用过）的跳过。队列过长时整理一次，摊下来每次操作是常数时间。
// 文件里有聊天原文与译文（没有说话人与频道名），只留在本机，不进问题报告。

//! 译文缓存与缓存文件的格式。

use std::collections::{HashMap, VecDeque};

use serde::{Deserialize, Serialize};

use super::TranslatedText;
use super::rules::cache_key;
use crate::model::AppLanguage;
use crate::support::StringEnum;

/// 默认容量。
pub const DEFAULT_CAPACITY: usize = 10_000;
/// 缓存文件格式的版本号。
pub const FILE_FORMAT: i64 = 1;

/// 译文缓存里的一条，存进 translation-cache.json。没有说话人与频道名。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CacheEntry {
    /// 目标语言代码。
    pub target: String,
    /// 原文的缓存键（[`cache_key`]）。
    pub key: String,
    /// 译文。
    pub text: String,
    /// 模型判断的原文语言代码；没有时文件里不写这个键（与 Swift 的 Codable 相同）。
    #[serde(rename = "sourceLanguage", default, skip_serializing_if = "Option::is_none")]
    pub source_language: Option<String>,
}

/// 缓存文件的结构。
#[derive(Serialize, Deserialize)]
struct CacheFile {
    /// 格式的版本号，只认 1。
    format: i64,
    /// 条目，最近用过的在后。
    entries: Vec<CacheEntry>,
}

/// 解出缓存文件里的条目；不是 JSON、结构不对或 format 不是 1 时返回空，从空缓存开始。
pub fn decode_file(bytes: &[u8]) -> Vec<CacheEntry> {
    match serde_json::from_slice::<CacheFile>(bytes) {
        Ok(file) if file.format == FILE_FORMAT => file.entries,
        _ => Vec::new(),
    }
}

/// 把条目编成缓存文件的内容。字段只有字符串，编码不会失败。
pub fn encode_file(entries: Vec<CacheEntry>) -> Vec<u8> {
    let file = CacheFile {
        format: FILE_FORMAT,
        entries,
    };
    serde_json::to_vec(&file).unwrap_or_default()
}

/// 一条缓存与它最近一次使用的序号。
#[derive(Debug, Clone)]
struct Slot {
    /// 条目。
    entry: CacheEntry,
    /// 最近一次使用的序号，越大越新。
    stamp: u64,
}

/// 译文缓存。由翻译总控持有。
#[derive(Debug, Clone)]
pub struct TranslationCache {
    /// 容量，至少 1。
    capacity: usize,
    /// 组合键 → 条目与最近一次使用的序号。
    table: HashMap<String, Slot>,
    /// 按使用先后排列的（组合键，序号）。序号与表里不一致的元素已失效。
    order: VecDeque<(String, u64)>,
    /// 下一个序号。
    next_stamp: u64,
    /// 有没有没存盘的改动。
    dirty: bool,
}

impl Default for TranslationCache {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY, Vec::new())
    }
}

impl TranslationCache {
    /// 建缓存。entries 按「最近用过的在后」的顺序给出；同一个键出现多次时后面的为准；超过容量时只留最后的。
    /// 缓存键或译文为空的条目忽略。新建的缓存没有改动。
    pub fn new(capacity: usize, entries: Vec<CacheEntry>) -> Self {
        let mut cache = Self {
            capacity: capacity.max(1),
            table: HashMap::new(),
            order: VecDeque::new(),
            next_stamp: 0,
            dirty: false,
        };
        for entry in entries {
            if !entry.key.is_empty() && !entry.text.is_empty() {
                cache.put(entry);
            }
        }
        cache
    }

    /// 有没有没存盘的改动。
    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    /// 条目数。
    pub fn len(&self) -> usize {
        self.table.len()
    }

    /// 是否一条也没有。
    pub fn is_empty(&self) -> bool {
        self.table.is_empty()
    }

    /// 取一条译文；命中时刷新它的新旧顺序。
    pub fn value(&mut self, text: &str, target: AppLanguage) -> Option<TranslatedText> {
        let key = composite_key(target.raw(), &cache_key(text));
        if !self.table.contains_key(&key) {
            return None;
        }
        let stamp = self.touch(&key);
        let slot = self.table.get_mut(&key)?;
        slot.stamp = stamp;
        Some(TranslatedText {
            text: slot.entry.text.clone(),
            source_language: slot.entry.source_language.clone(),
        })
    }

    /// 存一条译文；原文的缓存键为空或译文为空时不存。
    pub fn store(&mut self, value: &TranslatedText, text: &str, target: AppLanguage) {
        let key = cache_key(text);
        if key.is_empty() || value.text.is_empty() {
            return;
        }
        self.put(CacheEntry {
            target: target.raw().to_owned(),
            key,
            text: value.text.clone(),
            source_language: value.source_language.clone(),
        });
        self.dirty = true;
    }

    /// 清空全部条目，标记为有改动（存盘后文件也变空）。
    pub fn clear(&mut self) {
        self.table.clear();
        self.order.clear();
        self.dirty = true;
    }

    /// 取出要存盘的条目（最近用过的在后）并清掉改动标记。
    pub fn snapshot(&mut self) -> Vec<CacheEntry> {
        self.dirty = false;
        self.ordered_entries()
    }

    /// 全部条目，最近用过的在后；不改改动标记。
    pub fn ordered_entries(&self) -> Vec<CacheEntry> {
        let mut slots: Vec<&Slot> = self.table.values().collect();
        slots.sort_by_key(|slot| slot.stamp);
        slots.into_iter().map(|slot| slot.entry.clone()).collect()
    }

    /// 把从文件读到的条目并进来，当作比现有条目都旧（现有的同键条目为准）。改动标记不变。
    ///
    /// 应用启动后缓存文件在后台读取；读完之前已经翻译的句子在内存里，合并后都保留。
    pub fn merge_older(&mut self, entries: Vec<CacheEntry>) {
        let dirty = self.dirty;
        let mut all = entries;
        all.extend(self.ordered_entries());
        *self = Self::new(self.capacity, all);
        self.dirty = dirty;
    }

    /// 放入一条（已规整的）条目，超过容量时淘汰最久没用的。
    fn put(&mut self, entry: CacheEntry) {
        let key = composite_key(&entry.target, &entry.key);
        let stamp = self.touch(&key);
        self.table.insert(key, Slot { entry, stamp });
        // 队列与表始终一致，淘汰总能成功；万一失败也退出，不陷入死循环。
        while self.table.len() > self.capacity && self.evict_oldest() {}
    }

    /// 记下一次使用，返回新的序号。调用方随后把序号写进表。
    /// 整理放在追加之前：这时表里还是旧序号，整理掉的只是已失效的元素，新追加的元素不受影响。
    fn touch(&mut self, key: &str) -> u64 {
        if self.order.len() > 2 * self.table.len() + 64 {
            let table = &self.table;
            self.order
                .retain(|(key, stamp)| table.get(key).is_some_and(|slot| slot.stamp == *stamp));
        }
        let stamp = self.next_stamp;
        self.next_stamp += 1;
        self.order.push_back((key.to_owned(), stamp));
        stamp
    }

    /// 淘汰最久没用的一条：从队头取，序号与表里不一致（之后又被用过或已删除）的跳过。淘汰了一条时为真。
    fn evict_oldest(&mut self) -> bool {
        while let Some((key, stamp)) = self.order.pop_front() {
            if self.table.get(&key).is_some_and(|slot| slot.stamp == stamp) {
                self.table.remove(&key);
                return true;
            }
        }
        false
    }
}

/// 组合键：目标语言代码与缓存键之间用 U+0001 隔开（缓存键已规整过空白，不会含这个控制字符）。
fn composite_key(target: &str, key: &str) -> String {
    format!("{target}\u{1}{key}")
}
