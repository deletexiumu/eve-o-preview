// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译控制器的 Key、译文缓存文件与「翻译」页用的接口（设计文档 7.7 节、7.8 节）：
// - Key 只在 3 个时机从凭据管理器读：开关打开或预设变了、用户点「保存」、用户点「测试」或「立即重试」且内存里没有。
// - 缓存文件在建控制器时于后台读，读完与内存里的条目合并；有改动时满 30 秒交给写入线程存一次。
// - 设置接口：缓存条数、清空缓存、Key 是否已保存、保存与删除 Key、立即重试、测试。
// Key 只经过内存，不写日志；日志只写错误码与条数。

//! 翻译控制器：Key、缓存文件与设置接口。

use std::collections::BTreeMap;
use std::sync::mpsc::{self, TryRecvError};
use std::thread;

use eveo_core::model::{AppLanguage, TranslationEndpointSettings, TranslationProviderId};
use eveo_core::translation::cache::CacheEntry;
use eveo_core::translation::{Failure, TranslatedText, TranslationStatus, prompt, providers, wire};

use super::store::TranslationCacheStore;
use super::text::failure_log_name;
use super::{CACHE_SAVE_INTERVAL, CacheLoad, KeyState, Purpose, SecretError, TranslationController, Writer};

impl TranslationController {
    /// 读一次 Key，结果留在内存里。只在 7.7 节的 3 个时机调用。
    pub(super) fn load_key(&mut self, provider: TranslationProviderId) {
        self.key_provider = Some(provider);
        if !uses_key(provider) {
            self.key = KeyState::Missing;
            return;
        }
        // 读到空串当作没有 Key；读取失败只记错误码，Key 的状态是 Unavailable。
        self.key = match self.secrets.read(&providers::credential_account(provider)) {
            Ok(Some(value)) if !value.is_empty() => KeyState::Value(value),
            Ok(_) => KeyState::Missing,
            Err(error) => {
                self.log.push(format!(
                    "凭据管理器：读取 Key 失败（{}）",
                    secret_error_code(error)
                ));
                KeyState::Unavailable
            }
        };
    }

    /// 内存里是否有 Key 的值。
    pub(super) fn has_key_value(&self) -> bool {
        matches!(self.key, KeyState::Value(_))
    }

    // MARK: 译文缓存

    /// 在后台线程读缓存文件；建不了线程时直接在这里读。
    pub(super) fn start_loading(&mut self) {
        let (sender, receiver) = mpsc::channel();
        let store = self.cache_store.clone();
        let spawned = thread::Builder::new()
            .name("eveo-translation-cache-load".into())
            .spawn(move || {
                let _ = sender.send(store.load());
            });
        self.cache_load = match spawned {
            Ok(_) => CacheLoad::Loading(receiver),
            Err(_) => {
                let entries = self.cache_store.load();
                self.cache_loaded(entries);
                CacheLoad::Loaded
            }
        };
    }

    /// 收读文件的结果。
    pub(super) fn poll_loading(&mut self) {
        let CacheLoad::Loading(receiver) = &self.cache_load else {
            return;
        };
        let entries = match receiver.try_recv() {
            Ok(entries) => entries,
            Err(TryRecvError::Empty) => return,
            // 读文件的线程意外退出：从空缓存开始。
            Err(TryRecvError::Disconnected) => Vec::new(),
        };
        self.cache_load = CacheLoad::Loaded;
        self.cache_loaded(entries);
    }

    /// 缓存文件读完：与内存里的条目合并（读完之前用户清空过时丢掉读到的）。之后有改动时才存盘。
    pub(super) fn cache_loaded(&mut self, entries: Vec<CacheEntry>) {
        // 文件里的条目当作比内存里的旧：读完之前已经翻译的句子以内存为准。
        let count = entries.len();
        if !self.discard_loaded_cache {
            self.cache.merge_older(entries);
        }
        self.log.push(format!("译文缓存：读入 {count} 条"));
        // 「翻译」页显示缓存条数，要刷新。
        self.changed = true;
    }

