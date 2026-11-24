// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译功能的控制器，对应 macOS 的 TranslationController.swift（设计文档 7.6～7.8 节、7.10 节）：
// 持有翻译队列、译文缓存与内存里的 Key，把请求交给后台线程，产出翻译浮窗的内容。
// 规则在 eveo-core::translation（判断、分批、提示词、请求与答复、队列、缓存），这里只把它们与线程、文件、时钟接起来。
//
// - 消息进入时的阶段：系统消息不进入；不用模型的是 Skipped；缓存命中按 rules::result_phase 是 Done
//   或 Skipped(SameLanguage)；活动角色的非补读消息是 Pending；其余是 Off。补读到活动角色的消息后调一次 activate，
//   至多 20 条交给模型。
// - 目标语言变了、或星图数据第一次读到时，把缓冲里的消息按新条件重新判断；旧消息不直接排进队列，
//   只按 activate 的规则排最近的 20 条，不为整个缓冲重新付费。
// - 凭据管理器只在 3 个时机读（7.7 节）：开关打开或预设变了；用户点「保存」（写入后留在内存）；
//   用户点「测试」或「立即重试」且内存里没有值。之后只用内存里的值。
// - 同一时刻至多一批在途（队列负责）。设置、Key 或目标语言变了时，在途的请求变成「旧请求」：它的结果仍按发出时的
//   目标语言存进缓存，目标语言没变时也填给仍在等的消息，但不改队列的状态。
// - 每个请求在一个短命的后台线程里发（WinHTTP 的同步调用，至多等 60 秒）；结果经通道回到主线程，由 tick 处理。
//   关掉功能或停止时不等线程，只把它的结果丢掉。
// - 译文缓存在建控制器时于后台读取；读完之前不存盘，读完后与内存里的条目合并。有改动时满 30 秒交给写入线程存一次，
//   stop 时等写入线程写完，再同步存最后一次。
// - 活动角色在所选的每个翻译频道都没有被跟踪的日志文件时，状态行提示 EVE 没有写日志（coverage::lacks_all_logs）。
// - 日志只写条数、状态码与失败的种类，不写 Key、请求头、接口地址、模型名、聊天内容、角色名与服务给的说明。
//   本 crate 不直接写日志：日志行攒在控制器里，由应用层取走（take_log_lines）。
// 与 macOS 的差别：macOS 用 Swift 并发的任务与定时器；这里没有回调，调用方在应用的定时器里调用 tick，
// 返回值告诉它内容是否变了。Windows 凭据管理器读写不会弹窗，所以没有「要用户确认」的情形。
// 时刻用墙上时钟的秒数，与日志里的消息时间同一个时钟，由调用方传入。
// 文件：本文件是类型、上下文、消息的阶段与状态行；send 是发送与答复；settings 是 Key、缓存文件与设置接口；
// store 是缓存文件的读写；text 是界面文字。

//! 翻译功能的控制器：缓冲、发送、译文缓存与 Key。

mod send;
mod settings;
pub mod store;
pub mod text;

#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::JoinHandle;
use std::time::Instant;

use eveo_core::chat_log::coverage::{lacks_all_logs, match_name};
use eveo_core::chat_log::parser::SYSTEM_SPEAKERS;
use eveo_core::chat_log::{ChatLine, ChatLogEvent, ChatLogStatus, ChatMessage};
use eveo_core::intel::IntelReport;
use eveo_core::intel::parser::parse;
use eveo_core::model::{
    AppLanguage, TranslationEndpointSettings, TranslationProviderId, TranslationSettings,
};
use eveo_core::overlay::{OverlayContent, OverlayStatus, OverlayStatusLevel};
use eveo_core::translation::cache::{CacheEntry, TranslationCache};
use eveo_core::translation::queue::TranslationQueue;
use eveo_core::translation::{
    ApiKind, Failure, HttpRequest, HttpResponse, Phase, SkipReason, TranslationItem, TranslationStatus,
    TransportError, presenter, rules,
};

use self::store::TranslationCacheStore;
use self::text::{TranslationFormatter, channel_display_name, status_text};
use crate::chat::ChatFeedContext;

