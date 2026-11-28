// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警功能的控制器，对应 macOS 的 IntelFeedController 与 IntelFeedController+PilotLookup
// （docs/macos/design-intel-translate.md 6.8～6.10 节）：持有位置记录、预警缓冲、跳数表的缓存与人名核对服务，
// 产出预警浮窗的内容。全部方法在应用的主线程上调用。
//
// - update：每次配置、语言、活动角色、聊天日志状态或星图数据变化都会调用，应便宜且可重复调用。
//   各种触发都与上一次的上下文比较得出：星图数据第一次到达（或换了版本）时重新解析缓冲并补上早到的位置线索；
//   参考星系按 6.2 节换成 ID；人名核对的开关、活动角色变化时补排要查的名字。
// - ingest：位置线索交给 LocationTracker（星图数据还没到时先存起来，至多 200 条）；消息解析后进缓冲，
//   活动角色的新情报排进人名核对；含活动角色补读消息的一批事件之后补排一次。
// - content：取活动角色的消息逐条生成一行；跳数表按「出发星系、max_jumps、SDE 版本」缓存。
// - tick：在应用的定时器里调用，收人名核对的结果；缓存文件读完时补排。
// - clear：只清缓冲，不动位置记录与人名缓存（请求变了时调用方对全部角色调一次）。
//
// 与 macOS 的差别：手动位置的持久化（state.json）由应用层负责：控制器在手动位置变了时把 manual_dirty 置真，
// 应用层取走 manual_locations 写盘。人名核对服务是可选的：测试与没有联网能力的环境传 None。

//! 预警功能的控制器。

use std::collections::{BTreeMap, HashMap};

use eveo_core::chat_log::coverage::match_name;
use eveo_core::chat_log::tracker::{CharacterLocation, LocationOrigin, LocationSource, LocationTracker};
use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus, LocationHint};
use eveo_core::intel::IntelReport;
use eveo_core::intel::feed::IntelFeed;
use eveo_core::intel::parser::parse_with;
use eveo_core::intel::pilots::PilotLookupStatus;
use eveo_core::intel::pilots::segmenter::PilotDirectory;
use eveo_core::intel::presenter::{self, IntelLineFormatting, IntelPresentationContext};
use eveo_core::model::{AppLanguage, IntelSettings};
use eveo_core::overlay::{OverlayContent, OverlayStatus, OverlayStatusLevel};
use eveo_core::static_data::EveStaticData;
use eveo_core::static_data::jumps::distances;

use super::{ChatFeedContext, IntelFormatter, whole_seconds};
use crate::pilots::PilotLookupService;

/// 星图数据到达之前至多存几条位置线索。
pub const MAX_PENDING_HINTS: usize = 200;

/// 状态行显示位置的「多久以前」时，至少每隔几秒刷新一次。
const LOCATION_AGE_REFRESH: f64 = 60.0;

/// 跳数表的缓存：出发星系、max_jumps、SDE 版本与表本身。
///
/// 一次广度优先搜索要走遍 max_jumps 跳以内的全部星系（低安区可达几千个），而浮窗每秒都可能重画；
/// 出发星系不变时表不变，所以只在三者之一变化时重算。
type JumpCache = (i64, i64, i64, HashMap<i64, i64>);

/// 预警功能的控制器。
pub struct IntelController {
    /// 最近一次的上下文；还没调用过 update 时为 None。
    context: Option<ChatFeedContext>,
    /// 各角色的位置。
    tracker: LocationTracker,
    /// 预警缓冲。
    feed: IntelFeed,
    /// 星图数据到达之前收到的位置线索。
    pending_hints: Vec<LocationHint>,
    /// 缓冲里的消息是用哪个 SDE 版本的星图数据解析的；None 表示还没有星图数据。
    parsed_build: Option<i64>,
    /// 跳数表的缓存。
    jump_cache: Option<JumpCache>,
    /// 人名核对服务；None 表示不核对（测试、没有联网能力）。
    pilots: Option<PilotLookupService>,
    /// 核对关着时借出的空目录。
    empty_directory: PilotDirectory,
    /// 手动位置变了，应用层要写 state.json。
    manual_dirty: bool,
    /// 已停止。
    stopped: bool,
}