    /// 缓存有改动、且距上次存盘满 30 秒（或 force）时，交给写入线程存一次。读完文件之前不存。
    pub(super) fn save_cache_if_due(&mut self, now: f64, force: bool) {
        if !matches!(self.cache_load, CacheLoad::Loaded)
            || !self.cache.is_dirty()
            || !(force || now - self.last_cache_save >= CACHE_SAVE_INTERVAL)
        {
            return;
        }
        self.last_cache_save = now;
        let entries = self.cache.snapshot();
        self.write_async(entries);
    }

    /// 交给写入线程写文件；线程还没建时先建，建不了时在这里同步写。
    pub(super) fn write_async(&mut self, entries: Vec<CacheEntry>) {
        if self.writer.is_none() {
            self.writer = spawn_writer(self.cache_store.clone());
        }
        // 发送失败（线程已退出）时取回快照，在这里同步写，不丢这次改动。
        let entries = match &self.writer {
            Some(writer) => match writer.snapshots.send(entries) {
                Ok(()) => return,
                Err(mpsc::SendError(entries)) => entries,
            },
            None => entries,
        };
        if let Err(error) = self.cache_store.save(entries) {
            self.log.push(format!("译文缓存存盘失败：{:?}", error.kind()));
        }
    }

    // MARK: 设置界面用的接口

    /// 译文缓存的条数。
    pub fn cache_count(&self) -> usize {
        self.cache.len()
    }

    /// 清空译文缓存并存盘（文件变成空的）。文件还没读完时，读完的结果不再用。
    pub fn clear_cache(&mut self, now: f64) {
        self.cache.clear();
        if matches!(self.cache_load, CacheLoad::Loaded) {
            self.save_cache_if_due(now, true);
        } else {
            self.discard_loaded_cache = true;
        }
        self.log.push("译文缓存已清空".to_owned());
        self.changed = true;
    }

    /// 某个预设的 Key 是否已在凭据管理器里：读过且有值（或读取失败）时为真，读过且没有时为假，没读过时为 None。
    pub fn is_key_stored(&self, provider: TranslationProviderId) -> Option<bool> {
        if self.key_provider != Some(provider) {
            return None;
        }
        match self.key {
            KeyState::Value(_) | KeyState::Unavailable => Some(true),
            KeyState::Missing => Some(false),
            KeyState::Unknown => None,
        }
    }

    /// 用户点「保存」：写进凭据管理器并留在内存里，清掉暂停后重试。空白的输入什么也不做。
    pub fn save_key(
        &mut self,
        raw_key: &str,
        provider: TranslationProviderId,
        now: f64,
    ) -> Result<(), SecretError> {
        // 用户粘贴的 Key 常带首尾空白或换行，去掉后再存。
        let value = raw_key.trim();
        if value.is_empty() {
            return Ok(());
        }
        if let Err(error) = self
            .secrets
            .write(&providers::credential_account(provider), value)
        {
            self.log.push(format!(
                "凭据管理器：保存 Key 失败（{}）",
                secret_error_code(error)
            ));
            return Err(error);
        }
        self.key_provider = Some(provider);
        self.key = KeyState::Value(value.to_owned());
        self.log.push("凭据管理器：已保存 Key".to_owned());
        self.restart(now);
        Ok(())
    }

    /// 用户点「删除 Key」：从凭据管理器删掉，内存里也清掉。
    pub fn delete_key(&mut self, provider: TranslationProviderId, now: f64) -> Result<(), SecretError> {
        self.secrets.delete(&providers::credential_account(provider))?;
        self.key_provider = Some(provider);
        self.key = KeyState::Missing;
        self.log.push("凭据管理器：已删除 Key".to_owned());
        self.restart(now);
        Ok(())
    }

    /// 用户点「立即重试」：内存里没有 Key 时再读一次，清掉暂停，失败的消息重新排队。
    pub fn retry(&mut self, now: f64) {
        let Some(provider) = self
            .context
            .as_ref()
            .map(|c| c.general.translation_endpoint.provider)
        else {
            return;
        };
        if uses_key(provider) && (self.key_provider != Some(provider) || !self.has_key_value()) {
            self.load_key(provider);
        }
        self.restart(now);
    }

