// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译的总控，对应 macOS 的 ChatFeatureController（docs/macos/design-intel-translate.md 9.2 节）。
// macOS 的总控直接持有跟踪服务与读星图数据的任务；这里只做决定，跟踪服务、读文件与定时器由应用层执行，
// 所以总控不依赖平台层，能在 Linux 上测试。
//
// - 请求：当前配置方案的预警开着时要求跟踪聊天日志，关着时要求停止。频道取预警的频道，跟踪位置，
//   补读「保留最近」的分钟数。请求按 ChatLogRequest::requires_restart 判断变没变：只有补读秒数变了时不重建。
//   请求要重建时先清空缓冲，再让应用层重建跟踪服务；跟踪服务重建后补读，缓冲由补读填回，不会出现重复的消息。
// - 星图数据：第一次有功能打开时要求读一次（take_static_data_request），结果留到应用退出。
// - 分发：消息交给「已打开、且频道列表里有一项与它匹配」的功能；位置线索只给预警。
// - 任何影响内容的变化（配置、语言、活动角色、跟踪状态、星图数据）之后，把新上下文交给各功能。
// - 按时间的刷新：可见浮窗的 next_refresh 里最早的时刻，应用层到时取一次内容。
//
// - 翻译：请求取两个功能的并集（频道去重；跟踪位置取预警的开关；补读取「预警的保留分钟数」与「翻译的 600 秒」里
//   较大的一个）；消息两个功能都匹配时各给一份；跟踪的日志文件变了时也更新各功能（翻译据此提示 EVE 没写日志）。
// 与 macOS 的差别：翻译控制器是可选的（测试里不接），没有时翻译浮窗给一份空内容。
// 时钟：日志时间与「多久以前」用墙上时钟（1970 年以来的秒数），由调用方传入。

//! 预警与翻译的总控。

use std::collections::BTreeSet;
use std::sync::Arc;

use eveo_core::chat_log::coverage::FollowedChatChannel;
use eveo_core::chat_log::request::ChatLogRequest;
use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus, ChatMessage};
use eveo_core::model::{AppConfig, AppLanguage, ChannelRef};
use eveo_core::overlay::{OverlayContent, OverlayKind};
use eveo_core::static_data::EveStaticData;
use eveo_core::translation::rules::BACKFILL_QUEUE_SECONDS;

use super::ChatFeedContext;
use super::intel::IntelController;
use crate::translation::TranslationController;

/// 应用层对跟踪服务要做的事。
#[derive(Debug, Clone, PartialEq)]
pub enum TailerCommand {
    /// 按这个请求（重新）开始跟踪。已有的跟踪服务先停掉。
    Start(ChatLogRequest),
    /// 停止跟踪。
    Stop,
}

/// 读星图数据的结果。
#[derive(Debug, Clone)]
pub enum StaticDataLoad {
    /// 读到并解码成功；source 是文件的来源（只写进诊断信息，不含路径）。
    Loaded(Arc<EveStaticData>, &'static str),
    /// 没有任何数据文件。
    Missing,
    /// 有文件，但读不了或解不开。
    Invalid,
}

/// 预警与翻译的总控。全部方法在主线程上调用。
pub struct ChatFeatures {
    /// 预警功能。
    intel: IntelController,
    /// 翻译功能；测试里可以不接。
    translation: Option<TranslationController>,
    /// 最近一次的完整配置；apply 之前为 None。
    config: Option<AppConfig>,
    /// 界面语言。
    language: AppLanguage,
    /// 活动角色。
    active_character: Option<String>,
    /// 可见的浮窗；只有它们参与按时间的刷新。
    visible: BTreeSet<OverlayKind>,
    /// 跟踪服务最近报告的状态。
    chat_log_status: ChatLogStatus,
    /// 跟踪服务最近报告的日志文件（收听者与频道）；还没报告过时为 None。
    followed_channels: Option<Vec<FollowedChatChannel>>,
    /// 最近一次要求的请求；None 表示没有在跟踪。
    current_request: Option<ChatLogRequest>,
    /// 星图数据；还没读、缺失或无效时为 None。
    static_data: Option<Arc<EveStaticData>>,
    /// 给问题报告与设置界面：`build-<版本号>`、`missing`、`invalid`、`notLoaded`。
    static_data_state: String,
    /// 是否已要求读星图数据（只读一次）。
    static_data_requested: bool,
    /// 星图数据的读取请求还没被应用层取走。
    static_data_request_pending: bool,
    /// 已停止，之后的调用都直接返回。
    stopped: bool,
}

impl ChatFeatures {
    /// 用预警控制器与界面语言建总控；调用 apply 后才开始工作。
    pub fn new(intel: IntelController, language: AppLanguage) -> Self {
        Self {
            intel,
            translation: None,
            config: None,
            language,
            active_character: None,
            visible: BTreeSet::new(),
            chat_log_status: ChatLogStatus::Stopped,
            followed_channels: None,
            current_request: None,
            static_data: None,
            static_data_state: "notLoaded".to_owned(),
            static_data_requested: false,
            static_data_request_pending: false,
            stopped: false,
        }
    }