/// 两次存盘至少隔几秒：译文一批批到达，每批都写文件没有必要。
pub const CACHE_SAVE_INTERVAL: f64 = 30.0;
/// 至多攒几行日志：应用层没来取时丢掉最早的，内存不会无限增长。
pub const MAX_LOG_LINES: usize = 200;

/// 读写 API Key 的失败。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecretError {
    /// Key 超过凭据管理器的长度上限。
    TooLong,
    /// 系统调用失败，关联值是系统错误码（不含 Key）。
    System(i32),
}

/// 存 API Key 的地方（Windows 上是凭据管理器）。account 是 providers::credential_account 给的账户名。
pub trait SecretStore: Send {
    /// 读 Key；没有时是 Ok(None)。
    fn read(&self, account: &str) -> Result<Option<String>, SecretError>;
    /// 保存 Key，覆盖旧值。
    fn write(&self, account: &str, secret: &str) -> Result<(), SecretError>;
    /// 删除 Key；本来就没有时也算成功。
    fn delete(&self, account: &str) -> Result<(), SecretError>;
}

/// 发一次翻译请求并等答复。在后台线程里调用，可以阻塞（WinHTTP 的同步调用）。
pub type Transport = Arc<dyn Fn(&HttpRequest) -> Result<HttpResponse, TransportError> + Send + Sync>;

/// 控制器用到的外部服务。
pub struct TranslationServices {
    /// API Key 的存放处。
    pub secrets: Box<dyn SecretStore>,
    /// 发请求的函数。
    pub transport: Transport,
    /// 译文缓存文件。
    pub cache_store: TranslationCacheStore,
}

/// 内存里的 Key 的状态。
#[derive(Debug, Clone, PartialEq, Eq)]
enum KeyState {
    /// 还没读过。
    Unknown,
    /// 读到的值。
    Value(String),
    /// 凭据管理器里没有。
    Missing,
    /// 读取失败。
    Unavailable,
}

/// 一个在途请求的用途。
enum Purpose {
    /// 翻译一批消息；target 是发出时的目标语言。
    Batch {
        /// 这一批条目。
        batch: Vec<TranslationItem>,
        /// 发出时的目标语言。
        target: AppLanguage,
        /// 发出时的代次；与当前代次相同才是当前请求。
        generation: u64,
    },
    /// 「翻译」页的「测试」。
    Test,
}

/// 一个已交给后台线程的请求。
struct Sent {
    /// 用途。
    purpose: Purpose,
    /// 提示词里的编号 → 条目编号，解析答复用。
    ids: BTreeMap<i64, u64>,
    /// 接口种类，解析答复用。
    kind: ApiKind,
    /// 发出的时刻，只用来在日志里写耗时。
    started: Instant,
}

/// 后台线程交回的一次答复：请求的序号与传输层的结果。
type Reply = (u64, Result<HttpResponse, TransportError>);

/// 缓存文件的读取进度。
enum CacheLoad {
    /// 后台线程在读。
    Loading(Receiver<Vec<CacheEntry>>),
    /// 已读完（或读失败后从空缓存开始）。
    Loaded,
}

/// 写缓存文件的后台线程：各次写入排成一串，后一次等前一次写完。
struct Writer {
    /// 要写的快照。
    snapshots: Sender<Vec<CacheEntry>>,
    /// 线程句柄，stop 时等它写完。
    handle: JoinHandle<()>,
}