    /// 用户点「测试」：用给出的接口设置与当前的 Key 发一次固定样例。结果由 take_test_result 取走。
    /// 内存里没有这个预设的 Key 时再读一次。测试不改队列的状态。已有一次在等答复时什么也不做。
    pub fn start_test(&mut self, settings: &TranslationEndpointSettings, target: AppLanguage, now: f64) {
        if self.testing || self.stopped {
            return;
        }
        // 新的一次测试开始前清掉上一次的结果，界面不会显示过时的结果。
        self.test_result = None;
        let endpoint = match providers::resolve(settings) {
            Ok(endpoint) => endpoint,
            Err(issue) => {
                self.test_result = Some(Err(Failure::NotConfigured(issue)));
                return;
            }
        };
        if uses_key(endpoint.provider)
            && (self.key_provider != Some(endpoint.provider) || !self.has_key_value())
        {
            self.load_key(endpoint.provider);
            // 这次读到了 Key，而队列正因为没有 Key 暂停着：解除暂停，浮窗不必等用户再点「立即重试」。
            let current = self
                .context
                .as_ref()
                .map(|c| c.general.translation_endpoint.provider);
            let blocked_on_key = matches!(
                self.queue.status(),
                TranslationStatus::Blocked(Failure::MissingKey | Failure::KeychainUnavailable)
            );
            if self.has_key_value() && current == Some(endpoint.provider) && blocked_on_key {
                self.restart(now);
            }
            self.changed = true;
        }
        let key = match self.key_for(&endpoint) {
            Ok(key) => key,
            Err(failure) => {
                self.test_result = Some(Err(failure));
                return;
            }
        };
        let content = prompt::test_content(target);
        let request = wire::request(&endpoint, key.as_deref(), &content);
        self.testing = true;
        self.dispatch(request, Purpose::Test, &content, endpoint.kind, now);
    }

    /// 「测试」是否在等答复。
    pub fn is_testing(&self) -> bool {
        self.testing
    }

    /// 取走「测试」的结果：成功时是译文。还没有结果时为 None。
    pub fn take_test_result(&mut self) -> Option<Result<String, Failure>> {
        self.test_result.take()
    }

    /// 测试的答复：记下译文或失败。
    pub(super) fn finish_test(&mut self, outcome: Result<BTreeMap<u64, TranslatedText>, Failure>) {
        self.testing = false;
        let result = outcome.and_then(|results| {
            results
                .into_values()
                .next()
                .map(|value| value.text)
                .ok_or(Failure::MalformedAnswer)
        });
        match &result {
            Ok(_) => self.log.push("翻译测试：成功".to_owned()),
            Err(failure) => self
                .log
                .push(format!("翻译测试失败：{}", failure_log_name(failure))),
        }
        self.test_result = Some(result);
        self.changed = true;
    }

    /// Key 变了或用户要求重试：旧请求不再改状态，清掉暂停，失败的消息重新排队，然后马上检查一次。
    pub(super) fn restart(&mut self, now: f64) {
        self.abandon_in_flight(false);
        self.queue.reset(now);
        self.pump(now);
        self.changed = true;
    }
}

/// 这个预设要不要读 Key：要 Key 的预设与自定义接口（可选）读，其余不读。
pub(super) fn uses_key(provider: TranslationProviderId) -> bool {
    provider == TranslationProviderId::Custom || provider.preset().requires_key
}

/// 日志里写的错误码：长度超限记 -1。
pub(super) fn secret_error_code(error: SecretError) -> i32 {
    match error {
        SecretError::TooLong => -1,
        SecretError::System(code) => code,
    }
}

/// 建写文件的后台线程：按顺序写每个快照；排着好几个时只写最新的一个（旧的没有意义）。
pub(super) fn spawn_writer(store: TranslationCacheStore) -> Option<Writer> {
    let (sender, receiver) = mpsc::channel::<Vec<CacheEntry>>();
    let handle = thread::Builder::new()
        .name("eveo-translation-cache-save".into())
        .spawn(move || {
            while let Ok(mut entries) = receiver.recv() {
                // 跳过已经过时的快照，只写排在最后的。
                while let Ok(newer) = receiver.try_recv() {
                    entries = newer;
                }
                let _ = store.save(entries);
            }
        })
        .ok()?;
    Some(Writer {
        snapshots: sender,
        handle,
    })
}
