// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译控制器的用例，对应 macOS 的 TranslationControllerTests：排队与发送、缺 Key 时暂停与保存 Key、补读只排最近的、
// 缓存命中不发请求、旧请求的结果、关掉功能丢掉结果、服务出错时等待、缓存文件的读入合并与清空、停止时存盘、
// 「测试」、浮窗的状态行，以及界面文字的写法。
// 假的传输层把请求里的每条消息译成「译:原文」（lang 为 ru）；可以让它暂停住，模拟在途的请求。
// 时刻用固定的墙上时钟；答复从后台线程回来，用 settle 反复 tick 直到条件成立（至多 3 秒）。

use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use eveo_core::chat_log::coverage::FollowedChatChannel;
use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus, ChatMessage};
use eveo_core::model::{
    AppLanguage, ChannelRef, GeneralSettings, Profile, TranslationEndpointSettings, TranslationProviderId,
    TranslationTarget,
};
use eveo_core::overlay::OverlayStatusLevel;
use eveo_core::translation::cache::CacheEntry;
use eveo_core::translation::presenter::TranslationLineFormatting;
use eveo_core::translation::rules::cache_key;
use eveo_core::translation::{
    EndpointIssue, Failure, HttpRequest, HttpResponse, Phase, TranslationStatus, TransportError,
};
use serde_json::Value;

use super::store::TranslationCacheStore;
use super::text::{TranslationFormatter, channel_display_name, failure_log_name, status_text};
use super::{SecretError, SecretStore, TranslationController, TranslationServices};
use crate::chat::ChatFeedContext;

/// 活动角色（虚构）。
const ACTIVE: &str = "Kael Doran";
/// 另一个在线角色（虚构）。
const OTHER: &str = "Mira Sol";
/// 现在（墙上时钟）。
const NOW: f64 = 1_800_000_000.0;
/// 翻译频道的名字。
const CHANNEL: &str = "Rookie Help";

// MARK: 假的服务

/// 假的凭据管理器：内存里的表，可以让读取失败。
#[derive(Clone, Default)]
struct FakeSecrets {
    /// 账户名 → Key。
    values: Arc<Mutex<BTreeMap<String, String>>>,
    /// 为真时读取返回系统错误。
    fail_reads: Arc<Mutex<bool>>,
}

impl SecretStore for FakeSecrets {
    fn read(&self, account: &str) -> Result<Option<String>, SecretError> {
        if *self.fail_reads.lock().unwrap() {
            return Err(SecretError::System(5));
        }
        Ok(self.values.lock().unwrap().get(account).cloned())
    }

    fn write(&self, account: &str, secret: &str) -> Result<(), SecretError> {
        self.values
            .lock()
            .unwrap()
            .insert(account.to_owned(), secret.to_owned());
        Ok(())
    }

    fn delete(&self, account: &str) -> Result<(), SecretError> {
        self.values.lock().unwrap().remove(account);
        Ok(())
    }
}

/// 假的模型服务的状态。
#[derive(Default)]
struct ServerState {
    /// 收到的请求。
    requests: Vec<HttpRequest>,
    /// 接下来几次请求的固定状态码（非 200 时答复正文是一段错误说明）；用完后回到正常翻译。
    statuses: VecDeque<u16>,
    /// 为真时请求停在服务里，直到改回假。
    hold: bool,
}

/// 假的模型服务：把消息译成「译:原文」。
#[derive(Clone, Default)]
struct FakeServer {
    /// 状态与唤醒等待中的请求用的条件变量。
    state: Arc<(Mutex<ServerState>, Condvar)>,
}

impl FakeServer {
    /// 处理一个请求（在后台线程里）。
    fn handle(&self, request: &HttpRequest) -> Result<HttpResponse, TransportError> {
        let (lock, condvar) = &*self.state;
        let mut state = lock.lock().unwrap();
        state.requests.push(request.clone());
        // 暂停住时等测试放行；至多等 5 秒，免得用例出错时线程永远挂着。
        let deadline = Instant::now() + Duration::from_secs(5);
        while state.hold && Instant::now() < deadline {
            state = condvar.wait_timeout(state, Duration::from_millis(20)).unwrap().0;
        }
        if let Some(status) = state.statuses.pop_front() {
            return Ok(HttpResponse {
                status,
                headers: BTreeMap::new(),
                body: br#"{"error":{"message":"secret detail"}}"#.to_vec(),
            });
        }
        Ok(HttpResponse {
            status: 200,
            headers: BTreeMap::new(),
            body: echo_answer(&request.body),
        })
    }