/// 翻译功能的控制器。只在应用的主线程上使用。
pub struct TranslationController {
    /// 凭据管理器。
    secrets: Box<dyn SecretStore>,
    /// 发请求的函数。
    transport: Transport,
    /// 缓存文件。
    cache_store: TranslationCacheStore,
    /// 最近一次的上下文。
    context: Option<ChatFeedContext>,
    /// 缓冲与队列。
    queue: TranslationQueue,
    /// 译文缓存。
    cache: TranslationCache,
    /// 缓存文件的读取进度；读完之前不存盘。
    cache_load: CacheLoad,
    /// 读完之前用户清空了缓存：读到的条目丢掉。
    discard_loaded_cache: bool,
    /// 上次存盘的时刻。
    last_cache_save: f64,
    /// 写文件的后台线程；第一次存盘时建。
    writer: Option<Writer>,
    /// Key 的状态。
    key: KeyState,
    /// Key 属于哪个预设；还没读过时为 None。
    key_provider: Option<TranslationProviderId>,
    /// 请求的代次：每发一批、以及设置、Key 或目标语言变了时加 1，之前发出的请求成为旧请求。
    generation: u64,
    /// 下一个请求序号。
    next_serial: u64,
    /// 已发出、还没收到答复的请求。
    sent: HashMap<u64, Sent>,
    /// 当前在途的那一批的序号；旧请求不占这个位置。
    current_serial: Option<u64>,
    /// 后台线程交回答复的发送端（每个线程克隆一份）。
    reply_sender: Sender<Reply>,
    /// 答复的接收端，tick 里取。
    replies: Receiver<Reply>,
    /// 上一次的开关。
    last_enabled: bool,
    /// 上一次的目标语言；还没打开过时为 None。
    target: Option<AppLanguage>,
    /// 上一次的接口设置。
    last_endpoint: Option<TranslationEndpointSettings>,
    /// 上一次的活动角色。
    last_active: Option<String>,
    /// 上一次有没有星图数据。
    had_static_data: bool,
    /// 翻译的状态；功能关着时是 Off。
    status: TranslationStatus,
    /// 「测试」在等答复。
    testing: bool,
    /// 「测试」的结果，设置界面取走。
    test_result: Option<Result<String, Failure>>,
    /// 内容或状态变了、调用方还没刷新。
    changed: bool,
    /// 攒着的日志行，由应用层取走。
    log: Vec<String>,
    /// stop 已调用。
    stopped: bool,
}

impl TranslationController {
    /// 用外部服务建控制器，并在后台读译文缓存文件。
    pub fn new(services: TranslationServices) -> Self {
        let (reply_sender, replies) = mpsc::channel();
        let mut controller = Self {
            secrets: services.secrets,
            transport: services.transport,
            cache_store: services.cache_store,
            context: None,
            queue: TranslationQueue::new(),
            cache: TranslationCache::default(),
            cache_load: CacheLoad::Loaded,
            discard_loaded_cache: false,
            last_cache_save: f64::NEG_INFINITY,
            writer: None,
            key: KeyState::Unknown,
            key_provider: None,
            generation: 0,
            next_serial: 0,
            sent: HashMap::new(),
            current_serial: None,
            reply_sender,
            replies,
            last_enabled: false,
            target: None,
            last_endpoint: None,
            last_active: None,
            had_static_data: false,
            status: TranslationStatus::Off,
            testing: false,
            test_result: None,
            changed: false,
            log: Vec::new(),
            stopped: false,
        };
        controller.start_loading();
        controller
    }

    /// 翻译的状态，「翻译」页与问题报告读它。功能关着时是 Off。
    pub fn status(&self) -> &TranslationStatus {
        &self.status
    }

    /// 取走攒着的日志行（只有条数、状态码与失败的种类）。
    pub fn take_log_lines(&mut self) -> Vec<String> {
        std::mem::take(&mut self.log)
    }

    /// 记一行日志；超过上限时丢掉最早的一行。
    fn note(&mut self, line: impl Into<String>) {
        if self.log.len() >= MAX_LOG_LINES {
            self.log.remove(0);
        }
        self.log.push(line.into());
    }

    /// 当前配置方案的翻译设置；还没有上下文时是默认值。
    fn settings(&self) -> TranslationSettings {
        self.context
            .as_ref()
            .map(|c| c.profile.translation.clone())
            .unwrap_or_default()
    }

    /// 功能是否打开。
    fn is_enabled(&self) -> bool {
        !self.stopped
            && self
                .context
                .as_ref()
                .is_some_and(|c| c.profile.translation.enabled)
    }

    /// 界面语言；还没有上下文时是英文。
    fn language(&self) -> AppLanguage {
        self.context.as_ref().map_or(AppLanguage::En, |c| c.language)
    }

    // MARK: 上下文与消息

