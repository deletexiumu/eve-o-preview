// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译控制器的发送部分（设计文档 7.4～7.6 节）：检查设置与 Key、用缓存先填、拼请求、交给后台线程、处理答复。
// - 同一时刻至多一批在途，由队列判断；每发一批代次加 1，代次变过的答复是旧请求，只存缓存、填译文，不改状态。
// - 每个请求一个短命线程，答复经通道回到主线程，由 tick 取走；建不了线程时按网络失败处理。
// - 日志只写条数、耗时与失败的种类。

//! 翻译控制器：发送与答复。

use std::collections::BTreeMap;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use eveo_core::translation::prompt::{self, PromptContent};
use eveo_core::translation::{
    ApiKind, Endpoint, Failure, HttpRequest, HttpResponse, Phase, TranslatedText, TranslationItem,
    TranslationStatus, TransportError, providers, wire,
};

use super::text::failure_log_name;
use super::{KeyState, Purpose, Sent, TranslationController};

impl TranslationController {
    /// 检查设置与 Key，能发时取一批交给后台线程。
    pub(super) fn pump(&mut self, now: f64) {
        if !self.is_enabled() {
            self.notify_if_status_changed();
            return;
        }
        // 缓存里已有的句子不论队列是否暂停、有没有在途的一批，都先填上。
        if self.fill_pending_from_cache() {
            self.changed = true;
        }
        if let Some(endpoint) = self.ready_endpoint(now)
            && let Some(batch) = self.queue.take_batch(now)
        {
            self.send(batch, &endpoint, now);
        }
        self.notify_if_status_changed();
    }

    /// 能发请求时返回接口与 Key；不能时（暂停中、设置不对、缺 Key）返回 None，必要时把队列标成暂停。
    pub(super) fn ready_endpoint(&mut self, now: f64) -> Option<(Endpoint, Option<String>)> {
        if matches!(self.queue.status(), TranslationStatus::Blocked(_)) {
            return None;
        }
        // 每次都重新解析接口：设置可能刚改，解析只是几次字符串操作。
        let settings = self.context.as_ref()?.general.translation_endpoint.clone();
        let endpoint = match providers::resolve(&settings) {
            Ok(endpoint) => endpoint,
            Err(issue) => {
                self.queue.fail(Failure::NotConfigured(issue), &[], now);
                return None;
            }
        };
        match self.key_for(&endpoint) {
            Ok(key) => Some((endpoint, key)),
            Err(failure) => {
                self.queue.fail(failure, &[], now);
                None
            }
        }
    }

    /// 这个接口要用的 Key：要 Key 而内存里没有时是 MissingKey 或 KeychainUnavailable。
    pub(super) fn key_for(&self, endpoint: &Endpoint) -> Result<Option<String>, Failure> {
        let key = match &self.key {
            KeyState::Value(value) if self.key_provider == Some(endpoint.provider) => Some(value.clone()),
            _ => None,
        };
        if endpoint.requires_key && key.is_none() {
            return Err(if self.key == KeyState::Unavailable {
                Failure::KeychainUnavailable
            } else {
                Failure::MissingKey
            });
        }
        Ok(key)
    }

    /// 发请求之前，先用缓存填上活动角色排队中的消息，返回是否填了。
    ///
    /// 同一条消息会写进每个收听角色的文件。活动角色那一份翻译完时，其他角色的副本还是 Off，
    /// 切换客户端后 activate 把它们排进队列；这里先查缓存，已翻译过的句子不再付费。
    /// 填的方式是一批「不在途」的结果：队列只改这些消息与缓存键相同的 Pending 消息，不改状态。
    pub(super) fn fill_pending_from_cache(&mut self) -> bool {
        let (Some(active), Some(target)) = (
            self.context.as_ref().and_then(|c| c.active_character.clone()),
            self.target,
        ) else {
            return false;
        };
        let mut hits: BTreeMap<u64, TranslatedText> = BTreeMap::new();
        let mut hit_items = Vec::new();
        for item in self.queue.items(&active) {
            if item.phase != Phase::Pending {
                continue;
            }
            if let Some(value) = self.cache.value(&item.message.text, target) {
                hits.insert(item.id, value);
                hit_items.push(item);
            }
        }
        if hit_items.is_empty() {
            return false;
        }
        self.queue.complete(&hits, &hit_items, Some(target));
        true
    }