    /// 让之后的请求停住或放行。
    fn set_hold(&self, hold: bool) {
        let (lock, condvar) = &*self.state;
        lock.lock().unwrap().hold = hold;
        condvar.notify_all();
    }

    /// 接下来的一次请求答这个状态码。
    fn push_status(&self, status: u16) {
        self.state.0.lock().unwrap().statuses.push_back(status);
    }

    /// 收到的请求数。
    fn request_count(&self) -> usize {
        self.state.0.lock().unwrap().requests.len()
    }

    /// 收到的请求。
    fn requests(&self) -> Vec<HttpRequest> {
        self.state.0.lock().unwrap().requests.clone()
    }
}

/// OpenAI 兼容接口的答复：取用户消息里「消息：」之后的 JSON 数组，每条译成「译:原文」。
fn echo_answer(body: &[u8]) -> Vec<u8> {
    let request: Value = serde_json::from_slice(body).expect("请求体是 JSON");
    let user = request["messages"][1]["content"].as_str().expect("有用户消息");
    let list = user.split("消息：\n").nth(1).expect("有消息列表");
    let messages: Vec<Value> = serde_json::from_str(list).expect("消息列表是 JSON");
    let answers: Vec<Value> = messages
        .iter()
        .map(|m| {
            serde_json::json!({
                "id": m["id"],
                "text": format!("译:{}", m["text"].as_str().unwrap_or_default()),
                "lang": "ru",
            })
        })
        .collect();
    let content = serde_json::to_string(&answers).unwrap();
    serde_json::to_vec(&serde_json::json!({
        "choices": [{"message": {"content": content}, "finish_reason": "stop"}]
    }))
    .unwrap()
}

/// 用例的环境：控制器、假服务与缓存文件的位置。
struct Harness {
    /// 控制器。
    controller: TranslationController,
    /// 假的模型服务。
    server: FakeServer,
    /// 假的凭据管理器。
    secrets: FakeSecrets,
    /// 缓存文件。
    cache_path: PathBuf,
}