    /// 接上翻译功能（应用启动时调用一次）。
    pub fn with_translation(mut self, translation: TranslationController) -> Self {
        self.translation = Some(translation);
        self
    }

    /// 翻译功能（「翻译」页读状态、Key 与缓存条数）。
    pub fn translation(&self) -> Option<&TranslationController> {
        self.translation.as_ref()
    }

    /// 翻译功能的可变引用（「翻译」页的保存 Key、测试、重试、清空缓存）。
    pub fn translation_mut(&mut self) -> Option<&mut TranslationController> {
        self.translation.as_mut()
    }

    /// 预警功能（设置界面读位置、人名缓存等）。
    pub fn intel(&self) -> &IntelController {
        &self.intel
    }

    /// 预警功能的可变引用（设置界面的「手动位置」「清空人名缓存」）。
    pub fn intel_mut(&mut self) -> &mut IntelController {
        &mut self.intel
    }

    /// 界面语言。
    pub fn language(&self) -> AppLanguage {
        self.language
    }

    /// 星图数据；还没读完、缺失或无效时为 None。
    pub fn static_data(&self) -> Option<&EveStaticData> {
        self.static_data.as_deref()
    }

    /// 最近一次交来的配置；还没交过时为 None。
    pub fn config(&self) -> Option<&AppConfig> {
        self.config.as_ref()
    }

    /// 跟踪服务最近报告的状态。
    pub fn chat_log_status(&self) -> &ChatLogStatus {
        &self.chat_log_status
    }

    /// 星图数据的状态：`build-<版本号>`、`missing`、`invalid`、`notLoaded`。
    pub fn static_data_state(&self) -> &str {
        &self.static_data_state
    }

    /// 当前活动角色名；翻译浮窗的频道切换菜单据此优先排当前角色的频道。
    pub fn active_character(&self) -> Option<&str> {
        self.active_character.as_deref()
    }

    /// 配置变了（含启动时的第一次）：先把新上下文交给各功能，再算请求；请求要重建时清空缓冲。
    /// 返回应用层要对跟踪服务做的事；不用动时为 None。
    pub fn apply(&mut self, config: &AppConfig, now: f64) -> Option<TailerCommand> {
        if self.stopped {
            return None;
        }
        // 翻译频道切换时，即便新旧频道都在预警列表里（并集没变），也要清掉旧频道的翻译缓冲并补读新频道。
        let translation_channels_changed = self
            .config
            .as_ref()
            .and_then(AppConfig::active_profile)
            .zip(config.active_profile())
            .is_some_and(|(old, new)| {
                old.translation.enabled
                    && new.translation.enabled
                    && old.translation.channels != new.translation.channels
            });
        self.config = Some(config.clone());
        // 先更新上下文再启动跟踪：跟踪服务一启动就可能上报事件，这时功能要已经知道新的频道与开关。
        self.update_consumers(now);
        let request = Self::request_for(config);
        let restart = ChatLogRequest::requires_restart(self.current_request.as_ref(), request.as_ref())
            || translation_channels_changed;
        // 只有补读秒数变了时也记下新请求，但不重建：缓冲在每次刷新时按新的「保留最近」修剪。
        self.current_request = request.clone();
        if request.is_some() && !self.static_data_requested {
            self.static_data_requested = true;
            self.static_data_request_pending = true;
        }
        if !restart {
            return None;
        }
        // 先清空缓冲：跟踪服务重建后会补读最近的内容，不清空会出现重复的消息。位置记录、人名缓存与译文缓存不清。
        self.intel.clear(None);
        if let Some(translation) = &mut self.translation {
            translation.clear(None);
        }
        Some(request.map_or(TailerCommand::Stop, TailerCommand::Start))
    }

    /// 应用层取走「读星图数据」的请求：第一次有功能打开后返回一次真，之后都是假。
    pub fn take_static_data_request(&mut self) -> bool {
        std::mem::take(&mut self.static_data_request_pending)
    }

