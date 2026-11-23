// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器，对应 macOS 的 AppCoordinator（架构文档 3.3 节、7.2 节）。
// 每个事件只更新状态并标记「需要重算」；同一次 handle 的末尾最多重算一次，得出效果列表。
// 这和 macOS 的 setNeedsReplan 合并同一回合内多次请求是一个意思。
//
// 与 macOS 的差别：
// - 没有捕获流要协调，DWM 缩略图注册的结果以 ThumbnailStatusChanged 事件回来。
// - 配置由协调器自己持有（macOS 是 ConfigController），改动后发 ConfigChanged，由执行者延迟写盘。
// - 激活与最小化是效果，结果以前台事件与下一轮轮询回来；协调器不追踪激活的序号。
//
// 分成三个文件：这里是状态、事件分发与重算；actions.rs 是缩略图、右键菜单与托盘的动作；
// hotkeys.rs 是热键的规划与执行。

//! 事件驱动的协调器。

mod actions;
mod hotkeys;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap, HashSet};

use eveo_core::clients::ClientRegistry;
use eveo_core::clients::selector::main_windows;
use eveo_core::config::normalized;
use eveo_core::geometry::ScreenInfo;
use eveo_core::hotkeys::HotkeyPlan;
use eveo_core::model::{AppConfig, Profile, RegistryDiff, ThumbnailLayout, WindowId, WindowInfo};
use eveo_core::planning::{
    FrontmostContext, PlannerInput, SessionState, ThumbnailPlan, ThumbnailPresentation, ThumbnailStatus, plan,
};

use crate::event::{Effect, Event, ForegroundOwner};

/// 上一次发给缩略图窗口管理器的内容，用来跳过没有变化的 `ApplyPresentations`。
type Applied = (Vec<ThumbnailPresentation>, Vec<WindowId>, HashSet<WindowId>);

/// 应用的协调器。全部方法在主线程调用；时间都是单调时钟的秒数，由调用方传入。
#[derive(Debug)]
pub struct Coordinator {
    /// 当前配置，总是经过校验，至少有一个配置方案。
    config: AppConfig,
    /// 客户端登记。
    registry: ClientRegistry,
    /// 不持久化的会话状态。
    session: SessionState,
    /// 平台层报告的前台归属；客户端列表变化后要按它重新换算 `frontmost`。
    foreground: ForegroundOwner,
    /// 规划器用的前台情况。
    frontmost: FrontmostContext,
    /// 屏幕列表。
    screens: Vec<ScreenInfo>,
    /// 每个窗口的 DWM 缩略图状态；只记仍存在的客户端。
    thumbnail_states: HashMap<WindowId, ThumbnailStatus>,
    /// 当前热键规划。注册用的规划与回调查找用的规划必须是同一份，只有 `rebuild_hotkeys` 改它。
    hotkey_plan: HotkeyPlan,
    /// 最近一次告诉热键服务的「前台是 EVE 客户端」；`None` 表示还没告诉过。
    game_foreground: Option<bool>,
    /// 最近一次规划的结果，供右键菜单、拖动上下文等查询。
    last_plan: ThumbnailPlan,
    /// 最近一次发出的呈现，没变时不再发。
    last_applied: Option<Applied>,
    /// 最近一次安排的唤醒时刻，没变时不再发。
    scheduled_wake: Option<f64>,
    /// 本次 `handle` 里有事件要求重算。
    needs_replan: bool,
    /// 收到退出后为真，之后的事件全部忽略。
    stopped: bool,
    /// 当前事件的时刻。
    now: f64,
    /// 本次 `handle` 累积的效果。
    effects: Vec<Effect>,
}

impl Coordinator {
    /// 用读入的配置与当前屏幕建协调器。配置先经过校验；热键与第一次规划等到 `Event::Started`。
    pub fn new(config: AppConfig, screens: Vec<ScreenInfo>) -> Self {
        Self {
            config: normalized(config).config,
            registry: ClientRegistry::new(),
            session: SessionState::default(),
            foreground: ForegroundOwner::Nobody,
            frontmost: FrontmostContext::Other,
            screens,
            thumbnail_states: HashMap::new(),
            hotkey_plan: HotkeyPlan::default(),
            game_foreground: None,
            last_plan: ThumbnailPlan::default(),
            last_applied: None,
            scheduled_wake: None,
            needs_replan: false,
            stopped: false,
            now: 0.0,
            effects: Vec::new(),
        }
    }

    /// 处理一个事件，返回要执行的效果。`now` 是事件发生时的单调时钟秒数。
    pub fn handle(&mut self, event: Event, now: f64) -> Vec<Effect> {
        if self.stopped {
            return Vec::new();
        }
        self.now = now;
        self.dispatch(event);
        // 退出时不再重算：重算会重建刚要销毁的缩略图窗口。
        if self.needs_replan && !self.stopped {
            self.replan();
        }
        self.needs_replan = false;
        std::mem::take(&mut self.effects)
    }