/// 每个用例自己的临时目录。
fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("eveo-translation-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// 建环境；entries 是事先写进缓存文件的条目（None 表示没有文件）。
fn harness(name: &str, entries: Option<Vec<CacheEntry>>) -> Harness {
    let cache_path = temp_dir(name).join("translation-cache.json");
    let store = TranslationCacheStore::new(&cache_path);
    if let Some(entries) = entries {
        store.save(entries).unwrap();
    }
    let server = FakeServer::default();
    let secrets = FakeSecrets::default();
    let handler = server.clone();
    let controller = TranslationController::new(TranslationServices {
        secrets: Box::new(secrets.clone()),
        transport: Arc::new(move |request: &HttpRequest| handler.handle(request)),
        cache_store: store,
    });
    // 控制器建好后就在后台读缓存文件；服务的克隆留在环境里，用例借它们检查请求与凭据。
    let mut harness = Harness {
        controller,
        server,
        secrets,
        cache_path,
    };
    // 先等缓存文件读完，用例从确定的状态开始。
    harness.settle(NOW, |c| {
        c.cache_count() > 0 || matches!(c.cache_load, super::CacheLoad::Loaded)
    });
    harness
}

impl Harness {
    /// 反复 tick 直到条件成立；3 秒内不成立时用例失败。
    fn settle(&mut self, now: f64, done: impl Fn(&TranslationController) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            self.controller.tick(now);
            if done(&self.controller) {
                return;
            }
            assert!(Instant::now() < deadline, "3 秒内没有等到预期的状态");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// 活动角色各条的阶段。
    fn phases(&self) -> Vec<Phase> {
        self.controller
            .queue
            .items(ACTIVE)
            .into_iter()
            .map(|item| item.phase)
            .collect()
    }
}

/// 翻译开着、有一个频道、目标语言是中文、接口是本机 Ollama（不要 Key）的上下文。
fn context() -> ChatFeedContext {
    let mut profile = Profile::make_new("p", "Default");
    profile.translation.enabled = true;
    profile.translation.channels = vec![ChannelRef::new(CHANNEL, None)];
    profile.translation.target_language = TranslationTarget::Zh;
    let mut general = GeneralSettings::default();
    general.translation_endpoint.provider = TranslationProviderId::Ollama;
    ChatFeedContext {
        profile,
        general,
        static_data: None,
        active_character: Some(ACTIVE.to_owned()),
        chat_log_status: ChatLogStatus::Watching {
            directory: "C:\\Chatlogs".to_owned(),
            followed_files: 1,
        },
        followed_channels: None,
        language: AppLanguage::En,
    }
}

/// 收听者 listener 在 time 收到的一条消息。
fn message(listener: &str, text: &str, time: f64, is_backfill: bool) -> ChatLogEvent {
    ChatLogEvent::Message(ChatMessage {
        listener: listener.to_owned(),
        channel_id: "player_1".to_owned(),
        channel_name: CHANNEL.to_owned(),
        time,
        speaker: "Pilot".to_owned(),
        text: text.to_owned(),
        is_backfill,
    })
}

/// 「译:原文」的 Done。
fn done(original: &str) -> Phase {
    Phase::Done {
        text: format!("译:{original}"),
        source_language: Some("ru".to_owned()),
    }
}

// MARK: 排队与发送

/// 活动角色的新消息排队，满 1 秒后发出，译文填回；浮窗显示译文，缓存满 30 秒存盘。
#[test]
fn sends_pending_messages_after_debounce() {
    let mut h = harness("send", None);
    // 打开功能后，EVE 系统发的频道提示也不进入缓冲。
    h.controller.update(context(), NOW);
    // 打开功能后队列空闲，还没有任何请求。
    assert_eq!(h.controller.status(), &TranslationStatus::Idle);
    assert!(
        h.controller
            .ingest(vec![message(ACTIVE, "where is the station", NOW, false)], NOW)
    );
    // 最近的消息重新排队，用日文再翻一次。
    assert_eq!(h.phases(), vec![Phase::Pending]);
    // 不足 1 秒不发。
    h.controller.tick(NOW + 0.5);
    assert_eq!(h.server.request_count(), 0);
    h.settle(NOW + 1.5, |c| {
        c.queue.items(ACTIVE)[0].phase != Phase::Pending && c.queue.items(ACTIVE)[0].phase != Phase::InFlight
    });
    // 一条消息一个请求，答复回来后队列回到空闲。
    assert_eq!(h.phases(), vec![done("where is the station")]);
    // 第一个角色那一份翻译完，缓存里有了这句话。
    assert_eq!(h.server.request_count(), 1);
    assert_eq!(h.controller.status(), &TranslationStatus::Idle);
    // 浮窗：标题带角色名，一行里有译文。
    let content = h.controller.content(NOW + 2.0);
    assert_eq!(content.context_key, format!("translation:{ACTIVE}"));
    assert!(content.title.contains(ACTIVE));
    assert!(content.lines[0].copy_text.contains("译:where is the station"));
    // 缓存有 1 条，第一次存盘不用等 30 秒（tick 里已交给写入线程）。
    // 文件里的一条已读入内存。
    assert_eq!(h.controller.cache_count(), 1);
    // stop 等写入线程写完再同步存一次，之后文件里一定有这条译文。
    h.controller.stop();
    let saved = TranslationCacheStore::new(&h.cache_path).load();
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].target, "zh");
    // 日志里只有条数与耗时，没有聊天内容。
    let log = h.controller.take_log_lines().join("\n");
    assert!(log.contains("发送一批 1 条"));
    assert!(!log.contains("station"));
}

