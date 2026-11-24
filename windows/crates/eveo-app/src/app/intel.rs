// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译浮窗、聊天日志的接线，对应 macOS 的 AppCoordinator+ChatOverlays 与 ChatFeatureController 里碰平台的部分
// （docs/macos/design-intel-translate.md 9.2、9.3 节）。决定都在 eveo-app-core 里做（总控 ChatFeatures、
// 协调器的浮窗规划），这里只执行：
// - 跟踪服务：总控要求开始、重建或停止时建或丢掉 ChatLogTailer；50 毫秒的定时器取走它的消息交给总控。
// - 星图数据：总控第一次要求时开一个后台线程读（嵌进 exe 的数据与用户的覆盖文件），读完经通道交回。
// - 浮窗：协调器的 ApplyOverlays 交给 InfoOverlays；内容变了（新消息、换角色、按时间刷新）直接把新内容
//   交给可见的浮窗，不触发协调器重算。拖动结束与改配置的菜单项交给协调器。
// - 拖动上下文：浮窗的输入处理在窗口过程里，那时应用可能正被借用，不能去问协调器；
//   所以每次规划后把各浮窗的上下文算好放进共享的表，按下鼠标时直接取。
//
// 时钟：日志时间、「多久以前」与人名核对的节流用墙上时钟（1970 年以来的秒数）；协调器用单调时钟，两者不混用。
// 隐私：消息正文、说话人、人名与链接都不写进任何日志。

//! 预警浮窗与聊天日志。

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver};
use std::time::{SystemTime, UNIX_EPOCH};

use eveo_app_core::chat::features::{ChatFeatures, StaticDataLoad, TailerCommand};
use eveo_app_core::chat::intel::IntelController;
use eveo_app_core::chat::static_file;
use eveo_app_core::chat_log::{ChatLogMessage, ChatLogTailer};
use eveo_app_core::paths::DataPaths;
use eveo_app_core::pilots::PilotLookupService;
use eveo_app_core::pilots::store::PilotNameStore;
use eveo_app_core::{DragContext, Event};
use eveo_core::chat_log::ChatLogStatus;
use eveo_core::geometry::{ScreenPoint, ScreenRect};
use eveo_core::model::AppLanguage;
use eveo_core::overlay::OverlayKind;
use eveo_core::overlay::planner::OverlayPresentation;
use eveo_platform_win::{esi, menu, shell};

use super::alerts::automatic_directory;
use super::translation::{self, TranslationPage};
use super::{App, Runtime};
use crate::menus::{self, OverlayChoice};
use crate::overlays::{DragContextProvider, InfoOverlays, OverlayEvent};

/// 嵌进 exe 的星图数据（shared/static/eve-static.json，约 755 KB）。
const EMBEDDED_STATIC_DATA: &str = include_str!("../../../../../shared/static/eve-static.json");

/// 墙上时钟的秒数（1970 年以来）。系统时间早于 1970 年时记 0，只会让「多久以前」显示得不对，不会出错。
pub(super) fn wall_clock() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// 预警浮窗与聊天日志的运行状态。
pub(super) struct ChatRuntime {
    /// 总控（含预警与翻译功能）。
    pub(super) features: ChatFeatures,
    /// 「翻译」页只给显示用的状态（Key 的失败说明、测试结果）。
    pub(super) translation_page: TranslationPage,
    /// 聊天日志的跟踪服务；功能都关着时为 None。
    tailer: Option<ChatLogTailer>,
    /// 读星图数据的后台线程交回结果的通道；没在读时为 None。
    static_data: Option<Receiver<StaticDataLoad>>,
    /// 用户覆盖的星图数据文件（数据目录下的 eve-static.json）。
    static_override: PathBuf,
    /// 浮窗。
    overlays: InfoOverlays,
    /// 各浮窗的拖动上下文，规划后算好；按下鼠标时浮窗的输入处理从这里取。
    drag_contexts: Rc<RefCell<BTreeMap<OverlayKind, DragContext>>>,
    /// 下一次按时间刷新浮窗的时刻（墙上时钟）；不用时为 None。
    refresh_at: Option<f64>,
}