    /// 星图数据读完：记下结果并更新各功能。返回给诊断日志的一行（不含路径）。
    pub fn static_data_loaded(&mut self, result: StaticDataLoad, now: f64) -> String {
        let line = match result {
            StaticDataLoad::Loaded(data, source) => {
                self.static_data_state = format!("build-{}", data.sde_build);
                let line = format!("星图数据已读入：来源 {source}，SDE 版本 {}", data.sde_build);
                self.static_data = Some(data);
                line
            }
            StaticDataLoad::Missing => {
                self.static_data_state = "missing".to_owned();
                "没有星图数据文件".to_owned()
            }
            StaticDataLoad::Invalid => {
                self.static_data_state = "invalid".to_owned();
                "星图数据无效".to_owned()
            }
        };
        if !self.stopped {
            self.update_consumers(now);
        }
        line
    }

    /// 界面语言变了：各功能的文字都要换，调用方随后刷新全部浮窗。
    pub fn set_language(&mut self, language: AppLanguage, now: f64) {
        if self.stopped || language == self.language {
            return;
        }
        self.language = language;
        self.update_consumers(now);
    }

    /// 活动角色变了：返回真时调用方立即把浮窗换成新角色的内容。
    pub fn set_active_character(&mut self, name: Option<String>, now: f64) -> bool {
        if self.stopped || name == self.active_character {
            return false;
        }
        self.active_character = name;
        self.update_consumers(now);
        true
    }

    /// 记下可见的浮窗；只有它们参与按时间的刷新。
    pub fn set_visible(&mut self, kinds: BTreeSet<OverlayKind>) {
        self.visible = kinds;
    }

    /// 某个浮窗当前的内容。没接翻译功能时翻译浮窗给一份空内容兜底。
    pub fn content(&mut self, kind: OverlayKind, now: f64) -> OverlayContent {
        match kind {
            OverlayKind::Intel => self.intel.content(now),
            OverlayKind::Translation => match &self.translation {
                Some(translation) => translation.content(now),
                None => OverlayContent {
                    context_key: "translation:".to_owned(),
                    title: eveo_l10n::settings(self.language).page_translation().to_owned(),
                    channel_label: None,
                    status: None,
                    lines: Vec::new(),
                },
            },
        }
    }

    /// 清空活动角色在某个浮窗里的缓冲（浮窗右键菜单的「清空列表」）。没有活动角色时不做任何事。
    /// 返回内容是否可能变了。
    pub fn clear(&mut self, kind: OverlayKind) -> bool {
        let Some(active) = self.active_character.as_deref() else {
            return false;
        };
        match kind {
            OverlayKind::Intel => {
                self.intel.clear(Some(active));
                true
            }
            OverlayKind::Translation => match &mut self.translation {
                Some(translation) => {
                    translation.clear(Some(active));
                    true
                }
                None => false,
            },
        }
    }

    /// 一批事件：按频道分给各功能，各自保持日志里的顺序。返回内容变了的浮窗。
    pub fn events(&mut self, events: Vec<ChatLogEvent>, now: f64) -> BTreeSet<OverlayKind> {
        let mut changed = BTreeSet::new();
        let Some(profile) = self.config.as_ref().and_then(AppConfig::active_profile) else {
            return changed;
        };
        if self.stopped {
            return changed;
        }
        let intel = &profile.intel;
        let translation = &profile.translation;
        let mut intel_events = Vec::new();
        let mut translation_events = Vec::new();
        for event in events {
            match &event {
                ChatLogEvent::Message(message) => {
                    // 两个功能都匹配时各给一份（翻译的频道常常也是预警的频道，例如本地）。
                    if Self::accepts(message, translation.enabled, &translation.channels) {
                        translation_events.push(event.clone());
                    }
                    if Self::accepts(message, intel.enabled, &intel.channels) {
                        intel_events.push(event);
                    }
                }
                // 位置线索只有预警用；预警关着时丢掉（跟踪服务在那之前读到的线索）。
                ChatLogEvent::LocationHint(_) => {
                    if intel.enabled {
                        intel_events.push(event);
                    }
                }
            }
        }
        if !intel_events.is_empty() && self.intel.ingest(intel_events, now) {
            changed.insert(OverlayKind::Intel);
        }
        if !translation_events.is_empty()
            && let Some(controller) = &mut self.translation
            && controller.ingest(translation_events, now)
        {
            changed.insert(OverlayKind::Translation);
        }
        changed
    }

    /// 跟踪服务的状态变了：返回真时调用方刷新浮窗的状态行与设置窗口。
    pub fn status_changed(&mut self, status: ChatLogStatus, now: f64) -> bool {
        if self.stopped || status == self.chat_log_status {
            return false;
        }
        self.chat_log_status = status;
        self.update_consumers(now);
        true
    }

    /// 跟踪的日志文件变了（例如 EVE 新建了某个频道的日志）：返回真时调用方刷新浮窗的状态行。
    pub fn followed_changed(&mut self, followed: Vec<FollowedChatChannel>, now: f64) -> bool {
        if self.stopped || self.followed_channels.as_ref() == Some(&followed) {
            return false;
        }
        self.followed_channels = Some(followed);
        self.update_consumers(now);
        true
    }