/// 非活动角色的消息、补读的旧消息是 Off；补读到活动角色的消息后排最近的（600 秒内至多 20 条）。
#[test]
fn backfill_queues_only_recent_active_messages() {
    let mut h = harness("backfill", None);
    h.controller.update(context(), NOW);
    let mut events = vec![message(OTHER, "hello there", NOW, false)];
    // 一条 20 分钟前的、两条最近的。
    events.push(message(ACTIVE, "old news", NOW - 1_200.0, true));
    events.push(message(ACTIVE, "fresh one", NOW - 60.0, true));
    events.push(message(ACTIVE, "fresh two", NOW - 30.0, true));
    // 先让服务停住，进入时的阶段在请求发出之前就能看清。
    h.server.set_hold(true);
    h.controller.ingest(events, NOW);
    // 非活动角色的消息不花钱；20 分钟前的补读消息超出 600 秒，也不排队。
    assert_eq!(h.controller.queue.items(OTHER)[0].phase, Phase::Off);
    assert_eq!(h.phases(), vec![Phase::Off, Phase::Pending, Phase::Pending]);
    // 放行后两条最近的补读消息作为一批发出。
    h.server.set_hold(false);
    h.settle(NOW + 2.0, |c| {
        !c.queue.has_batch_in_flight() && c.queue.items(ACTIVE)[1].phase != Phase::Pending
    });
    assert_eq!(h.phases(), vec![Phase::Off, done("fresh one"), done("fresh two")]);
}

/// 缓存里已有的句子不发请求：另一个角色收到同一句话、切换过去后直接是 Done。
#[test]
fn cached_sentences_are_not_sent_again() {
    let mut h = harness("cached", None);
    h.controller.update(context(), NOW);
    h.controller
        .ingest(vec![message(ACTIVE, "need help with fitting", NOW, false)], NOW);
    h.settle(NOW + 1.5, |c| {
        !c.queue.has_batch_in_flight() && c.cache_count() == 1
    });
    assert_eq!(h.server.request_count(), 1);
    // 同一句话写进了另一个角色的日志（多开时常见）：进入时就按缓存是 Done。
    h.controller.ingest(
        vec![message(OTHER, "need help with fitting", NOW + 2.0, false)],
        NOW + 2.0,
    );
    assert_eq!(
        h.controller.queue.items(OTHER)[0].phase,
        done("need help with fitting")
    );
    // 切换到另一个角色：它的副本已是 Done，不会再排进队列。
    let mut switched = context();
    switched.active_character = Some(OTHER.to_owned());
    h.controller.update(switched, NOW + 3.0);
    // 消息已有译文，不会为它再发一次。
    h.controller.tick(NOW + 5.0);
    assert_eq!(h.server.request_count(), 1);
}

/// 系统消息不进入缓冲；功能关着时什么也不收。
#[test]
fn ignores_system_messages_and_disabled_feature() {
    let mut h = harness("system", None);
    let mut off = context();
    off.profile.translation.enabled = false;
    // 功能关着：ingest 什么也不收，状态是 Off。
    h.controller.update(off, NOW);
    assert!(
        !h.controller
            .ingest(vec![message(ACTIVE, "anything", NOW, false)], NOW)
    );
    assert_eq!(h.controller.status(), &TranslationStatus::Off);
    h.controller.update(context(), NOW);
    let mut system = message(ACTIVE, "Channel changed", NOW, false);
    if let ChatLogEvent::Message(m) = &mut system {
        m.speaker = "EVE System".to_owned();
    }
    h.controller.ingest(vec![system], NOW);
    assert!(h.phases().is_empty());
}

// MARK: Key