impl ChatRuntime {
    /// 建运行状态：人名核对用 ESI，缓存放在 cache 目录；浮窗按需建，跟踪服务等配置交来再开。
    pub(super) fn new(paths: &DataPaths, language: AppLanguage) -> Self {
        let version = env!("CARGO_PKG_VERSION");
        let resolver = Box::new(move |names: &[String]| esi::resolve(names, version).result);
        let pilots = PilotLookupService::new(PilotNameStore::in_dir(&paths.cache_dir()), resolver);
        // 手动位置（state.json）还没有设置界面，先从空表开始；接上「预警」页的位置一栏时再读写。
        let intel = IntelController::new(BTreeMap::new(), Some(pilots));
        let drag_contexts: Rc<RefCell<BTreeMap<OverlayKind, DragContext>>> = Rc::default();
        let table = drag_contexts.clone();
        // 按下时把起点换成浮窗当前的 frame（拖动中被规划改过之前的位置以浮窗为准）；边缘判断用同一个 frame。
        let provider: DragContextProvider = Rc::new(move |kind: OverlayKind, frame: ScreenRect| {
            let mut context = table.borrow().get(&kind).cloned()?;
            context.start_frame = frame;
            context.edge_frame = frame;
            Some(context)
        });
        Self {
            features: ChatFeatures::new(intel, language).with_translation(translation::controller(paths)),
            translation_page: TranslationPage::default(),
            tailer: None,
            static_data: None,
            static_override: paths.config_file().with_file_name(static_file::FILE_NAME),
            overlays: InfoOverlays::new(language, provider),
            drag_contexts,
            refresh_at: None,
        }
    }
}

impl App {
    /// 配置变了（含启动时的第一次）：交给总控，按它的要求开始、重建或停止跟踪，必要时开始读星图数据，
    /// 然后刷新可见的浮窗（频道、开关与「保留最近」都可能影响内容）。
    pub(super) fn chat_config_changed(&mut self) {
        let now = wall_clock();
        let config = self.coordinator.config().clone();
        match self.chat.features.apply(&config, now) {
            Some(TailerCommand::Start(request)) => {
                // 先丢掉旧服务（停掉它的线程），新服务从头定起点并补读。
                self.chat.tailer = None;
                // 线程建不出来（系统资源耗尽）时按停止处理，下次配置变化再试。
                self.chat.tailer = ChatLogTailer::start(request, &automatic_directory()).ok();
            }
            Some(TailerCommand::Stop) => {
                self.chat.tailer = None;
                self.chat.features.status_changed(ChatLogStatus::Stopped, now);
            }
            None => {}
        }
        if self.chat.features.take_static_data_request() {
            self.load_static_data();
        }
        self.show_chat_status();
        self.refresh_overlays(None);
    }

    /// 聊天日志的跟踪状态，填设置窗口的预警页时用。
    pub(super) fn chat_log_status(&self) -> &ChatLogStatus {
        self.chat.features.chat_log_status()
    }

    /// 设置窗口开着时刷新预警页的状态行（聊天日志的跟踪状态）。
    fn show_chat_status(&self) {
        if let Some(window) = &self.settings {
            eveo_ui::chat::show_intel_status(window, self.chat.features.chat_log_status());
        }
    }

    /// 界面语言变了：浮窗的固定文字与各行的用语都换成新语言。
    pub(super) fn chat_language_changed(&mut self) {
        self.chat.overlays.set_language(self.language);
        self.chat.features.set_language(self.language, wall_clock());
        self.show_chat_status();
        self.refresh_overlays(None);
    }