impl IntelController {
    /// 用 state.json 里的手动位置与人名核对服务建控制器。
    pub fn new(manual: BTreeMap<String, CharacterLocation>, pilots: Option<PilotLookupService>) -> Self {
        Self {
            context: None,
            tracker: LocationTracker::new(manual, None),
            feed: IntelFeed::default(),
            pending_hints: Vec::new(),
            parsed_build: None,
            jump_cache: None,
            pilots,
            empty_directory: PilotDirectory::default(),
            manual_dirty: false,
            stopped: false,
        }
    }

    /// 记下新的上下文，并按与上一次的差别处理星图数据、参考星系与人名核对。不报告变化（调用方会刷新）。
    pub fn update(&mut self, context: ChatFeedContext, now: f64) {
        if self.stopped {
            return;
        }
        // 先记下上一次的活动角色：换角色要补排人名核对，而比较要在 self.context 被新值替换之前做。
        let previous_active = self.context.as_ref().and_then(|c| c.active_character.clone());
        let mut data_arrived = false;
        if let Some(data) = context.static_data.clone()
            && Some(data.sde_build) != self.parsed_build
        {
            // 星图数据第一次到达或换了版本：按它重新解析缓冲，补上之前存起来的位置线索。
            self.parsed_build = Some(data.sde_build);
            data_arrived = true;
            self.feed.reparse(|message| parse_with(&message.text, &data));
            self.jump_cache = None;
            self.replay_pending_hints(&data);
        }
        // 参考星系每次都重新换算：名字可能刚改，星图数据可能刚到（之前查不到的名字现在查得到），
        // 换算本身只是一次哈希查找，不值得再和上一次比较。查不到的名字当作没设，状态行会提示位置未知。
        self.tracker.reference_system_id = context
            .profile
            .intel
            .reference_system
            .as_deref()
            .and_then(|name| context.static_data.as_ref()?.system_named(name))
            .map(|system| system.id);
        // 从「没有活动角色」变成有，也算换了角色；从有变成没有不算，那时没有要补排的消息。
        let character_changed =
            context.active_character.is_some() && context.active_character != previous_active;
        let lookup_enabled = context.profile.intel.enabled && context.profile.intel.resolve_pilot_names;
        self.context = Some(context);
        // 人名核对：开关从关变成开（且缓存已读完）、换了活动角色、星图数据刚到并重新解析之后，各补排一次。
        if let Some(pilots) = &mut self.pilots {
            let newly_enabled = pilots.set_enabled(lookup_enabled, now);
            if lookup_enabled && (newly_enabled || character_changed || data_arrived) {
                self.enqueue_backfill(now);
            }
        }
    }

    /// 位置线索交给位置记录；消息解析后进缓冲，活动角色的新情报排进人名核对。返回内容是否变了。
    pub fn ingest(&mut self, events: Vec<ChatLogEvent>, now: f64) -> bool {
        if self.stopped {
            return false;
        }
        // 星图数据是 Arc，克隆一份只是加引用计数，借此避免在循环里同时借用 self.context 与 self。
        let data = self.context.as_ref().and_then(|c| c.static_data.clone());
        let mut changed = false;
        // 这一批里有没有活动角色的补读消息；有就在循环结束后统一补排一次。
        let mut active_backfill = false;
        for event in events {
            match event {
                ChatLogEvent::LocationHint(hint) => match &data {
                    Some(data) => changed |= self.apply_hint(&hint, data),
                    None => {
                        // 星图数据还没到：先存起来，到了再补；只留最新的 200 条，早到的线索太多时旧的没有用。
                        self.pending_hints.push(hint);
                        let excess = self.pending_hints.len().saturating_sub(MAX_PENDING_HINTS);
                        self.pending_hints.drain(..excess);
                    }
                },
                ChatLogEvent::Message(message) => {
                    // 没有星图数据时按纯文本存：星系名与船名都认不出，数据到了之后 update 会整批重新解析。
                    let report = data.as_ref().map_or_else(
                        || IntelReport::plain(&message.text),
                        |d| parse_with(&message.text, d),
                    );
                    let active = self.is_active_listener(&message.listener);
                    let backfill = message.is_backfill;
                    // 补读的消息不逐条排：一批里可能有几百条，收完后从最新的往前补排一次，满 500 个名字为止。
                    if active
                        && !backfill
                        && let Some(pilots) = &mut self.pilots
                    {
                        pilots.enqueue_report(&report, now);
                    }
                    active_backfill |= active && backfill;
                    self.feed.append(message, report);
                    changed = true;
                }
            }
        }
        if active_backfill {
            self.enqueue_backfill(now);
        }
        changed
    }