    // MARK: 查询

    /// 当前配置。
    pub fn config(&self) -> &AppConfig {
        &self.config
    }

    /// 当前配置方案。校验保证至少有一个配置方案。
    pub fn profile(&self) -> &Profile {
        self.config
            .active_profile()
            .expect("校验后的配置至少有一个配置方案")
    }

    /// 会话状态。
    pub fn session(&self) -> &SessionState {
        &self.session
    }

    /// 客户端登记。
    pub fn registry(&self) -> &ClientRegistry {
        &self.registry
    }

    /// 规划器用的前台情况。
    pub fn frontmost(&self) -> FrontmostContext {
        self.frontmost
    }

    /// 当前热键规划（设置窗口据它的 `issues` 在热键旁提示）。
    pub fn hotkey_plan(&self) -> &HotkeyPlan {
        &self.hotkey_plan
    }

    /// 最近一次规划的结果。
    pub fn last_plan(&self) -> &ThumbnailPlan {
        &self.last_plan
    }

    /// 是否已收到退出。
    pub fn is_stopped(&self) -> bool {
        self.stopped
    }

    // MARK: 事件分发

    /// 按事件更新状态。需要重算的事件设 `needs_replan`。
    fn dispatch(&mut self, event: Event) {
        match event {
            Event::Started => {
                self.rebuild_hotkeys(true);
                self.push_game_foreground();
                self.effects.push(Effect::PollNow);
                self.needs_replan = true;
            }
            Event::WindowsPolled(candidates) => self.windows_polled(&candidates),
            Event::ForegroundChanged(owner) => {
                self.foreground = owner;
                self.refresh_frontmost();
                self.needs_replan = true;
            }
            Event::ScreensChanged(screens) => {
                self.screens = screens;
                self.needs_replan = true;
            }
            Event::ThumbnailStatusChanged { id, status } => {
                // 已消失的窗口不再记录，否则状态表里会留下永远不清的条目。
                if self.registry.client_with_id(id).is_some()
                    && self.thumbnail_states.get(&id) != Some(&status)
                {
                    self.thumbnail_states.insert(id, status);
                    self.needs_replan = true;
                }
            }
            Event::Wake => {
                // 安排的时刻已过，下次规划给出同一时刻也要重新安排。
                self.scheduled_wake = None;
                self.needs_replan = true;
            }
            Event::HotkeyFired(id) => self.hotkey_fired(id),
            Event::ThumbnailClicked(id) => self.thumbnail_clicked(id),
            Event::ThumbnailMinimizeRequested(id) => self.minimize(id),
            Event::HoverChanged { id, hovering } => self.hover_changed(id, hovering),
            Event::DragBegan(id) => {
                self.session.interacting_windows.insert(id);
                self.needs_replan = true;
            }
            Event::DragEnded { id, frame } => self.drag_ended(id, frame),
            Event::DragCancelled(id) => {
                self.session.interacting_windows.remove(&id);
                self.needs_replan = true;
            }
            Event::ContextMenu { id, action } => self.context_menu_action(id, action),
            Event::Tray(action) => self.tray_action(action),
            Event::ConfigEdited(config) => self.update_config(|draft| *draft = config),
        }
    }

    /// 一轮枚举：选主窗口、更新登记、清掉消失窗口的状态，再按新的客户端列表重新判断前台。
    fn windows_polled(&mut self, candidates: &[WindowInfo]) {
        // 同一进程可能有多个候选窗口（启动器、崩溃对话框），先按标题与尺寸选出主窗口。
        let diff = self.registry.update(&main_windows(candidates));
        if !diff.is_empty() {
            self.apply_registry_diff(&diff);
        }
        self.refresh_frontmost();
        self.needs_replan = true;
    }

    /// 清掉已消失窗口的会话状态。
    fn apply_registry_diff(&mut self, diff: &RegistryDiff) {
        for client in &diff.removed {
            self.thumbnail_states.remove(&client.id);
            self.session.interacting_windows.remove(&client.id);
            if self.session.hovered_window == Some(client.id) {
                self.session.hovered_window = None;
            }
            self.session.combat_alerts.remove(&client.id);
        }
    }

    /// 由前台归属换算规划器用的前台情况，并按架构文档 7.2 节更新 `last_eve_context_at`：
    /// 前台仍在 EVE 环境内时更新；从 EVE 环境变成其他应用的那一刻也记一次，
    /// 「离开 EVE 时隐藏」的延迟从这一刻算起。
    fn refresh_frontmost(&mut self) {
        let previous = self.frontmost;
        self.frontmost = match self.foreground {
            ForegroundOwner::SelfApp => FrontmostContext::SelfApp,
            ForegroundOwner::Process(pid) if self.registry.client_with_pid(pid).is_some() => {
                FrontmostContext::Client(pid)
            }
            ForegroundOwner::Process(_) | ForegroundOwner::Nobody => FrontmostContext::Other,
        };
        if is_eve_context(self.frontmost) || is_eve_context(previous) {
            self.session.last_eve_context_at = self.now;
        }
        self.push_game_foreground();
    }