/// 要 Key 的预设没有 Key 时暂停；保存 Key 后写进凭据管理器、请求带上它，暂停解除。
#[test]
fn missing_key_blocks_until_saved() {
    let mut h = harness("key", None);
    // 日志目录不存在时，状态行先说这个，别的问题都排在后面。
    let mut ctx = context();
    ctx.general.translation_endpoint.provider = TranslationProviderId::DeepSeek;
    // DeepSeek 要 Key，假凭据管理器里还没有。
    h.controller.update(ctx, NOW);
    h.controller
        .ingest(vec![message(ACTIVE, "is the gate camped", NOW, false)], NOW);
    assert_eq!(
        h.controller.status(),
        &TranslationStatus::Blocked(Failure::MissingKey)
    );
    assert_eq!(
        h.controller.is_key_stored(TranslationProviderId::DeepSeek),
        Some(false)
    );
    // 空白的输入什么也不做。
    h.controller
        .save_key("   ", TranslationProviderId::DeepSeek, NOW)
        .unwrap();
    assert_eq!(
        h.controller.status(),
        &TranslationStatus::Blocked(Failure::MissingKey)
    );
    h.controller
        .save_key(" sk-test-123 ", TranslationProviderId::DeepSeek, NOW + 1.0)
        .unwrap();
    assert_eq!(
        h.secrets
            .values
            .lock()
            .unwrap()
            .get("apikey.deepseek")
            .map(String::as_str),
        Some("sk-test-123")
    );
    assert_eq!(
        h.controller.is_key_stored(TranslationProviderId::DeepSeek),
        Some(true)
    );
    h.settle(NOW + 3.0, |c| c.cache_count() == 1);
    let request = &h.server.requests()[0];
    assert_eq!(
        request.headers.get("Authorization").map(String::as_str),
        Some("Bearer sk-test-123")
    );
    // 日志里没有 Key。
    assert!(!h.controller.take_log_lines().join("\n").contains("sk-test"));
    // 删除后又是缺 Key。
    h.controller
        .delete_key(TranslationProviderId::DeepSeek, NOW + 4.0)
        .unwrap();
    assert!(h.secrets.values.lock().unwrap().is_empty());
    h.controller
        .ingest(vec![message(ACTIVE, "another line", NOW + 4.0, false)], NOW + 4.0);
    assert_eq!(
        h.controller.status(),
        &TranslationStatus::Blocked(Failure::MissingKey)
    );
}

/// 读凭据管理器失败时暂停的原因是 KeychainUnavailable；「立即重试」再读一次。
#[test]
fn unreadable_key_blocks_and_retry_reads_again() {
    let mut h = harness("keyfail", None);
    *h.secrets.fail_reads.lock().unwrap() = true;
    h.secrets
        .values
        .lock()
        .unwrap()
        .insert("apikey.deepseek".to_owned(), "sk-x".to_owned());
    // 没有选翻译频道时只给一句提示（info）。
    let mut ctx = context();
    ctx.general.translation_endpoint.provider = TranslationProviderId::DeepSeek;
    // 凭据管理器里有 Key，但读取失败（例如凭据服务没有运行）。
    h.controller.update(ctx, NOW);
    h.controller
        .ingest(vec![message(ACTIVE, "anyone in system", NOW, false)], NOW);
    assert_eq!(
        h.controller.status(),
        &TranslationStatus::Blocked(Failure::KeychainUnavailable)
    );
    *h.secrets.fail_reads.lock().unwrap() = false;
    // 「立即重试」时内存里没有 Key，再读一次；这次读得到，排队的消息发出。
    h.controller.retry(NOW + 1.0);
    h.settle(NOW + 3.0, |c| c.cache_count() == 1);
    assert_eq!(h.controller.status(), &TranslationStatus::Idle);
}

// MARK: 在途的请求

/// 接口设置变了时在途的请求成为旧请求：它的译文仍填给在等的消息，但不再多发一次。
#[test]
fn stale_results_still_fill_messages() {
    let mut h = harness("stale", None);
    h.controller.update(context(), NOW);
    h.server.set_hold(true);
    h.controller
        .ingest(vec![message(ACTIVE, "warp to me", NOW, false)], NOW);
    // 请求已发出、停在服务里；这时改了模型名。
    h.settle(NOW + 1.5, |c| c.queue.has_batch_in_flight());
    let mut changed = context();
    changed.general.translation_endpoint.model = "other-model".to_owned();
    h.controller.update(changed, NOW + 1.6);
    // 消息回到排队；旧请求放行后，在下一次发送（满 1 秒）之前就填上了译文。
    assert_eq!(h.phases(), vec![Phase::Pending]);
    // 旧请求放行：译文填给仍在排队的消息，但不改队列的状态。
    h.server.set_hold(false);
    h.settle(NOW + 1.7, |c| c.queue.items(ACTIVE)[0].phase != Phase::Pending);
    assert_eq!(h.phases(), vec![done("warp to me")]);
    h.controller.tick(NOW + 5.0);
    assert_eq!(h.server.request_count(), 1);
    assert!(h.controller.take_log_lines().iter().any(|l| l.contains("旧请求")));
}