    /// 发出一批：拼好请求，交给后台线程。
    pub(super) fn send(
        &mut self,
        batch: Vec<TranslationItem>,
        (endpoint, key): &(Endpoint, Option<String>),
        now: f64,
    ) {
        let target = self.target.unwrap_or_else(|| self.language());
        let data = self.context.as_ref().and_then(|c| c.static_data.clone());
        // 每条消息里识别出的星系、舰船等术语钉住译名，合并后一起交给模型。
        let groups: Vec<_> = batch
            .iter()
            .map(|item| {
                let matches = data
                    .as_ref()
                    .map(|d| d.matcher.matches(&item.message.text))
                    .unwrap_or_default();
                prompt::pins(&item.message.text, &matches, target)
            })
            .collect();
        let pins = prompt::merged_pins(&groups);
        let content = prompt::content(&batch, &pins, target);
        // 每发一批代次加 1：只有代次没变的答复才是「当前请求」，能改队列的状态。
        let request = wire::request(endpoint, key.as_deref(), &content);
        self.generation += 1;
        self.log.push(format!(
            "翻译：发送一批 {} 条，钉住 {} 个术语",
            batch.len(),
            pins.len()
        ));
        let purpose = Purpose::Batch {
            batch,
            target,
            generation: self.generation,
        };
        let serial = self.dispatch(request, purpose, &content, endpoint.kind, now);
        // 线程建不出来时 dispatch 已按网络失败处理，这时不占在途的位置。
        if let Some(serial) = serial {
            self.current_serial = Some(serial);
        }
    }

    /// 把请求交给一个后台线程，返回请求序号；建不了线程时立刻按网络失败处理并返回 None。
    pub(super) fn dispatch(
        &mut self,
        request: HttpRequest,
        purpose: Purpose,
        content: &PromptContent,
        kind: ApiKind,
        now: f64,
    ) -> Option<u64> {
        let serial = self.next_serial;
        self.next_serial += 1;
        self.sent.insert(
            serial,
            Sent {
                purpose,
                ids: content.ids.clone(),
                kind,
                started: Instant::now(),
            },
        );
        // 每个请求一个短命线程：同一时刻至多一批在途（另加可能的旧请求与测试），线程数很少。
        let transport = Arc::clone(&self.transport);
        let sender = self.reply_sender.clone();
        let spawned = thread::Builder::new()
            .name("eveo-translation".into())
            .spawn(move || {
                let result = transport(&request);
                // 接收端不在了（控制器已丢掉）时结果没人要，忽略发送失败。
                let _ = sender.send((serial, result));
            });
        if spawned.is_err() {
            let failure = Err(TransportError::Network("thread unavailable".into()));
            self.finish(serial, failure, now);
            return None;
        }
        Some(serial)
    }

    /// 收后台线程交回的全部答复。
    pub(super) fn drain_replies(&mut self, now: f64) {
        // 发送端有一份在控制器自己手里，通道不会断开；取到 Empty 就是收完了。
        while let Ok((serial, result)) = self.replies.try_recv() {
            self.finish(serial, result, now);
        }
    }

    /// 一个请求的结果：翻译一批时存缓存、改队列，再看能不能发下一批；测试时记下结果。
    pub(super) fn finish(&mut self, serial: u64, result: Result<HttpResponse, TransportError>, now: f64) {
        // 关掉功能时丢掉了记录：结果不要了。
        let Some(sent) = self.sent.remove(&serial) else {
            return;
        };
        if self.current_serial == Some(serial) {
            self.current_serial = None;
        }
        let milliseconds = sent.started.elapsed().as_millis();
        let outcome = outcome(result, &sent.ids, sent.kind);
        match sent.purpose {
            Purpose::Test => self.finish_test(outcome),
            Purpose::Batch {
                batch,
                target,
                generation,
            } => {
                // 代次变过（设置、Key 或目标语言变了，或之后又发了一批）就是旧请求。
                let is_current = generation == self.generation;
                match outcome {
                    Ok(results) => {
                        for item in &batch {
                            if let Some(value) = results.get(&item.id) {
                                self.cache.store(value, &item.message.text, target);
                            }
                        }
                        // 目标语言变了时缓冲里已是新的条目，旧译文只进缓存，不填给它们。
                        if Some(target) == self.target {
                            self.queue.complete(&results, &batch, Some(target));
                        }
                        let suffix = if is_current { "" } else { "（旧请求）" };
                        self.log.push(format!(
                            "翻译：收到 {}/{} 条，耗时 {milliseconds} 毫秒{suffix}",
                            results.len(),
                            batch.len()
                        ));
                    }
                    Err(failure) => {
                        if is_current {
                            self.queue.fail(failure.clone(), &batch, now);
                        }
                        let name = failure_log_name(&failure);
                        self.log
                            .push(format!("翻译失败：{name}，耗时 {milliseconds} 毫秒"));
                    }
                }
                self.changed = true;
                self.refresh_status();
                self.pump(now);
            }
        }
    }

    /// 让在途的请求变成旧请求；drop_result 为真时连结果也丢掉（关掉功能或停止时）。
    pub(super) fn abandon_in_flight(&mut self, drop_result: bool) {
        if let Some(serial) = self.current_serial.take()
            && drop_result
        {
            self.sent.remove(&serial);
        }
        self.generation += 1;
    }
}

/// 答复换成译文或失败。
pub(super) fn outcome(
    result: Result<HttpResponse, TransportError>,
    ids: &BTreeMap<i64, u64>,
    kind: ApiKind,
) -> Result<BTreeMap<u64, TranslatedText>, Failure> {
    let response = result.map_err(|error| wire::failure_for(&error))?;
    let answer = wire::answer(&response, kind)?;
    wire::parse(&answer, ids)
}