    /// 在应用的定时器里调用：收人名核对的结果。返回内容变了的浮窗。
    pub fn tick(&mut self, now: f64) -> BTreeSet<OverlayKind> {
        let mut changed = BTreeSet::new();
        if self.stopped {
            return changed;
        }
        if self.intel.tick(now) {
            changed.insert(OverlayKind::Intel);
        }
        // 翻译：收答复、到时发下一批、满 30 秒存一次译文缓存。
        if let Some(translation) = &mut self.translation
            && translation.tick(now)
        {
            changed.insert(OverlayKind::Translation);
        }
        changed
    }

    /// 可见浮窗里最早要按时间刷新的时刻；没有可见浮窗、或都不用按时间刷新时为 None。
    pub fn next_refresh(&self, now: f64) -> Option<f64> {
        if self.stopped {
            return None;
        }
        self.visible
            .iter()
            .filter_map(|kind| match kind {
                OverlayKind::Intel => self.intel.next_refresh(now),
                // 翻译浮窗只在等待重试时随时间变（倒计时）。
                OverlayKind::Translation => self.translation.as_ref().and_then(|t| t.next_refresh(now)),
            })
            .min_by(f64::total_cmp)
    }

    /// 可见的浮窗（按时间刷新到点时，调用方刷新它们）。
    pub fn visible(&self) -> &BTreeSet<OverlayKind> {
        &self.visible
    }

    /// 停止各功能；之后应用层停掉跟踪服务。应用退出时调用。
    pub fn stop(&mut self, now: f64) {
        if std::mem::replace(&mut self.stopped, true) {
            return;
        }
        self.current_request = None;
        self.intel.stop(now);
        if let Some(translation) = &mut self.translation {
            translation.stop();
        }
    }

    /// 由配置算出跟踪请求；两个功能都关着时为 None。与 macOS 一样取两个功能的并集。
    pub fn request_for(config: &AppConfig) -> Option<ChatLogRequest> {
        let profile = config.active_profile()?;
        let intel = &profile.intel;
        let translation = &profile.translation;
        if !intel.enabled && !translation.enabled {
            return None;
        }
        // 去重并保持顺序：同一个频道在列表里出现两次（或两个功能都选了）时只跟踪一次。
        let mut channels: Vec<ChannelRef> = Vec::new();
        let intel_channels = intel.enabled.then_some(&intel.channels).into_iter().flatten();
        let translation_channels = translation
            .enabled
            .then_some(&translation.channels)
            .into_iter()
            .flatten();
        for channel in intel_channels.chain(translation_channels) {
            if !channels.contains(channel) {
                channels.push(channel.clone());
            }
        }
        // 补读：预警按「保留最近」，翻译固定 600 秒（只排最近的消息），取较大的一个。
        let intel_backfill = if intel.enabled {
            intel.window_minutes as f64 * 60.0
        } else {
            0.0
        };
        let translation_backfill = if translation.enabled {
            BACKFILL_QUEUE_SECONDS
        } else {
            0.0
        };
        let mut enabled_features = BTreeSet::new();
        if intel.enabled {
            enabled_features.insert(OverlayKind::Intel);
        }
        if translation.enabled {
            enabled_features.insert(OverlayKind::Translation);
        }
        Some(ChatLogRequest {
            log_directory: config.general.eve_log_directory.clone(),
            channels,
            follows_location: intel.enabled,
            backfill_seconds: intel_backfill.max(translation_backfill),
            enabled_features,
        })
    }

    /// 消息是否属于某个功能：功能已打开，且频道列表里有一项与它匹配（按 ID 或名称）。
    pub fn accepts(message: &ChatMessage, enabled: bool, channels: &[ChannelRef]) -> bool {
        enabled
            && channels
                .iter()
                .any(|c| c.matches(Some(&message.channel_id), Some(&message.channel_name)))
    }

    /// 用当前状态对各功能调一次 update。还没有配置时什么也不做。
    fn update_consumers(&mut self, now: f64) {
        let Some(config) = &self.config else {
            return;
        };
        let Some(profile) = config.active_profile() else {
            return;
        };
        let context = ChatFeedContext {
            profile: profile.clone(),
            general: config.general.clone(),
            static_data: self.static_data.clone(),
            active_character: self.active_character.clone(),
            chat_log_status: self.chat_log_status.clone(),
            followed_channels: self.followed_channels.clone(),
            language: self.language,
        };
        if let Some(translation) = &mut self.translation {
            translation.update(context.clone(), now);
        }
        self.intel.update(context, now);
    }
}