    // MARK: 配置

    /// 修改配置：校验后与当前比较，变了才采用，然后处理变化并通知执行者写盘。
    fn update_config(&mut self, body: impl FnOnce(&mut AppConfig)) {
        // 在副本上改，校验后再比较：校验可能把越界的值夹回去，结果与当前相同时什么都不做。
        let mut draft = self.config.clone();
        body(&mut draft);
        let next = normalized(draft).config;
        if next == self.config {
            return;
        }
        let old = std::mem::replace(&mut self.config, next);
        // 切换配置方案时清空跳过名单与悬停（跳过名单按角色名记，换了方案就不再有意义）。
        if old.active_profile_id != self.config.active_profile_id {
            self.session.skipped_characters.clear();
            self.session.hovered_window = None;
        }
        self.rebuild_hotkeys(false);
        self.effects.push(Effect::ConfigChanged(self.config.clone()));
        self.needs_replan = true;
    }

    /// 修改当前配置方案，是 `update_config` 的简写。
    fn update_profile(&mut self, body: impl FnOnce(&mut Profile)) {
        self.update_config(|config| {
            if let Some(profile) = config.active_profile_mut() {
                body(profile);
            }
        });
    }

    // MARK: 重算

    /// 由当前状态算出呈现，发出呈现、写盘与唤醒的效果。
    fn replan(&mut self) {
        let now = self.now;
        // 前台仍在 EVE 环境内时持续更新时刻（离开的那一刻由 refresh_frontmost 记下）。
        match self.frontmost {
            FrontmostContext::Client(pid) => {
                self.session.last_eve_context_at = now;
                self.session.last_active_pid = Some(pid);
            }
            FrontmostContext::SelfApp => self.session.last_eve_context_at = now,
            FrontmostContext::Other => {}
        }
        // 先删掉到期的战斗提醒，规划器与之后的状态里只留未到期的项。
        self.session.combat_alerts.retain(|_, alert| alert.is_active(now));
        let plan = plan(&PlannerInput {
            clients: self.registry.clients(),
            frontmost: self.frontmost,
            profile: self.profile(),
            session: &self.session,
            screens: &self.screens,
            thumbnail_states: &self.thumbnail_states,
            now,
        });
        let visible: HashSet<WindowId> = plan
            .presentations
            .iter()
            .filter(|p| p.is_visible)
            .map(|p| p.id)
            .collect();
        // 悬停的缩略图被隐藏后收不到离开事件，这里清掉悬停，否则它再出现时仍是放大、不透明的样子。
        if self
            .session
            .hovered_window
            .is_some_and(|id| !visible.contains(&id))
        {
            self.session.hovered_window = None;
        }
        // 拖动中的缩略图被隐藏或已消失时清掉交互状态，否则以后规划给的 frame 永远不会应用到它上面。
        self.session.interacting_windows.retain(|id| visible.contains(id));

        // 与上一次发出的内容比较，没变就不发：兜底轮询每秒一次，大多数时候什么都没变。
        let applied = (
            plan.presentations.clone(),
            plan.thumbnails.clone(),
            self.session.interacting_windows.clone(),
        );
        if self.last_applied.as_ref() != Some(&applied) {
            let (presentations, thumbnails, interacting) = applied.clone();
            self.effects.push(Effect::ApplyPresentations {
                presentations,
                thumbnails,
                interacting,
            });
            self.last_applied = Some(applied);
        }
        // 先存下规划，再写自动布局：写配置会读当前配置方案，不能同时借着规划。
        let to_persist = plan.layouts_to_persist.clone();
        let wake = plan.next_wake_at;
        self.last_plan = plan;
        self.persist_auto_layouts(to_persist);
        if wake != self.scheduled_wake {
            self.scheduled_wake = wake;
            self.effects.push(Effect::ScheduleWake(wake));
        }
    }

    /// 把自动排位的结果写进当前配置方案。规划器在写入前每次都会返回它们，
    /// 所以只写配置里还没有的角色，写入后下一次规划就不再返回。
    fn persist_auto_layouts(&mut self, layouts: BTreeMap<String, ThumbnailLayout>) {
        let existing = &self.profile().layouts;
        let missing: Vec<_> = layouts
            .into_iter()
            .filter(|(name, _)| !existing.contains_key(name))
            .collect();
        if missing.is_empty() {
            return;
        }
        self.update_profile(|profile| {
            for (name, layout) in missing {
                profile.layouts.entry(name).or_insert(layout);
            }
        });
        // update_config 设了 needs_replan，但本轮重算已经结束；写入的位置与刚才的规划相同，不用再算。
        self.needs_replan = false;
    }
}

/// 前台是 EVE 客户端或本应用（「在 EVE 环境内」，见架构文档 4.3 节）。
fn is_eve_context(context: FrontmostContext) -> bool {
    !matches!(context, FrontmostContext::Other)
}