    /// 在应用的定时器里调用：收人名核对的结果。返回浮窗要不要刷新。
    pub fn tick(&mut self, now: f64) -> bool {
        let Some(pilots) = &mut self.pilots else {
            return false;
        };
        // 核对服务在后台线程上查询，结果在这里（主线程）收下；返回的 changed 表示有新的名字核对完，
        // 浮窗里对应的人名要换成核对后的样式。
        let tick = pilots.tick(now);
        if tick.wants_backfill {
            self.enqueue_backfill(now);
        }
        tick.changed
    }

    /// 浮窗的内容：活动角色的各条消息，标题与状态行。顺带清掉超过保留时长的消息。
    pub fn content(&mut self, now: f64) -> OverlayContent {
        let settings = self
            .context
            .as_ref()
            .map_or_else(IntelSettings::default, |c| c.profile.intel.clone());
        let language = self.language();
        // 过期清理放在生成内容时做，而不是另开定时器：next_refresh 已经把最早一条的过期时刻算进去了，
        // 到时会触发一次刷新，清理就跟着发生。
        self.feed.prune(now - settings.window_minutes as f64 * 60.0);
        let active = self.context.as_ref().and_then(|c| c.active_character.clone());
        let text = eveo_l10n::intel(language);
        let title = active.as_deref().map_or_else(
            || eveo_l10n::settings(language).page_intel().to_owned(),
            |name| text.overlay_title(name),
        );
        let formatter = IntelFormatter { language };
        let data = self.context.as_ref().and_then(|c| c.static_data.clone());
        // 有星图数据时每行带跳数、安等、船型强调；没有时退回纯文本行（时间、发言人与原文），
        // 状态行会说明原因，用户不会以为预警坏了。
        let lines = match &data {
            Some(data) => {
                let origin = self.tracker.origin(active.as_deref());
                let table = self.distances(origin, settings.max_jumps, data);
                let directory = self.pilot_directory();
                let presentation = IntelPresentationContext {
                    distances: table.as_ref(),
                    settings: &settings,
                    language,
                    now,
                    pilots: directory,
                };
                let items = active.as_deref().map(|a| self.feed.items(a)).unwrap_or_default();
                items
                    .into_iter()
                    .map(|item| presenter::line(item, &presentation, data, &formatter))
                    .collect()
            }
            None => {
                let items = active.as_deref().map(|a| self.feed.items(a)).unwrap_or_default();
                items
                    .into_iter()
                    .map(|item| presenter::plain_line(item, now, &formatter))
                    .collect()
            }
        };
        // context_key 换了时浮窗视图会重置滚动位置并回到最新；同一角色的内容更新只做增量比较。
        OverlayContent {
            context_key: format!("intel:{}", active.as_deref().unwrap_or("")),
            title,
            channel_label: None,
            status: self.status_line(now, &formatter),
            lines,
        }
    }

    /// 下一次按时间刷新的时刻：消息的年龄文字与过期清理；状态行显示位置的「多久以前」时至少每分钟一次。
    pub fn next_refresh(&self, now: f64) -> Option<f64> {
        let context = self.context.as_ref()?;
        let active = context.active_character.as_deref()?;
        let next = presenter::next_refresh(self.feed.items(active), now);
        // 只有用角色自己的位置作出发点时，状态行才显示「多久以前」；参考星系与位置未知时状态行不随时间变。
        if context.static_data.is_some()
            && let LocationOrigin::Character(_) = self.tracker.origin(Some(active))
        {
            return Some(next.unwrap_or(f64::INFINITY).min(now + LOCATION_AGE_REFRESH));
        }
        next
    }