/// 关掉功能时在途请求的结果丢掉，不进缓存。
#[test]
fn disabling_drops_in_flight_results() {
    let mut h = harness("disable", None);
    h.controller.update(context(), NOW);
    h.server.set_hold(true);
    h.controller
        .ingest(vec![message(ACTIVE, "align out", NOW, false)], NOW);
    // 请求停在服务里时关掉功能。
    h.settle(NOW + 1.5, |c| c.queue.has_batch_in_flight());
    let mut off = context();
    off.profile.translation.enabled = false;
    h.controller.update(off, NOW + 2.0);
    assert_eq!(h.controller.status(), &TranslationStatus::Off);
    // 放行后答复照样回来，但控制器已丢掉这个请求的记录。
    h.server.set_hold(false);
    // 给后台线程时间答复；结果到了也没人要。
    std::thread::sleep(Duration::from_millis(50));
    for _ in 0..10 {
        h.controller.tick(NOW + 3.0);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(h.controller.cache_count(), 0);
}

/// 服务出错（500）时等 30 秒重试，日志里只有状态码；到时再发，成功后回到空闲。
#[test]
fn server_errors_wait_and_retry() {
    let mut h = harness("server", None);
    h.controller.update(context(), NOW);
    // 第一次请求答 500，之后恢复正常。
    h.server.push_status(500);
    h.controller
        .ingest(vec![message(ACTIVE, "fleet forming up", NOW, false)], NOW);
    h.settle(NOW + 1.5, |c| {
        matches!(c.status(), TranslationStatus::Waiting { .. })
    });
    let TranslationStatus::Waiting { until, reason } = h.controller.status().clone() else {
        unreachable!()
    };
    // 第一次服务出错等 30 秒，从请求发出的时刻（防抖后的 NOW + 1.5）算起。
    assert_eq!(reason, Failure::Server(500));
    assert!((until - (NOW + 31.5)).abs() < 1e-6);
    // 状态行是 warning，写着还要等几秒。
    let line = h.controller.content(NOW + 11.5).status.expect("有状态行");
    assert_eq!(line.level, OverlayStatusLevel::Warning);
    assert!(line.text.contains("20"));
    // 倒计时每秒变一次：剩 20 秒整时下一次是剩 19 秒；剩 19.7 秒（显示 20）时也是剩 19 秒。
    let next = h.controller.next_refresh(NOW + 11.5).expect("等待中要按时刷新");
    assert!((next - (NOW + 12.5)).abs() < 1e-6);
    let next = h.controller.next_refresh(NOW + 11.8).expect("等待中要按时刷新");
    assert!((next - (NOW + 12.5)).abs() < 1e-6);
    // 到时自动重试，这次成功。
    h.settle(NOW + 32.0, |c| c.cache_count() == 1);
    assert_eq!(h.controller.status(), &TranslationStatus::Idle);
    // 不再等待时浮窗内容不随时间变。
    assert_eq!(h.controller.next_refresh(NOW + 32.0), None);
    let log = h.controller.take_log_lines().join("\n");
    assert!(log.contains("server(500)"));
    assert!(!log.contains("secret detail"));
}

/// 400 的说明显示在状态行（暂停，error），但不写进日志。
#[test]
fn rejected_requests_block_with_message() {
    let mut h = harness("rejected", None);
    h.controller.update(context(), NOW);
    // 400 属于「请求不被接受」，是致命失败：暂停到用户改设置或点重试。
    h.server.push_status(400);
    h.controller.ingest(vec![message(ACTIVE, "o7", NOW, false)], NOW);
    h.settle(NOW + 1.5, |c| matches!(c.status(), TranslationStatus::Blocked(_)));
    let line = h.controller.content(NOW + 2.0).status.expect("有状态行");
    assert_eq!(line.level, OverlayStatusLevel::Error);
    assert!(line.text.contains("secret detail"));
    assert!(!h.controller.take_log_lines().join("\n").contains("secret detail"));
}

// MARK: 目标语言与缓存文件

/// 目标语言变了：缓冲按新语言重新判断，旧译文不再显示，最近的消息重新排队。
#[test]
fn target_change_reclassifies() {
    let mut h = harness("target", None);
    h.controller.update(context(), NOW);
    h.controller
        .ingest(vec![message(ACTIVE, "bonjour tout le monde", NOW, false)], NOW);
    h.settle(NOW + 1.5, |c| c.cache_count() == 1);
    // 换成日文：缓冲按新语言重新判断，中文的译文不再适用。
    let mut japanese = context();
    japanese.profile.translation.target_language = TranslationTarget::Ja;
    h.controller.update(japanese, NOW + 2.0);
    assert_eq!(h.phases(), vec![Phase::Pending]);
    h.settle(NOW + 3.5, |c| c.cache_count() == 2);
    assert_eq!(h.server.request_count(), 2);
}

/// 缓存文件里的条目读入后直接命中；清空缓存后文件变空。
#[test]
fn loads_cache_file_and_clears_it() {
    let original = "is local clear";
    let entry = CacheEntry {
        target: "zh".to_owned(),
        key: cache_key(original),
        text: "本地安全吗".to_owned(),
        source_language: Some("en".to_owned()),
    };
    let mut h = harness("load", Some(vec![entry]));
    assert_eq!(h.controller.cache_count(), 1);
    h.controller.update(context(), NOW);
    h.controller
        .ingest(vec![message(ACTIVE, original, NOW, false)], NOW);
    assert_eq!(
        h.phases(),
        vec![Phase::Done {
            text: "本地安全吗".to_owned(),
            source_language: Some("en".to_owned()),
        }]
    );
    // 命中缓存的消息不发请求。
    h.controller.tick(NOW + 2.0);
    assert_eq!(h.server.request_count(), 0);
    // 清空缓存后立刻把空的快照交给写入线程。
    h.controller.clear_cache(NOW + 3.0);
    assert_eq!(h.controller.cache_count(), 0);
    h.controller.stop();
    assert!(TranslationCacheStore::new(&h.cache_path).load().is_empty());
}

/// 坏掉的缓存文件当作空缓存。
#[test]
fn corrupt_cache_file_starts_empty() {
    let dir = temp_dir("corrupt");
    let path = dir.join("translation-cache.json");
    std::fs::write(&path, b"not json").unwrap();
    assert!(TranslationCacheStore::new(&path).load().is_empty());
    assert!(
        TranslationCacheStore::new(dir.join("missing.json"))
            .load()
            .is_empty()
    );
}

// MARK: 测试按钮

/// 「测试」：成功时给出译文；地址不对时立刻失败；要 Key 而没有时是 MissingKey。都不改队列的状态。
#[test]
fn test_button_reports_result() {
    let mut h = harness("test", None);
    h.controller.update(context(), NOW);
    let settings = context().general.translation_endpoint;
    // 本机 Ollama 不要 Key，测试请求直接发出。
    h.controller.start_test(&settings, AppLanguage::Zh, NOW);
    assert!(h.controller.is_testing());
    h.settle(NOW, |c| !c.is_testing());
    let text = h.controller.take_test_result().expect("有结果").expect("成功");
    assert!(text.starts_with("译:"));
    assert_eq!(h.controller.status(), &TranslationStatus::Idle);

    // ftp 地址在解析接口时就被拒绝，不发请求。
    let bad = TranslationEndpointSettings {
        provider: TranslationProviderId::Custom,
        base_url: "ftp://example.invalid".to_owned(),
        model: "m".to_owned(),
    };
    h.controller.start_test(&bad, AppLanguage::Zh, NOW);
    assert_eq!(
        h.controller.take_test_result(),
        Some(Err(Failure::NotConfigured(EndpointIssue::InvalidUrl)))
    );

    // DeepSeek 要 Key 而凭据管理器里没有：也不发请求。
    let deepseek = TranslationEndpointSettings {
        provider: TranslationProviderId::DeepSeek,
        ..TranslationEndpointSettings::default()
    };
    h.controller.start_test(&deepseek, AppLanguage::Zh, NOW);
    assert_eq!(h.controller.take_test_result(), Some(Err(Failure::MissingKey)));
    assert_eq!(h.server.request_count(), 1);
}

// MARK: 状态行

/// 状态行：日志目录不存在（error）；没有翻译频道（info）；活动角色在所选频道都没有日志文件（warning）。
#[test]
fn status_line_explains_problems() {
    let mut h = harness("status", None);
    let mut ctx = context();
    ctx.chat_log_status = ChatLogStatus::DirectoryNotFound("C:\\Missing".to_owned());
    h.controller.update(ctx, NOW);
    let line = h.controller.content(NOW).status.expect("有状态行");
    assert_eq!(line.level, OverlayStatusLevel::Error);
    assert!(line.text.contains("C:\\Missing"));

    let mut ctx = context();
    ctx.profile.translation.channels.clear();
    h.controller.update(ctx, NOW);
    assert_eq!(
        h.controller.content(NOW).status.map(|s| s.level),
        Some(OverlayStatusLevel::Info)
    );

    // 跟踪服务只找到另一个角色的日志：活动角色在所选频道一个文件也没有。
    let mut ctx = context();
    ctx.profile.translation.channels = vec![ChannelRef::built_ins()[0].clone()];
    ctx.followed_channels = Some(vec![FollowedChatChannel {
        listener: OTHER.to_owned(),
        channel_id: "local".to_owned(),
        channel_name: Some("Local".to_owned()),
    }]);
    h.controller.update(ctx.clone(), NOW);
    let line = h.controller.content(NOW).status.expect("有状态行");
    assert_eq!(line.level, OverlayStatusLevel::Warning);
    assert!(line.text.contains("Local"));
    // 活动角色也有了本地频道的日志后不再提示。
    ctx.followed_channels.as_mut().unwrap().push(FollowedChatChannel {
        listener: ACTIVE.to_owned(),
        channel_id: "local".to_owned(),
        channel_name: Some("Local".to_owned()),
    });
    h.controller.update(ctx, NOW);
    assert_eq!(h.controller.content(NOW).status, None);
}

/// 没有活动角色时标题是页名，没有行。
#[test]
fn content_without_active_character() {
    let mut h = harness("noactive", None);
    let mut ctx = context();
    ctx.active_character = None;
    h.controller.update(ctx, NOW);
    let content = h.controller.content(NOW);
    assert_eq!(content.context_key, "translation:");
    assert!(content.lines.is_empty());
    assert_eq!(
        content.title,
        eveo_l10n::settings(AppLanguage::En).page_translation()
    );
}

// MARK: 界面文字

/// 时间是 UTC 的 HH:mm；非有限值显示占位。
#[test]
fn formatter_writes_utc_time() {
    let formatter = TranslationFormatter {
        language: AppLanguage::En,
    };
    // 1_800_000_000 是 UTC 2027-01-15 08:00:00。
    assert_eq!(formatter.time(NOW), "08:00");
    assert_eq!(formatter.time(NOW + 59.9), "08:00");
    assert_eq!(formatter.time(-60.0), "23:59");
    assert_eq!(formatter.time(f64::NAN), "--:--");
    assert!(!formatter.pending().is_empty());
    assert!(!formatter.failed().is_empty());
}

/// 状态文字：等待的秒数向上取整；失败的日志名只有种类与状态码。
#[test]
fn status_and_log_names() {
    let waiting = TranslationStatus::Waiting {
        until: NOW + 9.2,
        reason: Failure::RateLimited(None),
    };
    assert!(status_text(AppLanguage::En, &waiting, NOW).contains("10"));
    let rejected = Failure::Rejected {
        status: 422,
        message: "private".to_owned(),
    };
    assert_eq!(failure_log_name(&rejected), "rejected(422)");
    assert_eq!(
        failure_log_name(&Failure::RateLimited(Some(12.7))),
        "rateLimited(12s)"
    );
    assert_eq!(
        channel_display_name(&ChannelRef::built_ins()[0], AppLanguage::Zh),
        eveo_l10n::overlay(AppLanguage::Zh).built_in_local()
    );
    assert_eq!(
        channel_display_name(&ChannelRef::new("  ", Some("player_9")), AppLanguage::En),
        "player_9"
    );
}