    /// 配置、星图数据、活动角色、聊天日志状态或界面语言变了。每次配置变化都会调用，只做比较与少量更新。
    pub fn update(&mut self, context: ChatFeedContext, now: f64) {
        if self.stopped {
            return;
        }
        // 先从新上下文里取出要比较的几项，再把它存下：后面的判断与重新分类都读 self.context。
        // 目标语言「跟随界面」时由界面语言决定，所以换界面语言也可能换目标语言。
        let enabled = context.profile.translation.enabled;
        let endpoint = context.general.translation_endpoint.clone();
        let new_target = context
            .profile
            .translation
            .target_language
            .resolved(context.language);
        let has_static_data = context.static_data.is_some();
        let active = context.active_character.clone();
        self.context = Some(context);
        if !enabled {
            if self.last_enabled {
                // 关掉功能：在途的请求连结果都不要了。
                self.last_enabled = false;
                self.abandon_in_flight(true);
            }
            self.refresh_status();
            return;
        }
        // 读 Key 的第一个时机：开关刚打开，或换了预设（每个预设一项凭据）。
        let turned_on = !self.last_enabled;
        self.last_enabled = true;
        if turned_on || self.key_provider != Some(endpoint.provider) {
            self.load_key(endpoint.provider);
        }
        if turned_on || self.last_endpoint.as_ref() != Some(&endpoint) {
            // 开关刚打开或接口设置变了：清掉暂停，旧请求的结果不再改状态。
            self.abandon_in_flight(false);
            self.queue.reset(now);
        }
        self.last_endpoint = Some(endpoint);
        // 星图数据第一次到达：之前按普通文字判断的消息里可能只有术语，要重新判断。
        let got_static_data = !self.had_static_data && has_static_data;
        self.had_static_data = has_static_data;
        let target_changed = self.target.is_some_and(|t| t != new_target);
        self.target = Some(new_target);
        if target_changed || got_static_data {
            self.reclassify(now);
        }
        if active != self.last_active {
            self.queue.activate(active.as_deref(), now);
            self.last_active = active;
        }
        self.pump(now);
    }

    /// 属于翻译的事件，按日志里的先后顺序。系统消息不进入；补读到活动角色的消息后排最近的 20 条。
    /// 返回内容是否变了。
    pub fn ingest(&mut self, events: Vec<ChatLogEvent>, now: f64) -> bool {
        if !self.is_enabled() {
            return false;
        }
        // 补读的消息先照常放入（进入时是 Off），全部放完后再按 activate 的规则排最近的。
        let mut appended = false;
        let mut active_backfill = false;
        for event in events {
            let ChatLogEvent::Message(message) = event else {
                continue;
            };
            if SYSTEM_SPEAKERS.contains(&message.speaker.as_str()) {
                continue;
            }
            if message.is_backfill && self.is_active(&message.listener) {
                active_backfill = true;
            }
            let phase = self.phase_for(&message, true);
            self.queue.append(message, phase, now);
            appended = true;
        }
        if active_backfill {
            let active = self.context.as_ref().and_then(|c| c.active_character.clone());
            self.queue.activate(active.as_deref(), now);
        }
        self.refresh_status();
        self.pump(now);
        appended
    }

    /// 浮窗的内容：标题、状态行与活动角色的各条。
    pub fn content(&self, now: f64) -> OverlayContent {
        let language = self.language();
        let character = self.context.as_ref().and_then(|c| c.active_character.clone());
        // 有活动角色时标题带角色名，否则显示页名「翻译」。
        let title = match &character {
            Some(name) => eveo_l10n::translation(language).overlay_title(name),
            None => eveo_l10n::settings(language).page_translation().to_owned(),
        };
        let formatter = TranslationFormatter { language };
        let settings = self.settings();
        let lines = character
            .as_deref()
            .map(|name| {
                self.queue
                    .items(name)
                    .iter()
                    .filter_map(|item| presenter::line(item, &settings, &formatter))
                    .collect()
            })
            .unwrap_or_default();
        OverlayContent {
            context_key: format!("translation:{}", character.unwrap_or_default()),
            title,
            status: self.status_line(now),
            lines,
        }
    }

