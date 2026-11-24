// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的缓冲与排队，对应 macOS 的 TranslationQueue.swift（设计文档 7.6 节）。缓冲按收听者分开，每个收听者至多 300 条。
// 规则：
// - 消息由总控决定进入时的阶段（Skipped、Done、Pending、Off）。
// - activate：换了活动角色，把它最近 600 秒内最新 20 条里 Off 的消息排进队列。
// - take_batch：最早的 Pending 消息进入队列满 1 秒、没有在途的一批、没有暂停时，取一批标成 InFlight。
//   只取活动角色的消息：长时间暂停之后切换客户端时，不为没人看的缓冲花钱。
// - complete、fail：按结果改阶段与状态。一批在途时记下它的 id 集合；只有与之相同的一批才能释放在途的位置，
//   reset 或清空之后才到的旧结果仍可填上译文（complete），但不改状态。
// - complete 的结果按 rules::result_phase 换成阶段（给了目标语言时）：模型原样抄回、或判断原文已是目标语言的，
//   是 Skipped(SameLanguage)，不是 Done。
// - 答复被截断（Truncated）：一批多于 1 条时把这一批放回 Pending，之后每批至多取原来的一半；
//   只有 1 条时这一条改成 Failed。成功一批后上限加倍，回到 20 为止。
// - 等待时长：429 带 retry-after 时用答复给的秒数，不参与加倍；不带时 30 秒起，连续限流时每次加倍，上限 600 秒。
//   408、409、5xx 与网络失败 30 秒起，连续失败时每次加倍，上限 300 秒。
// - next_attempt：在等待、而活动角色没有 Pending 的消息时，返回等待结束的时刻，让总控到时调 take_batch
//   把状态改回 Idle，状态行不停在「等待重试」。
// 时刻（now、until、pending_since）都用墙上时钟的秒数，与日志里的消息时间同一个时钟。
// 缓冲用有序表，收听者的不区分大小写匹配在多个候选时取字典序靠前的，结果稳定（macOS 的字典无序）。

//! 翻译的缓冲、排队与重试。

use std::collections::{BTreeMap, BTreeSet};

use super::rules::{
    BACKFILL_QUEUE_LIMIT, BACKFILL_QUEUE_SECONDS, MAX_BATCH_MESSAGES, cache_key, next_batch, result_phase,
};
use super::{Failure, Phase, TranslatedText, TranslationItem, TranslationStatus};
use crate::chat_log::ChatMessage;
use crate::chat_log::coverage::match_name;
use crate::model::AppLanguage;

/// 最早的 Pending 消息进入队列满这么多秒才发。
pub const DEBOUNCE_SECONDS: f64 = 1.0;
/// 每个收听者至多保留几条。
pub const CAPACITY_PER_CHARACTER: usize = 300;
/// 服务出错与网络失败的首次等待秒数。
pub const BASE_RETRY_SECONDS: f64 = 30.0;
/// 连续失败时等待秒数的上限。
pub const MAX_RETRY_SECONDS: f64 = 300.0;
/// 429 没有给等待秒数时，连续限流的等待上限。
pub const MAX_RATE_LIMIT_SECONDS: f64 = 600.0;

/// 一条缓冲：条目与它变成 Pending 的时刻。
#[derive(Debug, Clone)]
struct Slot {
    /// 条目。
    item: TranslationItem,
    /// 变成 Pending（或放入）的时刻。
    pending_since: f64,
}

/// 翻译的缓冲与队列。由翻译总控持有。
#[derive(Debug, Clone)]
pub struct TranslationQueue {
    /// 队列的状态。
    status: TranslationStatus,
    /// 活动角色（最近一次 activate 的参数）。
    active_listener: Option<String>,
    /// 收听者 → 按进入顺序排列的条目。
    buffers: BTreeMap<String, Vec<Slot>>,
    /// 下一个条目编号；从不复用，浮窗按编号对齐行。
    next_id: u64,
    /// 在途的一批的 id 集合；没有在途的一批时为 None。
    in_flight: Option<BTreeSet<u64>>,
    /// 连续的服务出错与网络失败次数。
    consecutive_failures: u32,
    /// 连续的、没有给等待秒数的 429 次数。
    consecutive_rate_limits: u32,
    /// 一批至多几条；答复被截断后减半，成功后加倍，最多 20。
    batch_limit: usize,
}

