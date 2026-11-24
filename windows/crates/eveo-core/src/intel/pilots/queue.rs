// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的排队与节流，对应 macOS 的 PilotLookupQueue.swift（设计文档 6.10 节）。只是状态机，不发请求、
// 不读时钟：时刻都由调用方传入（墙上时钟）。
// - enqueue：名字按比较键记进待查，记下排进来的时刻；已在待查或在途的不重复排；超过 2,000 个时丢最早的。
// - take_batch：有一批在途、在等待且没到时刻、没有待查、最早的名字排进来不足 0.5 秒、距上一批不足 2 秒时
//   返回 None；否则取最早的至多 500 个，状态改成 Resolving。两批之间至少 2 秒，每分钟至多 30 个请求。
// - complete：这一批离开在途，连续失败清零。错误额度（error_limit_remain）小于 20 时等 error_limit_reset 秒
//   （夹到 1～120，没有时 60），否则回到 Idle。
// - fail：RateLimited 回到待查、等 retry_after 秒；Network、Server、MalformedAnswer 回到待查、等 30 秒，
//   连续失败时每次加倍，上限 600 秒；Rejected 丢掉这一批、等 300 秒（请求写法有错，重发只会再扣错误额度）。
// - Rejected 的名字另记进内存里的「暂不查」表，1 小时内 enqueue 不再排它们：补排每次从缓冲里收集名字，
//   不记的话同一批会在每次补排时重新发出。这张表不写文件，remove_all 不清（同等待的时刻）。
// 失败不产生任何结果，缓存不变。

//! 人名核对的排队与节流。

use std::collections::{HashMap, HashSet, VecDeque};

use super::wire::MAX_NAMES_PER_REQUEST;
use super::{PilotLookupAnswer, PilotLookupFailure, PilotLookupStatus, key};

/// 最早的名字排进来后至少等多久再发：同一条消息的名字一起发。
pub const DEBOUNCE_SECONDS: f64 = 0.5;
/// 两批之间至少隔多久。
pub const MINIMUM_INTERVAL: f64 = 2.0;
/// 待查的名字至多几个。
pub const MAX_PENDING: usize = 2_000;
/// 错误额度低于这个数时暂停：ESI 的错误额度用完会封 IP，留出余量。
pub const LOW_ERROR_BUDGET: i64 = 20;
/// 失败后等待的起点。
const FAILURE_DELAY: f64 = 30.0;
/// 失败后等待的上限。
const MAX_FAILURE_DELAY: f64 = 600.0;
/// Rejected 后的等待。
const REJECTED_DELAY: f64 = 300.0;
/// Rejected 的名字多久之内不再排。
const REJECTED_HOLD_SECONDS: f64 = 3_600.0;

/// 一个待查的名字。
#[derive(Debug, Clone)]
struct Pending {
    /// 比较键。
    key: String,
    /// 原文的写法（发给 ESI 的就是它）。
    name: String,
    /// 排进来的时刻。
    enqueued_at: f64,
}

/// 人名核对的队列。
#[derive(Debug, Clone, Default)]
pub struct PilotLookupQueue {
    /// 待查的名字，最早的在前。
    pending: VecDeque<Pending>,
    /// 待查名字的比较键，查重用。
    pending_keys: HashSet<String>,
    /// 在途的一批。
    in_flight: Option<Vec<Pending>>,
    /// 等到这个时刻再发；None 表示不在等待。
    waiting_until: Option<f64>,
    /// 上一批发出的时刻。
    last_batch_at: Option<f64>,
    /// 连续失败的次数（Network、Server、MalformedAnswer）。
    consecutive_failures: u32,
    /// 被 Rejected 的名字的比较键 → 到这个时刻之前不再排。
    rejected_until: HashMap<String, f64>,
}

impl PilotLookupQueue {
    /// 当前状态（不含 Off；Off 由控制器按开关判断）。等待的时刻已过、还没取下一批时仍是 Waiting，
    /// 界面按剩余秒数显示（不足 1 秒时显示成就绪）。
    pub fn status(&self) -> PilotLookupStatus {
        if self.in_flight.is_some() {
            PilotLookupStatus::Resolving
        } else if let Some(until) = self.waiting_until {
            PilotLookupStatus::Waiting(until)
        } else {
            PilotLookupStatus::Idle
        }
    }

    /// 待查的名字个数。
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// 排进待查的名字；已在待查或在途的、1 小时内被 Rejected 的不排。超过 2,000 个时丢最早的。
    pub fn enqueue<S: AsRef<str>>(&mut self, names: &[S], now: f64) {
        let in_flight_keys: HashSet<&str> = self.in_flight.iter().flatten().map(|p| p.key.as_str()).collect();
        // 顺手清掉已到期的「暂不查」记录，表不会无限长。
        self.rejected_until.retain(|_, until| *until > now);
        let mut added = Vec::new();
        for name in names {
            let name = name.as_ref();
            let name_key = key(name);
            if name_key.is_empty()
                || self.pending_keys.contains(&name_key)
                || in_flight_keys.contains(name_key.as_str())
                || self.rejected_until.contains_key(&name_key)
            {
                continue;
            }
            self.pending_keys.insert(name_key.clone());
            added.push(Pending {
                key: name_key,
                name: name.to_owned(),
                enqueued_at: now,
            });
        }
        self.pending.extend(added);
        self.trim_pending();
    }