    /// 清空某个角色（None 表示全部）的缓冲。缓存与暂停的原因都不变。
    pub fn clear(&mut self, character: Option<&str>) {
        self.queue.remove_items(character);
        self.refresh_status();
    }

    /// 在应用的定时器里调用：收缓存文件与答复，到时发下一批，满 30 秒存一次盘。返回内容或状态是否变了。
    pub fn tick(&mut self, now: f64) -> bool {
        if self.stopped {
            return false;
        }
        // 顺序：先合并缓存文件（之后的答复存进合并后的缓存），再收答复，最后看要不要发下一批。
        self.poll_loading();
        self.drain_replies(now);
        // 防抖与等待到期都由队列给出时刻；到了就再检查一次。
        if self.is_enabled() && self.queue.next_attempt().is_some_and(|at| at <= now) {
            self.pump(now);
        }
        self.save_cache_if_due(now, false);
        std::mem::take(&mut self.changed)
    }

    /// 下一次 tick 有事可做的时刻：队列的下一次尝试；没有时为 None。应用的定时器只用它在空闲时放慢。
    pub fn next_attempt(&self) -> Option<f64> {
        if self.is_enabled() {
            self.queue.next_attempt()
        } else {
            None
        }
    }

    /// 停止：丢掉在途的请求，等写入线程写完，缓存有改动时同步存一次。应用退出时调用。
    pub fn stop(&mut self) {
        if std::mem::replace(&mut self.stopped, true) {
            return;
        }
        self.abandon_in_flight(true);
        self.sent.clear();
        // 关掉写入线程的发送端，线程写完排着的快照后自己结束；等它结束，免得它稍后用旧快照盖掉下面的最后一次。
        if let Some(writer) = self.writer.take() {
            drop(writer.snapshots);
            let _ = writer.handle.join();
        }
        if matches!(self.cache_load, CacheLoad::Loaded)
            && self.cache.is_dirty()
            && let Err(error) = self.cache_store.save(self.cache.snapshot())
        {
            self.note(format!("译文缓存存盘失败：{:?}", error.kind()));
        }
        self.status = TranslationStatus::Off;
    }

    // MARK: 判断与排队

    /// 一条消息进入时的阶段。allow_pending 为假时（重新判断旧消息），没有缓存的消息一律是 Off。
    fn phase_for(&mut self, message: &ChatMessage, allow_pending: bool) -> Phase {
        // 还没打开过功能时没有目标语言，按界面语言判断（这时其实不会有消息进来）。
        let target = self.target.unwrap_or_else(|| self.language());
        let data = self.context.as_ref().and_then(|c| c.static_data.clone());
        let matches = data
            .as_ref()
            .map(|d| d.matcher.matches(&message.text))
            .unwrap_or_default();
        // 没有星图数据时不识别星系与舰船，按普通文字判断（只有情报用语时也会交给模型）。
        let report = if data.is_some() {
            parse(&message.text, &matches)
        } else {
            IntelReport::plain(&message.text)
        };
        let line = ChatLine {
            time: message.time,
            speaker: message.speaker.clone(),
            text: message.text.clone(),
            is_system: false,
        };
        // 不用模型的消息：系统说话人、空消息、已是目标语言、只有术语。只有术语时显示术语替换后的文字。
        if let Some(reason) = rules::skip_reason(&line, &report, target) {
            let rendered = (reason == SkipReason::TermsOnly)
                .then(|| rules::render_terms(&message.text, &matches, target))
                .filter(|text| *text != message.text);
            return Phase::Skipped(reason, rendered);
        }
        if let Some(hit) = self.cache.value(&message.text, target) {
            return rules::result_phase(&hit, &message.text, target);
        }
        if allow_pending && !message.is_backfill && self.is_active(&message.listener) {
            Phase::Pending
        } else {
            Phase::Off
        }
    }