    /// 清空某个角色的缓冲；character 为 None 时清空全部。位置记录与人名缓存不动。
    pub fn clear(&mut self, character: Option<&str>) {
        match character {
            Some(character) => {
                self.feed.remove_items(character);
            }
            None => self.feed.remove_all(),
        }
    }

    /// 停止：人名缓存有改动时同步存盘。应用退出时调用。
    pub fn stop(&mut self, now: f64) {
        // 重复调用不重复存盘：退出流程与窗口关闭可能各调一次。
        if std::mem::replace(&mut self.stopped, true) {
            return;
        }
        if let Some(pilots) = &mut self.pilots {
            let _ = pilots.shutdown(now);
        }
    }

    // MARK: 设置界面用

    /// 各角色的位置。
    pub fn locations(&self) -> &BTreeMap<String, CharacterLocation> {
        self.tracker.locations()
    }

    /// 星图数据的 SDE 版本；没有星图数据时为 None。
    pub fn static_data_build(&self) -> Option<i64> {
        self.context
            .as_ref()
            .and_then(|c| c.static_data.as_ref())
            .map(|d| d.sde_build)
    }

    /// 人名核对的状态；没有核对服务时是 Off。
    pub fn pilot_lookup_status(&self) -> PilotLookupStatus {
        self.pilots
            .as_ref()
            .map_or(PilotLookupStatus::Off, PilotLookupService::status)
    }

    /// 已保存的角色名个数与缓存文件是否已读完（「预警」页显示用）。
    pub fn pilot_cache(&self) -> (usize, bool) {
        self.pilots
            .as_ref()
            .map_or((0, false), |p| (p.matched_count(), p.is_cache_loaded()))
    }

    /// 「清空人名缓存」。
    pub fn clear_pilot_cache(&mut self, now: f64) {
        if let Some(pilots) = &mut self.pilots {
            pilots.clear(now);
        }
    }

    /// 手动设置某个角色的位置。星系名查不到（或没有星图数据）时返回假。
    pub fn set_manual_location(&mut self, character: &str, system_name: &str, now: f64) -> bool {
        let Some(system_id) = self
            .context
            .as_ref()
            .and_then(|c| c.static_data.as_ref()?.system_named(system_name))
            .map(|s| s.id)
        else {
            return false;
        };
        // 星系没变（重复设成同一个星系）时不必写盘，但仍返回真：输入本身是有效的。
        if self.tracker.set_manual(character, Some(system_id), now) {
            self.manual_dirty = true;
        }
        true
    }

    /// 清除某个角色的位置记录（任何来源）。返回记录是否变了。
    pub fn clear_manual_location(&mut self, character: &str, now: f64) -> bool {
        let changed = self.tracker.set_manual(character, None, now);
        self.manual_dirty |= changed;
        changed
    }

    /// 手动位置变了时取走要写进 state.json 的内容；没变时为 None。
    pub fn take_manual_locations(&mut self) -> Option<BTreeMap<String, CharacterLocation>> {
        std::mem::take(&mut self.manual_dirty).then(|| self.tracker.manual_locations())
    }

    // MARK: 内部

    /// 界面语言；还没有上下文时按英文。
    fn language(&self) -> AppLanguage {
        self.context.as_ref().map_or(AppLanguage::En, |c| c.language)
    }

    /// 收听者是不是活动角色（先原样比较，再不区分大小写比较）。
    fn is_active_listener(&self, listener: &str) -> bool {
        self.context
            .as_ref()
            .and_then(|c| c.active_character.as_deref())
            .is_some_and(|active| match_name(active, [listener]).is_some())
    }

    /// 给显示用的核对结果；没有核对服务时是空目录，显示回到解析器的推断。
    fn pilot_directory(&self) -> &PilotDirectory {
        self.pilots
            .as_ref()
            .map_or(&self.empty_directory, PilotLookupService::directory)
    }

    /// 补排：活动角色在缓冲里的消息，从最新的一条往前。
    fn enqueue_backfill(&mut self, now: f64) {
        let Some(active) = self.context.as_ref().and_then(|c| c.active_character.clone()) else {
            return;
        };
        let Some(pilots) = &mut self.pilots else {
            return;
        };
        // 从最新的往前排：核对服务每批有上限（500 个名字），最新的情报最有用，先核对。
        let items = self.feed.items(&active);
        pilots.enqueue_backfill(items.iter().rev().map(|item| &item.report), now);
    }