    /// 协调器的浮窗规划：建、移、显示或隐藏浮窗，换活动角色；这一次才变成可见的浮窗补一次内容
    /// （不可见时内容更新被跳过了），换了活动角色时全部可见的浮窗都换内容。
    pub(super) fn apply_overlays(&mut self, presentations: &[OverlayPresentation], active: Option<String>) {
        // 先记下之前可见的浮窗：新变成可见的要补一次内容。
        let before = self.chat.features.visible().clone();
        self.chat.overlays.apply(presentations, &self.screens);
        let after: BTreeSet<OverlayKind> = presentations
            .iter()
            .filter(|p| p.is_visible)
            .map(|p| p.kind)
            .collect();
        self.chat.features.set_visible(after.clone());
        let character_changed = self.chat.features.set_active_character(active, wall_clock());
        let stale: BTreeSet<OverlayKind> = after
            .into_iter()
            .filter(|kind| character_changed || !before.contains(kind))
            .collect();
        self.refresh_overlays(Some(&stale));
        self.update_overlay_drag_contexts();
    }

    /// 重算各浮窗的拖动上下文（吸附目标随缩略图与另一个浮窗的位置变化）。在每次缩略图或浮窗的规划之后调用。
    pub(super) fn update_overlay_drag_contexts(&self) {
        let contexts = self
            .coordinator
            .overlay_presentations()
            .iter()
            .filter_map(|p| Some((p.kind, self.coordinator.overlay_drag_context(p.kind)?)))
            .collect();
        *self.chat.drag_contexts.borrow_mut() = contexts;
    }

    /// 定时器里调用：取走跟踪服务的消息、星图数据与人名核对的结果、浮窗的事件，并按时间刷新。
    pub(super) fn chat_tick(&mut self, runtime: &Rc<Runtime>) {
        let now = wall_clock();
        let mut stale = BTreeSet::new();
        let mut all = false;
        // 先取走全部消息再处理：处理中要可变借用总控，不能同时借着跟踪服务。
        let messages = self
            .chat
            .tailer
            .as_ref()
            .map(ChatLogTailer::drain)
            .unwrap_or_default();
        for message in messages {
            match message {
                ChatLogMessage::Events(events) => stale.extend(self.chat.features.events(events, now)),
                // 状态变了：浮窗的状态行要换。
                ChatLogMessage::Status(status) => {
                    if self.chat.features.status_changed(status, now) {
                        all = true;
                        // 预警页的状态行也跟着换。
                        self.show_chat_status();
                    }
                }
                // 跟踪的日志文件变了：翻译浮窗的状态行可能要提示（或不再提示）「EVE 没写这些频道的日志」。
                ChatLogMessage::Followed(followed) => {
                    if self.chat.features.followed_changed(followed, now) {
                        stale.insert(OverlayKind::Translation);
                    }
                }
            }
        }
        if let Some(receiver) = &self.chat.static_data
            && let Ok(result) = receiver.try_recv()
        {
            self.chat.static_data = None;
            self.chat.features.static_data_loaded(result, now);
            all = true;
        }
        stale.extend(self.chat.features.tick(now));
        // 翻译：测试结果换成页面上的文字；日志行在诊断日志接上之前丢掉（只有条数与状态码）。
        self.take_translation_test();
        if let Some(translation) = self.chat.features.translation_mut() {
            translation.take_log_lines();
        }
        self.show_translation_page();
        // 「多久以前」与过期清理：到点时刷新全部可见的浮窗，refresh_overlays 会重新安排下一次。
        if self.chat.refresh_at.is_some_and(|at| now >= at) {
            all = true;
        }
        if all {
            self.refresh_overlays(None);
        } else if !stale.is_empty() {
            self.refresh_overlays(Some(&stale));
        }
        // 浮窗的事件最后处理：菜单是模态的，弹出期间消息循环照常转，放在最后不会耽误上面的刷新。
        for event in self.chat.overlays.drain_events() {
            self.overlay_event(event, runtime);
        }
    }

    /// 应用退出：停掉人名核对（有改动时同步存盘）与跟踪服务。
    pub(super) fn chat_stop(&mut self) {
        self.chat.features.stop(wall_clock());
        self.chat.tailer = None;
    }

    /// 「翻译」页的按钮改了翻译的内容（Key、重试、清空缓存）：刷新翻译浮窗。
    pub(super) fn refresh_translation_overlay(&mut self) {
        self.refresh_overlays(Some(&BTreeSet::from([OverlayKind::Translation])));
    }