impl Default for TranslationQueue {
    fn default() -> Self {
        Self {
            status: TranslationStatus::Idle,
            active_listener: None,
            buffers: BTreeMap::new(),
            next_id: 1,
            in_flight: None,
            consecutive_failures: 0,
            consecutive_rate_limits: 0,
            batch_limit: MAX_BATCH_MESSAGES,
        }
    }
}

impl TranslationQueue {
    /// 建空队列，状态是 Idle。
    pub fn new() -> Self {
        Self::default()
    }

    /// 队列的状态。
    pub fn status(&self) -> &TranslationStatus {
        &self.status
    }

    /// 活动角色。
    pub fn active_listener(&self) -> Option<&str> {
        self.active_listener.as_deref()
    }

    /// 一批至多几条。
    pub fn batch_limit(&self) -> usize {
        self.batch_limit
    }

    /// 是否有一批在途。
    pub fn has_batch_in_flight(&self) -> bool {
        self.in_flight.is_some()
    }

    /// 放入一条消息，返回它的编号。超过每个收听者的容量时丢掉最早的。
    pub fn append(&mut self, message: ChatMessage, phase: Phase, now: f64) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        // 收听者名大小写不同的日志并进同一个缓冲（同一角色换了客户端语言时会这样）。
        let key = self
            .key(&message.listener)
            .unwrap_or_else(|| message.listener.clone());
        let slots = self.buffers.entry(key).or_default();
        slots.push(Slot {
            item: TranslationItem { id, message, phase },
            pending_since: now,
        });
        if slots.len() > CAPACITY_PER_CHARACTER {
            let excess = slots.len() - CAPACITY_PER_CHARACTER;
            slots.drain(..excess);
        }
        id
    }

    /// 某个收听者的条目，按进入顺序。收听者先按原样、再不区分大小写匹配。
    pub fn items(&self, listener: &str) -> Vec<TranslationItem> {
        self.key(listener)
            .and_then(|key| self.buffers.get(&key))
            .map(|slots| slots.iter().map(|s| s.item.clone()).collect())
            .unwrap_or_default()
    }

    /// 全部收听者的条目，按编号（进入顺序）排列。目标语言或星图数据变了时，总控据此重新判断。
    pub fn all_items(&self) -> Vec<TranslationItem> {
        let mut items: Vec<TranslationItem> =
            self.buffers.values().flatten().map(|s| s.item.clone()).collect();
        items.sort_by_key(|item| item.id);
        items
    }

    /// 改一条的阶段（总控重新判断后调用）；改成 Pending 时记下时刻。找不到这一条时什么也不做。
    pub fn set_item_phase(&mut self, id: u64, phase: Phase, now: f64) {
        for slot in self.buffers.values_mut().flatten() {
            if slot.item.id == id {
                if phase == Phase::Pending {
                    slot.pending_since = now;
                }
                slot.item.phase = phase;
                return;
            }
        }
    }

    /// 换了活动角色：只看它时间在最近 600 秒内的最新 20 条，把其中 Off 的改成 Pending。
    /// 重复调用不会排进更多的消息。listener 为 None 时只记下「没有活动角色」。
    pub fn activate(&mut self, listener: Option<&str>, now: f64) {
        self.active_listener = listener.map(str::to_owned);
        let Some(key) = listener.and_then(|l| self.key(l)) else {
            return;
        };
        let Some(slots) = self.buffers.get_mut(&key) else {
            return;
        };
        // 先挑出时间在 600 秒内的，再取其中最新的 20 条。
        let recent: Vec<usize> = (0..slots.len())
            .filter(|&i| slots[i].item.message.time >= now - BACKFILL_QUEUE_SECONDS)
            .collect();
        let start = recent.len().saturating_sub(BACKFILL_QUEUE_LIMIT);
        for &index in &recent[start..] {
            if slots[index].item.phase == Phase::Off {
                slots[index].item.phase = Phase::Pending;
                slots[index].pending_since = now;
            }
        }
    }

    /// 现在该不该发下一批；该发时返回这一批并把它们标成 InFlight，状态改成 Translating。
    ///
    /// 返回 None 的情况：Blocked；Waiting 且还没到时刻；有一批在途；活动角色没有 Pending 的消息；
    /// 最早的 Pending 消息进入队列不足 1 秒。Waiting 到时后状态先回到 Idle。
    pub fn take_batch(&mut self, now: f64) -> Option<Vec<TranslationItem>> {
        match &self.status {
            TranslationStatus::Blocked(_) => return None,
            TranslationStatus::Waiting { until, .. } => {
                if now < *until {
                    return None;
                }
                self.status = TranslationStatus::Idle;
            }
            // 其余都是致命的设置问题：Key、地址、余额、请求被拒。
            _ => {}
        }
        if self.in_flight.is_some() {
            return None;
        }
        let key = self.active_key()?;
        let slots = self.buffers.get_mut(&key)?;
        // 只看排队中的；Off、Done 等都不发。
        let pending: Vec<&Slot> = slots.iter().filter(|s| s.item.phase == Phase::Pending).collect();
        let earliest = pending.iter().map(|s| s.pending_since).reduce(f64::min)?;
        if now < earliest + DEBOUNCE_SECONDS {
            return None;
        }
        let items: Vec<TranslationItem> = pending.iter().map(|s| s.item.clone()).collect();
        // 分批规则在 rules 里：缓存键去重、条数与字数上限。
        let mut batch = next_batch(&items, self.batch_limit);
        if batch.is_empty() {
            return None;
        }
        // 发请求之前的失败 ids 为空，set_phase 什么也不改，只改状态。
        let ids: BTreeSet<u64> = batch.iter().map(|item| item.id).collect();
        for slot in slots.iter_mut().filter(|s| ids.contains(&s.item.id)) {
            slot.item.phase = Phase::InFlight;
        }
        for item in &mut batch {
            item.phase = Phase::InFlight;
        }
        self.in_flight = Some(ids);
        self.status = TranslationStatus::Translating;
        Some(batch)
    }

    /// 一批的结果：有结果的改成 Done，在途而没有结果的改成 Failed；
    /// 队列里缓存键相同的其他 Pending 消息一并改成 Done。是当前在途的一批时释放位置，状态回到 Idle。
    ///
    /// 不是当前在途的一批（reset 或清空之后才到的旧结果）时，只把结果填给仍在 Pending 或 InFlight 的消息，
    /// 不把没有结果的改成 Failed，也不改状态。
    /// target 不为 None 时，结果按 [`result_phase`] 换成阶段；为 None 时一律是 Done。
    pub fn complete(
        &mut self,
        results: &BTreeMap<u64, TranslatedText>,
        batch: &[TranslationItem],
        target: Option<AppLanguage>,
    ) {
        let is_current = self.is_current_batch(batch);
        // 结果按缓存键索引：别的收听者缓冲里的同一句话也能一并填上。
        let by_key: BTreeMap<String, &TranslatedText> = batch
            .iter()
            .filter_map(|item| Some((cache_key(&item.message.text), results.get(&item.id)?)))
            .collect();
        let batch_ids: BTreeSet<u64> = batch.iter().map(|item| item.id).collect();
        for slot in self.buffers.values_mut().flatten() {
            let item = &mut slot.item;
            if item.phase != Phase::Pending && item.phase != Phase::InFlight {
                continue;
            }
            if let Some(result) = by_key.get(&cache_key(&item.message.text)) {
                item.phase = match target {
                    Some(target) => result_phase(result, &item.message.text, target),
                    None => Phase::Done {
                        text: result.text.clone(),
                        source_language: result.source_language.clone(),
                    },
                };
            } else if is_current && item.phase == Phase::InFlight && batch_ids.contains(&item.id) {
                item.phase = Phase::Failed;
            }
        }
        // 旧请求的结果到此为止：不动计数、上限与状态。
        if !is_current {
            return;
        }
        self.in_flight = None;
        self.consecutive_failures = 0;
        self.consecutive_rate_limits = 0;
        // 成功一批说明这个大小可行，逐步放大回 20。
        self.batch_limit = (self.batch_limit * 2).min(MAX_BATCH_MESSAGES);
        if self.status == TranslationStatus::Translating {
            self.status = TranslationStatus::Idle;
        }
    }

    /// 一批失败，或者发请求之前就发现的失败（batch 为空）。
    ///
    /// - 致命的失败：这一批回到 Pending，状态改成 Blocked。
    /// - RateLimited：这一批回到 Pending；有秒数时等答复给的秒数，没有时等 30 秒，连续限流时加倍，上限 600 秒。
    /// - Server、Network：这一批回到 Pending，等 30 秒，连续失败时加倍，上限 300 秒。
    /// - Truncated：多于 1 条时这一批回到 Pending，每批的上限改成这一批条数的一半；只有 1 条时改成 Failed。
    /// - MalformedAnswer、Refused：这一批改成 Failed，状态回到 Idle。
    ///
    /// batch 不为空但不是当前在途的一批时（旧请求的结果）不做任何事。
    pub fn fail(&mut self, failure: Failure, batch: &[TranslationItem], now: f64) {
        if !batch.is_empty() {
            if !self.is_current_batch(batch) {
                return;
            }
            self.in_flight = None;
        }
        let ids: BTreeSet<u64> = batch.iter().map(|item| item.id).collect();
        match &failure {
            Failure::Truncated if batch.len() > 1 => {
                self.set_phase(&ids, Phase::Pending, now);
                self.batch_limit = (batch.len() / 2).max(1);
                self.status = TranslationStatus::Idle;
            }
            Failure::MalformedAnswer | Failure::Refused | Failure::Truncated => {
                self.set_phase(&ids, Phase::Failed, now);
                self.consecutive_failures = 0;
                self.status = TranslationStatus::Idle;
            }
            // 服务明确给了等待秒数：照用，不加倍。
            Failure::RateLimited(Some(seconds)) => {
                let until = now + seconds;
                self.set_phase(&ids, Phase::Pending, now);
                self.status = TranslationStatus::Waiting {
                    until,
                    reason: failure,
                };
            }
            Failure::RateLimited(None) => {
                self.set_phase(&ids, Phase::Pending, now);
                self.consecutive_rate_limits += 1;
                let delay = backoff(self.consecutive_rate_limits, MAX_RATE_LIMIT_SECONDS);
                self.status = TranslationStatus::Waiting {
                    until: now + delay,
                    reason: failure,
                };
            }
            Failure::Server(_) | Failure::Network(_) => {
                self.set_phase(&ids, Phase::Pending, now);
                self.consecutive_failures += 1;
                let delay = backoff(self.consecutive_failures, MAX_RETRY_SECONDS);
                self.status = TranslationStatus::Waiting {
                    until: now + delay,
                    reason: failure,
                };
            }
            _ => {
                self.set_phase(&ids, Phase::Pending, now);
                self.status = TranslationStatus::Blocked(failure);
            }
        }
    }

    /// 设置或 Key 变了、或用户点了重试：状态回到 Idle，连续失败的计数清零；在途的消息回到 Pending，
    /// 最近 600 秒内 Failed 的消息改回 Pending。在途的请求由总控丢弃，它的结果到达时按旧结果处理。
    pub fn reset(&mut self, now: f64) {
        self.status = TranslationStatus::Idle;
        self.consecutive_failures = 0;
        self.consecutive_rate_limits = 0;
        self.batch_limit = MAX_BATCH_MESSAGES;
        self.in_flight = None;
        for slot in self.buffers.values_mut().flatten() {
            let item = &slot.item;
            // 用户点了重试：最近的失败消息再试一次，太旧的不再花钱。
            let retry = item.phase == Phase::Failed && item.message.time >= now - BACKFILL_QUEUE_SECONDS;
            if item.phase == Phase::InFlight || retry {
                slot.item.phase = Phase::Pending;
                slot.pending_since = now;
            }
        }
    }

    /// 下一次该调 take_batch 的时刻；Blocked 或有一批在途时为 None。
    /// 活动角色没有 Pending 的消息时：在等待则是等待结束的时刻（到时 take_batch 把状态改回 Idle），否则为 None。
    pub fn next_attempt(&self) -> Option<f64> {
        if matches!(self.status, TranslationStatus::Blocked(_)) || self.in_flight.is_some() {
            return None;
        }
        // 等待中而没有待发的消息时，也要在等待结束时叫醒一次，把状态改回 Idle。
        let waiting_until = match self.status {
            TranslationStatus::Waiting { until, .. } => Some(until),
            _ => None,
        };
        let earliest = self
            .active_key()
            .and_then(|key| self.buffers.get(&key))
            .and_then(|slots| {
                slots
                    .iter()
                    .filter(|s| s.item.phase == Phase::Pending)
                    .map(|s| s.pending_since)
                    .reduce(f64::min)
            });
        match (earliest, waiting_until) {
            (Some(earliest), Some(until)) => Some((earliest + DEBOUNCE_SECONDS).max(until)),
            (Some(earliest), None) => Some(earliest + DEBOUNCE_SECONDS),
            (None, waiting) => waiting,
        }
    }

    /// 清空全部缓冲与状态（目标语言变了时调用，之后总控重新放入消息）。编号不复用。
    pub fn clear(&mut self) {
        // 编号接着用：浮窗靠编号对齐行，复用会把旧行当成新行。
        let next_id = self.next_id;
        let active = self.active_listener.take();
        *self = Self::default();
        self.next_id = next_id;
        self.active_listener = active;
    }

    /// 清空某个收听者（None 表示全部）的缓冲，不改状态与在途的位置：跟踪请求变了、或用户点「清空列表」时调用，
    /// 暂停的原因（如 Key 无效）不因此消失；在途的一批的结果到达时照常释放位置。
    pub fn remove_items(&mut self, listener: Option<&str>) {
        match listener {
            None => self.buffers.clear(),
            Some(listener) => {
                if let Some(key) = self.key(listener) {
                    self.buffers.remove(&key);
                }
            }
        }
    }

    /// 收听者对应的缓冲键：先原样，再不区分大小写。
    fn key(&self, listener: &str) -> Option<String> {
        match_name(listener, self.buffers.keys().map(String::as_str)).map(str::to_owned)
    }

    /// 活动角色的缓冲键。
    fn active_key(&self) -> Option<String> {
        self.active_listener.as_deref().and_then(|l| self.key(l))
    }

    /// batch 是否就是当前在途的那一批。
    fn is_current_batch(&self, batch: &[TranslationItem]) -> bool {
        match &self.in_flight {
            Some(ids) if !batch.is_empty() => {
                batch.iter().map(|item| item.id).collect::<BTreeSet<_>>() == *ids
            }
            _ => false,
        }
    }

    /// 把 ids 里仍在途的条目改成 phase；改成 Pending 时记下时刻。
    fn set_phase(&mut self, ids: &BTreeSet<u64>, phase: Phase, now: f64) {
        if ids.is_empty() {
            return;
        }
        for slot in self.buffers.values_mut().flatten() {
            if ids.contains(&slot.item.id) && slot.item.phase == Phase::InFlight {
                slot.item.phase = phase.clone();
                if phase == Phase::Pending {
                    slot.pending_since = now;
                }
            }
        }
    }
}

/// 第 count 次连续失败的等待秒数：30 秒起每次加倍，不超过 cap。指数至多 16，避免溢出。
fn backoff(count: u32, cap: f64) -> f64 {
    let exponent = count.saturating_sub(1).min(16);
    (BASE_RETRY_SECONDS * f64::from(1u32 << exponent)).min(cap)
}