    /// 取下一批；不能发时返回 None。
    pub fn take_batch(&mut self, now: f64) -> Option<Vec<String>> {
        if self.in_flight.is_some() {
            return None;
        }
        let first = self.pending.front()?;
        if self.waiting_until.is_some_and(|until| now < until)
            || now - first.enqueued_at < DEBOUNCE_SECONDS
            || self
                .last_batch_at
                .is_some_and(|last| now - last < MINIMUM_INTERVAL)
        {
            return None;
        }
        // 取最早的至多 500 个；它们离开待查（也离开查重表），进入在途。
        let count = MAX_NAMES_PER_REQUEST.min(self.pending.len());
        let batch: Vec<Pending> = self.pending.drain(..count).collect();
        for item in &batch {
            self.pending_keys.remove(&item.key);
        }
        let names = batch.iter().map(|p| p.name.clone()).collect();
        self.in_flight = Some(batch);
        self.waiting_until = None;
        self.last_batch_at = Some(now);
        Some(names)
    }

    /// 下一次可以调 take_batch 的时刻；没有待查的名字或有一批在途时返回 None。
    /// 控制器据此安排下一次唤醒，不必每个 tick 都试。
    pub fn next_attempt(&self) -> Option<f64> {
        if self.in_flight.is_some() {
            return None;
        }
        let first = self.pending.front()?;
        let mut time = first.enqueued_at + DEBOUNCE_SECONDS;
        if let Some(last) = self.last_batch_at {
            time = time.max(last + MINIMUM_INTERVAL);
        }
        if let Some(until) = self.waiting_until {
            time = time.max(until);
        }
        Some(time)
    }

    /// 一批成功：离开在途，连续失败清零；错误额度低时进入等待。
    pub fn complete(&mut self, answer: &PilotLookupAnswer, now: f64) {
        self.in_flight = None;
        self.consecutive_failures = 0;
        self.waiting_until = match answer.error_limit_remain {
            Some(remain) if remain < LOW_ERROR_BUDGET => {
                let reset = answer.error_limit_reset.unwrap_or(60) as f64;
                Some(now + reset.clamp(1.0, 120.0))
            }
            _ => None,
        };
    }

    /// 一批失败：按失败的种类决定这一批回不回到待查、等多久。
    pub fn fail(&mut self, failure: &PilotLookupFailure, now: f64) {
        // 没有在途的一批时（调用顺序出错）当作空批处理，只更新等待的时刻。
        let batch = self.in_flight.take().unwrap_or_default();
        match failure {
            // 限流不是名字的问题，原样放回；不计入连续失败，等待时间完全按 ESI 的要求。
            PilotLookupFailure::RateLimited { retry_after } => {
                self.requeue(batch);
                self.waiting_until = Some(now + retry_after.max(0.0));
            }
            PilotLookupFailure::Network(_)
            | PilotLookupFailure::Server { .. }
            | PilotLookupFailure::MalformedAnswer => {
                self.requeue(batch);
                self.consecutive_failures += 1;
                // 30、60、120……秒，指数封顶在 2^10 防止溢出，再夹到 600 秒。
                let exponent = (self.consecutive_failures - 1).min(10) as i32;
                let delay = FAILURE_DELAY * 2f64.powi(exponent);
                self.waiting_until = Some(now + delay.min(MAX_FAILURE_DELAY));
            }
            PilotLookupFailure::Rejected { .. } => {
                self.waiting_until = Some(now + REJECTED_DELAY);
                for item in batch {
                    self.rejected_until.insert(item.key, now + REJECTED_HOLD_SECONDS);
                }
            }
        }
    }

    /// 清空待查与在途。等待的时刻保留：开关关了再开不应绕过 ESI 要求的等待。
    pub fn remove_all(&mut self) {
        self.pending.clear();
        self.pending_keys.clear();
        self.in_flight = None;
        self.consecutive_failures = 0;
    }

    /// 失败的一批放回待查的最前面，保留原来排进来的时刻；期间又排进来的同名不重复。
    fn requeue(&mut self, batch: Vec<Pending>) {
        let restored: Vec<Pending> = batch
            .into_iter()
            .filter(|p| !self.pending_keys.contains(&p.key))
            .collect();
        // 倒着插到最前面，插完后顺序与原来一致。
        for item in restored.into_iter().rev() {
            self.pending_keys.insert(item.key.clone());
            self.pending.push_front(item);
        }
        self.trim_pending();
    }

    /// 超过上限时丢最早的。
    fn trim_pending(&mut self) {
        while self.pending.len() > MAX_PENDING {
            if let Some(item) = self.pending.pop_front() {
                self.pending_keys.remove(&item.key);
            }
        }
    }
}