    /// 应用一条位置线索；手动位置被覆盖时记下要写盘。返回位置是否变了。
    fn apply_hint(&mut self, hint: &LocationHint, data: &EveStaticData) -> bool {
        // 新的线索会覆盖同一角色的手动位置（角色已经离开那个星系），手动表因此变短，要写回 state.json；
        // 比较前后两份手动表是最直接的判断，表很小（每个角色一项），代价可以忽略。
        let manual_before = self.tracker.manual_locations();
        let changed = self.tracker.apply(hint, data);
        if self.tracker.manual_locations() != manual_before {
            self.manual_dirty = true;
        }
        changed
    }

    /// 星图数据到达后，补上之前存起来的位置线索。
    fn replay_pending_hints(&mut self, data: &EveStaticData) {
        // 按收到的顺序补：同一角色的多条线索里，最后一条（最新的）留下来。
        for hint in std::mem::take(&mut self.pending_hints) {
            self.apply_hint(&hint, data);
        }
    }

    /// 从出发点算出的跳数表；出发点未知时为 None。按出发星系、max_jumps 与 SDE 版本缓存。
    fn distances(
        &mut self,
        origin: LocationOrigin,
        max_jumps: i64,
        data: &EveStaticData,
    ) -> Option<HashMap<i64, i64>> {
        let origin = origin.system_id()?;
        if let Some((cached_origin, cached_max, cached_build, table)) = &self.jump_cache
            && (*cached_origin, *cached_max, *cached_build) == (origin, max_jumps, data.sde_build)
        {
            return Some(table.clone());
        }
        let table = distances(origin, max_jumps, data);
        self.jump_cache = Some((origin, max_jumps, data.sde_build, table.clone()));
        Some(table)
    }

    /// 浮窗的状态行，按 6.8 节的表取第一个成立的。
    fn status_line(&self, now: f64, formatter: &IntelFormatter) -> Option<OverlayStatus> {
        let context = self.context.as_ref()?;
        let language = context.language;
        let settings = eveo_l10n::settings(language);
        let text = eveo_l10n::intel(language);
        let status = |text: String, level| Some(OverlayStatus { text, level });
        // 顺序与 macOS 一致：读不到聊天日志最严重（什么都收不到），其次是缺星图数据（收得到但算不了跳数），
        // 再次是没选频道（功能等于没开），最后才是位置信息。
        match &context.chat_log_status {
            ChatLogStatus::AccessDenied(path) => {
                return status(
                    settings.chat_log_status_access_denied(path),
                    OverlayStatusLevel::Error,
                );
            }
            ChatLogStatus::DirectoryNotFound(path) => {
                return status(
                    settings.chat_log_status_directory_not_found(path),
                    OverlayStatusLevel::Error,
                );
            }
            ChatLogStatus::Stopped | ChatLogStatus::Watching { .. } => {}
        }
        let Some(data) = &context.static_data else {
            return status(
                text.status_no_static_data().to_owned(),
                OverlayStatusLevel::Warning,
            );
        };
        if context.profile.intel.channels.is_empty() {
            return status(text.status_no_channels().to_owned(), OverlayStatusLevel::Info);
        }
        let name = |id: i64| {
            data.system(id)
                .map_or_else(|| id.to_string(), |s| s.name_in(language).to_owned())
        };
        match self.tracker.origin(context.active_character.as_deref()) {
            LocationOrigin::Unknown => status(
                text.status_location_unknown().to_owned(),
                OverlayStatusLevel::Warning,
            ),
            LocationOrigin::Reference(id) => {
                status(text.status_using_reference(&name(id)), OverlayStatusLevel::Info)
            }
            LocationOrigin::Character(location) => {
                let source = match location.source {
                    LocationSource::GameLog => text.source_game_log(),
                    LocationSource::LocalChannel => text.source_local(),
                    LocationSource::Manual => text.source_manual(),
                };
                let age = formatter.age(whole_seconds(now - location.time));
                status(
                    text.status_location(&name(location.system_id), source, &age),
                    OverlayStatusLevel::Info,
                )
            }
        }
    }
}