    /// 按当前的目标语言与星图数据重新判断缓冲里的全部消息。暂停的原因保留。
    fn reclassify(&mut self, now: f64) {
        // 先记下全部条目与暂停的原因，清空队列后按新条件逐条放回。
        let items = self.queue.all_items();
        let previous = self.queue.status().clone();
        self.abandon_in_flight(false);
        self.queue.clear();
        for item in items {
            let phase = self.phase_for(&item.message, false);
            self.queue.append(item.message, phase, now);
        }
        let active = self.context.as_ref().and_then(|c| c.active_character.clone());
        self.queue.activate(active.as_deref(), now);
        if let TranslationStatus::Blocked(failure) = previous {
            self.queue.fail(failure, &[], now);
        }
        self.changed = true;
    }

    /// 收听者是不是活动角色（先原样、再不区分大小写）。
    fn is_active(&self, listener: &str) -> bool {
        let Some(active) = self.context.as_ref().and_then(|c| c.active_character.as_deref()) else {
            return false;
        };
        match_name(listener, [active]).is_some()
    }

    // MARK: 状态

    /// 按开关与队列算出状态，返回是否变了。
    fn refresh_status(&mut self) -> bool {
        // 功能关着时对外一律是 Off，队列里的暂停原因保留到下次打开。
        let status = if self.is_enabled() {
            self.queue.status().clone()
        } else {
            TranslationStatus::Off
        };
        if status == self.status {
            return false;
        }
        self.status = status;
        true
    }

    /// 状态变了时记下要刷新。
    fn notify_if_status_changed(&mut self) {
        if self.refresh_status() {
            self.changed = true;
        }
    }

    /// 浮窗的状态行：聊天日志的错误；没有翻译频道；暂停（error）；活动角色在所选频道都没有日志文件（warning）；
    /// 等待重试（warning）；其余不显示。
    fn status_line(&self, now: f64) -> Option<OverlayStatus> {
        let language = self.language();
        let status = |text: String, level| Some(OverlayStatus { text, level });
        let settings_text = eveo_l10n::settings(language);
        match self.context.as_ref().map(|c| &c.chat_log_status) {
            Some(ChatLogStatus::DirectoryNotFound(path)) => {
                return status(
                    settings_text.chat_log_status_directory_not_found(path),
                    OverlayStatusLevel::Error,
                );
            }
            Some(ChatLogStatus::AccessDenied(path)) => {
                return status(
                    settings_text.chat_log_status_access_denied(path),
                    OverlayStatusLevel::Error,
                );
            }
            _ => {}
        }
        let text = eveo_l10n::translation(language);
        let settings = self.settings();
        if settings.channels.is_empty() {
            return status(text.status_no_channels().to_owned(), OverlayStatusLevel::Info);
        }
        if matches!(self.status, TranslationStatus::Blocked(_)) {
            return status(
                status_text(language, &self.status, now),
                OverlayStatusLevel::Error,
            );
        }
        // EVE 没有为这些频道写日志时，浮窗只会是「还没有消息」，用户会以为翻译坏了。
        if let Some(names) = self.missing_log_channel_names() {
            // 缺的里有内置频道时，多半是客户端语言不是英文（EVE 此时可能不写系统频道的日志），提示里给出办法。
            let built_in = settings.channels.iter().any(|c| c.is_built_in());
            let line = if built_in {
                text.status_no_log_files_built_in(&names)
            } else {
                text.status_no_log_files(&names)
            };
            return status(line, OverlayStatusLevel::Warning);
        }
        if matches!(self.status, TranslationStatus::Waiting { .. }) {
            return status(
                status_text(language, &self.status, now),
                OverlayStatusLevel::Warning,
            );
        }
        None
    }

    /// 活动角色在所选的每个翻译频道都没有被跟踪的日志文件时，返回这些频道的显示名；否则为 None。
    /// 跟踪服务还没扫描完、没有活动角色时也是 None。
    fn missing_log_channel_names(&self) -> Option<Vec<String>> {
        let context = self.context.as_ref()?;
        let character = context.active_character.as_deref()?;
        // 跟踪服务还没报告过日志文件（followed 为 None）时 lacks_all_logs 为假，不会误报。
        let channels = &context.profile.translation.channels;
        if !lacks_all_logs(character, channels, context.followed_channels.as_deref()) {
            return None;
        }
        Some(
            channels
                .iter()
                .map(|channel| channel_display_name(channel, context.language))
                .collect(),
        )
    }
}