    /// 把新内容交给可见的浮窗：kinds 为 None 时是全部可见的浮窗，否则只刷新其中可见的那些。
    /// 刷新后重新安排按时间的刷新。
    fn refresh_overlays(&mut self, kinds: Option<&BTreeSet<OverlayKind>>) {
        let now = wall_clock();
        let visible = self.chat.features.visible().clone();
        for kind in visible.iter().filter(|k| kinds.is_none_or(|set| set.contains(k))) {
            let content = self.chat.features.content(*kind, now);
            self.chat.overlays.set_content(*kind, &content);
        }
        self.chat.refresh_at = self.chat.features.next_refresh(now);
    }

    /// 开一个后台线程读星图数据；读完经通道交回，由定时器取走。线程建不出来时按缺失处理。
    fn load_static_data(&mut self) {
        // 环境变量在主线程上读（读一次即可），后台线程只管读文件与解码。
        let (sender, receiver) = mpsc::channel();
        let environment = std::env::var_os(static_file::ENVIRONMENT_VARIABLE)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from);
        let user_override = self.chat.static_override.clone();
        let spawned = std::thread::Builder::new()
            .name("static-data".to_owned())
            .spawn(move || {
                let result = static_file::load(environment.as_deref(), &user_override, EMBEDDED_STATIC_DATA);
                // 应用已退出、通道已丢时发送失败，结果也就不需要了。
                let _ = sender.send(result);
            });
        match spawned {
            Ok(_) => self.chat.static_data = Some(receiver),
            Err(_) => {
                self.chat
                    .features
                    .static_data_loaded(StaticDataLoad::Missing, wall_clock());
            }
        }
    }

    /// 处理浮窗报来的一个事件。
    fn overlay_event(&mut self, event: OverlayEvent, runtime: &Rc<Runtime>) {
        match event {
            OverlayEvent::DragEnded(kind, frame) => {
                self.send(Event::OverlayDragEnded { kind, frame }, runtime)
            }
            OverlayEvent::Menu { kind, point, row } => self.overlay_menu(kind, point, row, runtime),
            // 拖动开始与取消只影响浮窗自己（它不让规划改正在拖动的浮窗），协调器不需要知道。
            OverlayEvent::DragBegan(_) | OverlayEvent::DragCancelled(_) => {}
        }
    }

    /// 在光标处弹出浮窗的右键菜单并执行选中的一项。
    fn overlay_menu(
        &mut self,
        kind: OverlayKind,
        point: ScreenPoint,
        row: Option<usize>,
        runtime: &Rc<Runtime>,
    ) {
        // 光标下那一行在弹菜单前取一份：菜单弹出期间新消息可能到来，行号会指向别的消息。
        let line = row.and_then(|row| self.chat.overlays.line(kind, row));
        let locked = self.coordinator.profile().behavior.lock_layout;
        let entries = menus::overlay_menu(locked, line.as_ref(), self.language);
        let chosen = menu::popup(self.tray.hwnd(), point, &entries);
        let Some(choice) = chosen
            .ok()
            .flatten()
            .and_then(|id| menus::overlay_choice(id, line.as_ref()))
        else {
            return;
        };
        match choice {
            OverlayChoice::ScrollToLatest => self.chat.overlays.scroll_to_latest(kind),
            // 剪贴板被别的程序占着时放不进去；没有可提示的地方，用户再点一次即可。
            OverlayChoice::Copy(text) => {
                let _ = shell::copy_text(self.tray.hwnd(), &text);
            }
            OverlayChoice::Open(url) => {
                shell::open_url(&url);
            }
            OverlayChoice::Clear => {
                if self.chat.features.clear(kind) {
                    self.refresh_overlays(Some(&BTreeSet::from([kind])));
                }
            }
            OverlayChoice::Coordinator(action) => self.send(Event::OverlayMenu { kind, action }, runtime),
        }
    }
}
