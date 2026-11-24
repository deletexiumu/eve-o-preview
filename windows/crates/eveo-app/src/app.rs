// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用的主体：启动、主循环与效果的执行（架构文档 3.2 节、3.3 节）。
//
// 线程：全部在主线程上。主循环是 Slint 的事件循环；原生窗口（热键窗口、托盘窗口、缩略图窗口）的消息
// 也由它分发。WinEvent 钩子的事件进本线程的队列，由 50 毫秒一次的定时器取走；同一个定时器负责
// 兜底轮询（默认每秒一次，有窗口事件时提前）、隐藏延迟的唤醒与配置的延迟写盘。
//
// 重入：弹出菜单、激活窗口等调用期间系统会分发别的消息，窗口过程里的回调可能在应用正被借用时到来。
// 所以回调只把输入放进队列（Runtime::post）；正在处理时直接返回，由外层的处理循环接着取。

use std::cell::RefCell;
use std::collections::VecDeque;
use std::process::ExitCode;
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant};

use eveo_app_core::config_store::{ConfigWarning, JsonFileConfigStore, default_config};
use eveo_app_core::game_log::GameLogTailer;
use eveo_app_core::gesture::{Button, GestureOutput, Modifiers};
use eveo_app_core::paths::DataPaths;
use eveo_app_core::{Coordinator, Effect, Event, ForegroundOwner, SettingsPage};
use eveo_core::combat_log::CombatLogStatus;
use eveo_core::geometry::ScreenInfo;
use eveo_core::layout::ResizeEdges;
use eveo_core::model::{AppLanguage, Pid, WindowId};
use eveo_platform_win::discovery::{ClientFilter, candidate_windows};
use eveo_platform_win::events::{
    WindowEvent, WindowEventHooks, foreground_window, local_timestamp, window_pid,
};
use eveo_platform_win::hotkey::{HotkeyMessage, HotkeyWindow};
use eveo_platform_win::process::current_process_elevated;
use eveo_platform_win::recorder::HotkeyRecorder;
use eveo_platform_win::thumbnail::{CursorShape, MouseButton, ThumbnailInput};
use eveo_platform_win::tray::{TrayEvent, TrayIcon};
use eveo_platform_win::{activation, appearance, menu, screens, single_instance};
use eveo_ui::{bind, switching};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use slint::ComponentHandle;
use windows::Win32::Foundation::HWND;

use crate::hotkeys::HotkeyService;
use crate::menus;
use crate::thumbnails::ThumbnailManager;

mod alerts;
mod chat;
mod environment;
mod general;
mod intel;
mod profiles;
mod shell;
mod switching_page;
mod translation;

/// 定时器的周期：取窗口事件、检查轮询、唤醒与写盘。
const TICK: Duration = Duration::from_millis(50);
/// 兜底轮询的间隔（架构文档 4.1 节的 pollIntervalMs 默认值）。
const POLL_INTERVAL: Duration = Duration::from_millis(1000);
/// 有窗口事件时，两次轮询之间至少隔这么久，避免客户端窗口连续移动时每 50 毫秒枚举一次。
const EVENT_POLL_SPACING: Duration = Duration::from_millis(150);
/// 设置窗口的首选尺寸（逻辑像素），与 settings.slint 的 preferred-width、preferred-height 相同。
const SETTINGS_SIZE: (f64, f64) = (1040.0, 760.0);
/// 配置改动后延迟多久写盘，连续改动合并成一次（与 macOS 的 ConfigController 相同）。
const SAVE_DELAY: Duration = Duration::from_millis(500);

/// 送进应用的输入。
enum Input {
    /// 直接交给协调器的事件。
    Event(Event),
    /// 缩略图窗口的鼠标输入。
    Thumbnail(WindowId, ThumbnailInput),
    /// 热键窗口的消息。
    Hotkey(HotkeyMessage),
    /// 托盘与单实例唤醒。
    Tray(TrayEvent),
    /// 定时器。
    Tick,
    /// 设置窗口里改了值：读回整页，组成新配置交给协调器。
    SettingsEdited,
    /// 设置窗口的「统一尺寸」按钮。
    UnifySizes,
    /// 「客户端」页上对某个角色的改动。
    ClientEdit(bind::ClientEdit),
    /// 「客户端」页的「全部隐藏」开关，值是用户要的新状态。
    HideAll(bool),
    /// 「切换与热键」页上的改动。
    SwitchingEdit(switching::SwitchingEdit),
    /// 「切换与热键」页的录制按钮（位置标识、原文；新增时原文为空串）。
    Record(String, String),
    /// 「配置方案」页的操作。
    Profiles(profiles::ProfilesInput),
    /// 「通用」与「关于」页的操作。
    General(general::GeneralInput),
    /// 「提醒」页的操作。
    Alerts(alerts::AlertsInput),
    /// 「预警」与「翻译」页的输入。
    Chat(chat::ChatInput),
    /// 「翻译」页的按钮（Key、测试、重试、清空缓存）。
    Translation(translation::TranslationAction),
    /// 「环境检查」页的按钮。
    Environment(environment::EnvironmentInput),
}

/// 应用与它的输入队列。回调持有它的弱引用。
struct Runtime {
    /// 等待处理的输入。
    queue: RefCell<VecDeque<Input>>,
    /// 应用本身。
    app: RefCell<App>,
}

impl Runtime {
    /// 放进一个输入并尽量立即处理。应用正在处理别的输入（重入）时只排队，由外层循环接着处理。
    fn post(self: &Rc<Self>, input: Input) {
        self.queue.borrow_mut().push_back(input);
        let Ok(mut app) = self.app.try_borrow_mut() else {
            return;
        };
        loop {
            let next = self.queue.borrow_mut().pop_front();
            let Some(input) = next else {
                break;
            };
            app.input(input, self);
        }
    }
}

/// 应用的状态：协调器与各平台服务。
struct App {
    /// 协调器。
    coordinator: Coordinator,
    /// 配置文件。
    store: JsonFileConfigStore,
    /// 配置能否写盘：读配置失败（新版本的文件、读文件出错）时本次会话不写，避免覆盖用户的文件。
    writable: bool,
    /// 下次写盘的时刻。
    save_at: Option<Instant>,
    /// 单调时钟的起点，协调器的时间从这里算起。
    started: Instant,
    /// 协调器要求的唤醒时刻（单调时钟秒数）。
    wake_at: Option<f64>,
    /// 下次轮询的时刻。
    poll_at: Instant,
    /// 上次轮询的时刻。
    polled_at: Instant,
    /// 最近一次读到的屏幕列表，变了才告诉协调器。
    screens: Vec<ScreenInfo>,
    /// 最近一次告诉协调器的前台归属，没变不再报。
    foreground: Option<ForegroundOwner>,
    /// 本进程的 PID，用来认出前台是不是自己的窗口。
    own_pid: u32,
    /// 客户端的判定条件。
    filter: ClientFilter,
    /// WinEvent 钩子。
    hooks: WindowEventHooks,
    /// 热键。
    hotkeys: HotkeyService,
    /// 缩略图窗口。
    thumbnails: ThumbnailManager,
    /// 托盘图标与主消息窗口。
    tray: TrayIcon,
    /// 设置窗口；第一次打开时建，关闭只是隐藏。
    settings: Option<eveo_ui::SettingsWindow>,
    /// 正在录制的热键：位置、被替换的原文（新增时为空串）与录制器。
    recording: Option<(switching::Slot, String, HotkeyRecorder)>,
    /// 日志文件夹，「通用」页显示它的位置。
    logs_dir: std::path::PathBuf,
    /// 设置窗口是否已经摆过初始位置（只在第一次显示时居中）。
    settings_placed: bool,
    /// 设置窗口显示后还没切到前台（见 focus_settings）。
    settings_focus_pending: bool,
    /// 界面语言：配置的选项求出的实际语言，配置变化时重新求（见 general::resolve_language）。
    language: AppLanguage,
    /// 本工具是否以管理员运行；启动时读一次，读不到按否处理（「环境检查」页）。
    self_elevated: bool,
    /// 上次轮询时以管理员运行的客户端进程（「环境检查」页）。
    elevated_pids: Vec<Pid>,
    /// 游戏日志的跟踪服务；战斗提醒关着时为 `None`。
    game_log: Option<GameLogTailer>,
    /// 跟踪服务最近报告的状态（「提醒」页的状态行）。
    combat_status: CombatLogStatus,
    /// 预警浮窗与聊天日志。
    chat: intel::ChatRuntime,
}

/// 启动应用，跑主循环直到退出。
pub fn run() -> ExitCode {
    // 先声明每显示器 DPI 感知：之后取到的屏幕、窗口与光标坐标都是物理像素，与 Core 的约定一致（4.6 节）。
    screens::enable_per_monitor_dpi();
    // 在第一次用 Slint 之前装好应用的平台（浮窗用离屏渲染）；装不上时 Slint 自己选默认后端，照常运行。
    let _ = crate::slint_platform::install();
    // 已有实例在运行：让它打开设置窗口，本实例退出。
    let Some(_guard) = single_instance::acquire() else {
        single_instance::notify_primary();
        return ExitCode::SUCCESS;
    };
    // `--background` 是开机启动时带的参数：第一次运行也不弹设置窗口。
    let background = std::env::args().any(|a| a == "--background");
    // 极少数环境没有 APPDATA（例如以服务账户运行）时退回当前目录，至少能运行。
    let paths = DataPaths::from_env().unwrap_or_else(|| DataPaths::new(".", None));
    let store = JsonFileConfigStore::new(paths.config_file());
    let (config, writable, first_run) = match store.load(&local_timestamp()) {
        Ok(result) => {
            let first_run = result.warnings.contains(&ConfigWarning::CreatedDefault);
            (result.config, true, first_run)
        }
        // 新版本的配置或读文件失败：用默认配置运行，本次会话不写盘，避免覆盖用户的文件。
        Err(_) => (default_config(), false, false),
    };

    let screens = screens::screens();
    // 热键窗口与托盘窗口是应用能运行的前提；建不了（系统资源耗尽）时直接退出。
    let (Ok(hotkey_window), Ok(tray)) = (HotkeyWindow::create(), TrayIcon::create("EVE-O Preview")) else {
        return ExitCode::FAILURE;
    };
    let now = Instant::now();
    let language = general::resolve_language(&config.general);
    let mut thumbnails = ThumbnailManager::default();
    thumbnails.set_language(language);
    let app = App {
        coordinator: Coordinator::new(config, screens.clone()),
        store,
        writable,
        // 第一次运行时把默认配置写下来，用户能在文件夹里找到它。
        save_at: first_run.then_some(now),
        started: now,
        wake_at: None,
        poll_at: now,
        polled_at: now,
        screens,
        foreground: None,
        own_pid: std::process::id(),
        filter: ClientFilter::default(),
        hooks: WindowEventHooks::install(),
        hotkeys: HotkeyService::new(hotkey_window),
        thumbnails,
        tray,
        settings: None,
        recording: None,
        logs_dir: paths.logs_dir(),
        settings_placed: false,
        settings_focus_pending: false,
        language,
        self_elevated: current_process_elevated().unwrap_or(false),
        elevated_pids: Vec::new(),
        game_log: None,
        combat_status: CombatLogStatus::Stopped,
        chat: intel::ChatRuntime::new(&paths, language),
    };
    let runtime = Rc::new(Runtime {
        queue: RefCell::new(VecDeque::new()),
        app: RefCell::new(app),
    });
    connect_callbacks(&runtime);

    // 启动：注册热键、第一次规划，并要求立即轮询（下一次定时器就会枚举窗口）。
    runtime.post(Input::Event(Event::Started));
    // 聊天日志按读入的配置开始（ConfigChanged 只在配置变化时才发，启动时要自己交一次）。
    runtime.app.borrow_mut().chat_config_changed();
    if first_run && !background {
        runtime.post(Input::Event(Event::Tray(eveo_app_core::TrayAction::OpenSettings)));
    }
    let timer = slint::Timer::default();
    {
        let weak = Rc::downgrade(&runtime);
        timer.start(slint::TimerMode::Repeated, TICK, move || {
            if let Some(runtime) = weak.upgrade() {
                runtime.post(Input::Tick);
            }
        });
    }
    // 没有任何 Slint 窗口时也要一直跑：托盘应用，关掉设置窗口不退出。
    let result = slint::run_event_loop_until_quit();
    timer.stop();
    // 退出：等待中的配置立即写盘，再销毁缩略图窗口（Drop 注销 DWM 缩略图）。热键与钩子随 App 释放。
    let mut app = runtime.app.borrow_mut();
    app.flush();
    app.chat_stop();
    app.thumbnails.clear();
    if result.is_ok() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// 给热键窗口与托盘设处理函数：只把输入放进队列。缩略图窗口的处理函数在建窗口时设。
fn connect_callbacks(runtime: &Rc<Runtime>) {
    let app = runtime.app.borrow();
    let weak = Rc::downgrade(runtime);
    app.hotkeys
        .set_handler(move |message| post(&weak, Input::Hotkey(message)));
    let weak = Rc::downgrade(runtime);
    app.tray.set_handler(move |event| post(&weak, Input::Tray(event)));
}

/// 运行时还在时放进一个输入。
fn post(weak: &Weak<Runtime>, input: Input) {
    if let Some(runtime) = weak.upgrade() {
        runtime.post(input);
    }
}

impl App {
    /// 协调器用的当前时刻。
    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// 处理一个输入。
    fn input(&mut self, input: Input, runtime: &Rc<Runtime>) {
        match input {
            Input::Event(event) => self.send(event, runtime),
            Input::Thumbnail(id, input) => self.thumbnail_input(id, input, runtime),
            Input::Hotkey(HotkeyMessage::Keyboard(raw)) => {
                if let Some(id) = self.hotkeys.decode(raw) {
                    self.send(Event::HotkeyFired(id), runtime);
                }
            }
            // 鼠标热键的编号就是绑定 id：匹配器的绑定随规划整份替换，不需要代数。
            Input::Hotkey(HotkeyMessage::Mouse(id)) => self.send(Event::HotkeyFired(id), runtime),
            // 托盘：右键弹菜单；左键与另一个实例的唤醒都打开设置窗口（Windows 托盘程序的习惯）。
            Input::Tray(TrayEvent::RightClick) => self.tray_menu(runtime),
            Input::Tray(TrayEvent::LeftClick | TrayEvent::ActivateRequested) => {
                self.open_settings(SettingsPage::General, runtime);
            }
            Input::Tick => self.tick(runtime),
            Input::SettingsEdited => self.settings_edited(false, runtime),
            Input::UnifySizes => self.settings_edited(true, runtime),
            Input::ClientEdit(edit) => self.client_edited(&edit, runtime),
            Input::SwitchingEdit(edit) => self.switching_edited(&edit, runtime),
            // 录制的结果不经回调，由定时器从录制器取（见 check_recording）。
            Input::Record(slot, text) => self.toggle_recording(&slot, text),
            Input::Profiles(input) => self.profiles_input(input, runtime),
            Input::General(input) => self.general_input(input, runtime),
            Input::Alerts(input) => self.alerts_input(input, runtime),
            Input::Chat(input) => self.chat_input(input, runtime),
            Input::Translation(action) => self.translation_action(action),
            Input::Environment(input) => self.environment_input(input),
            // 「全部隐藏」是协调器里的会话状态，只有切换动作；与现状相同时（例如热键刚切过）不再切。
            Input::HideAll(hide) => {
                if hide != self.coordinator.tray().hide_all {
                    self.send(Event::Tray(eveo_app_core::TrayAction::ToggleHideAll), runtime);
                }
            }
        }
    }

    /// 把事件交给协调器并执行它给出的效果。
    fn send(&mut self, event: Event, runtime: &Rc<Runtime>) {
        // 效果按顺序执行；执行中产生的新输入（缩略图状态等）排进队列，由 Runtime::post 的循环接着处理。
        let effects = self.coordinator.handle(event, self.now());
        for effect in effects {
            self.execute(effect, runtime);
        }
        self.refresh_settings_pages();
    }

    /// 设置窗口开着时刷新「客户端」与「切换与热键」两页（「预览与布局」页只随配置变化，在 ConfigChanged 里刷新）：
    /// 在线客户端、「全部隐藏」、热键规划与录制状态随时可能变。
    /// 每处理一个事件调一次；绑定层逐行比较，没变的行不碰，所以频繁调用也只是几次比较。
    fn refresh_settings_pages(&self) {
        let Some(window) = &self.settings else {
            return;
        };
        // 窗口关着时不刷新，下次打开时 open_settings 会整页填一次。
        if !window.window().is_visible() {
            return;
        }
        if let Some(profile) = self.coordinator.config().active_profile() {
            // 在线客户端取协调器的登记表，与缩略图用的是同一份，两边不会对不上。
            let clients = self.coordinator.registry().clients();
            bind::show_clients(window, profile, clients, self.coordinator.tray().hide_all);
            self.show_switching(window, profile);
        }
        self.show_profiles(window);
        self.show_privileges(window);
    }

    /// 填「配置方案」页：方案列表来自整份配置，路径是配置文件的位置。
    fn show_profiles(&self, window: &eveo_ui::SettingsWindow) {
        let path = self.store.path().display().to_string();
        eveo_ui::profiles::show_profiles(window, self.coordinator.config(), &path);
    }

    /// 填「切换与热键」页：热键规划的问题、注册失败项与录制状态一起交给绑定层。
    /// 注册失败项由热键服务记着（它最清楚哪些注册成功了），每次刷新时取一份。
    fn show_switching(&self, window: &eveo_ui::SettingsWindow, profile: &eveo_core::model::Profile) {
        let failed = self.hotkeys.failures();
        let state = switching::SwitchingState {
            clients: self.coordinator.registry().clients(),
            plan: self.coordinator.hotkey_plan(),
            failed: &failed,
            recording: self
                .recording
                .as_ref()
                .map(|(slot, text, _)| (slot.clone(), text.clone())),
        };
        switching::show_switching(window, profile, &state);
    }

    /// 执行一个效果。
    fn execute(&mut self, effect: Effect, runtime: &Rc<Runtime>) {
        match effect {
            Effect::ApplyPresentations {
                presentations,
                thumbnails,
                interacting,
            } => {
                let weak = Rc::downgrade(runtime);
                let changes =
                    self.thumbnails
                        .apply(&presentations, &thumbnails, &interacting, &self.screens, |id| {
                            let weak = weak.clone();
                            Box::new(move |input| post(&weak, Input::Thumbnail(id, input)))
                        });
                // 状态变化排进队列，本轮效果执行完后再交给协调器，不在 apply 中途重入。
                let mut queue = runtime.queue.borrow_mut();
                for (id, status) in changes {
                    queue.push_back(Input::Event(Event::ThumbnailStatusChanged { id, status }));
                }
                drop(queue);
                self.tray
                    .set_tooltip(&menus::tray_tooltip(&self.coordinator.tray(), self.language));
                // 浮窗吸附到缩略图：缩略图的位置变了，浮窗的拖动上下文跟着更新。
                self.update_overlay_drag_contexts();
            }
            Effect::ApplyOverlays {
                presentations,
                active_character,
            } => self.apply_overlays(&presentations, active_character),
            // 热键服务自己处理代数与作用范围，这里只转交。
            Effect::RegisterHotkeys(bindings) => self.hotkeys.replace(bindings),
            Effect::SetGameForeground(game) => self.hotkeys.set_game_foreground(game),
            // 配置变化：推迟写盘，连续改动（例如拖动后又改设置）只写一次。
            // 设置窗口开着时把新配置显示出来：改动可能来自拖动缩略图、托盘或热键，不只来自设置窗口。
            Effect::ConfigChanged(config) => {
                if self.writable {
                    self.save_at = Some(Instant::now() + SAVE_DELAY);
                }
                if let (Some(window), Some(profile)) = (&self.settings, config.active_profile()) {
                    bind::show_previews(window, profile);
                }
                // 界面语言可能变了（「通用」页的选项）：设置窗口的文字立即换成新语言。
                self.update_language();
                // 预警的开关、频道与「保留最近」可能变了：聊天日志的跟踪与浮窗的内容跟着变。
                self.chat_config_changed();
                // 「通用」「提醒」「预警」「翻译」页同样只随配置变化；「环境检查」页的日志目录可能改了。
                if let Some(window) = &self.settings {
                    self.show_general(window);
                    self.show_alerts(window);
                    self.show_chat(window);
                    self.show_environment(window);
                }
            }
            Effect::ScheduleWake(at) => self.wake_at = at,
            Effect::Activate(id) => {
                // 激活的结果以前台事件回来；客户端可能随之改了状态，提前轮询一次。
                let _ = activation::activate(id);
                self.poll_soon();
            }
            // 最小化后客户端窗口的状态（在屏、最小化）变了，同样提前轮询。
            Effect::Minimize(id) => {
                activation::minimize(id);
                self.poll_soon();
            }
            Effect::PollNow => self.poll_at = Instant::now(),
            Effect::OpenSettings(page) => self.open_settings(page, runtime),
            Effect::WatchGameLogs(directory) => self.watch_game_logs(directory.as_deref()),
            Effect::StopGameLogs => self.stop_game_logs(),
            // 退出：先写盘，再让主循环返回到 run() 的收尾。
            Effect::Quit => {
                self.flush();
                self.chat_stop();
                let _ = slint::quit_event_loop();
            }
        }
    }

    /// 定时器：取窗口事件，按时轮询、唤醒与写盘。
    fn tick(&mut self, runtime: &Rc<Runtime>) {
        // 钩子回调只把事件放进本线程的队列（回调里不能做重活），这里批量取走。
        for event in self.hooks.drain() {
            match event {
                // 前台变化直接报，不等轮询：「离开 EVE 时隐藏」的延迟从这一刻算起。
                WindowEvent::Foreground(window) => {
                    let owner = self.owner_of(Some(window));
                    self.report_foreground(owner, runtime);
                }
                // 出现、销毁、改名、最小化、还原与移动都可能改变客户端列表或它们的状态。
                _ => self.poll_soon(),
            }
        }
        // 设置窗口第一次显示时，原生窗口在这之后才出现，切到前台留到这里做。
        self.focus_settings();
        // 热键录制的结果：钩子回调只记下结果，这里取走并写进配置。
        self.check_recording(runtime);
        // 游戏日志的受击事件与状态：后台线程只放进通道，这里取走。
        self.drain_game_log(runtime);
        // 聊天日志、星图数据、人名核对与浮窗的事件，以及浮窗按时间的刷新。
        self.chat_tick(runtime);
        // 战斗提醒的闪烁随定时器逐帧推进（每 50 毫秒一帧）；没有提醒时立即返回。
        self.thumbnails.animate(self.now());
        let now = Instant::now();
        if now >= self.poll_at {
            self.poll(runtime);
        }
        // 唤醒用协调器的时钟（单调秒数）比较，与 ScheduleWake 给的时刻一致。
        if self.wake_at.is_some_and(|at| self.now() >= at) {
            self.wake_at = None;
            self.send(Event::Wake, runtime);
        }
        // 延迟写盘到点：期间又有改动时 save_at 已被推后，这里只写最后一份。
        if self.save_at.is_some_and(|at| now >= at) {
            self.flush();
        }
    }

    /// 枚举一次窗口，顺带核对屏幕与前台（事件可能丢）。
    fn poll(&mut self, runtime: &Rc<Runtime>) {
        let now = Instant::now();
        self.polled_at = now;
        self.poll_at = now + POLL_INTERVAL;
        // 显示器的增减与缩放变化没有专门的事件接进来，每次轮询比较一次；变了先报，规划用新屏幕。
        let screens = screens::screens();
        if screens != self.screens {
            self.screens = screens.clone();
            self.send(Event::ScreensChanged(screens), runtime);
        }
        // 候选窗口交给协调器，主窗口的挑选与客户端登记在 Core 里做。
        // 顺带记下以管理员运行的进程，「环境检查」页列出它们（读不到令牌的不算）。
        let candidates = candidate_windows(&self.filter);
        self.elevated_pids = candidates
            .iter()
            .filter(|c| c.process.elevated == Some(true))
            .map(|c| c.window.pid)
            .collect();
        let windows = candidates.into_iter().map(|c| c.window).collect();
        self.send(Event::WindowsPolled(windows), runtime);
        // 前台事件可能丢（例如锁屏期间），轮询时再核对一次；没变时 report_foreground 什么也不做。
        let owner = self.owner_of(foreground_window());
        self.report_foreground(owner, runtime);
    }

    /// 有窗口事件时提前轮询，但两次轮询至少隔 `EVENT_POLL_SPACING`。
    fn poll_soon(&mut self) {
        let earliest = self.polled_at + EVENT_POLL_SPACING;
        self.poll_at = self.poll_at.min(earliest.max(Instant::now()));
    }

    /// 前台窗口属于谁。
    fn owner_of(&self, window: Option<WindowId>) -> ForegroundOwner {
        // 读不到 PID（窗口刚销毁、锁屏时没有前台）按「没有前台」处理。
        match window.and_then(window_pid) {
            Some(pid) if pid == self.own_pid => ForegroundOwner::SelfApp,
            Some(pid) => ForegroundOwner::Process(pid),
            None => ForegroundOwner::Nobody,
        }
    }

    /// 前台归属变了才告诉协调器。
    fn report_foreground(&mut self, owner: ForegroundOwner, runtime: &Rc<Runtime>) {
        if self.foreground != Some(owner) {
            self.foreground = Some(owner);
            self.send(Event::ForegroundChanged(owner), runtime);
        }
    }

    /// 把配置写盘。失败时不重试：下一次改动会再写。
    fn flush(&mut self) {
        if self.save_at.take().is_some() && self.writable {
            let _ = self.store.save(self.coordinator.config());
        }
    }

    // MARK: 缩略图的手势

    /// 缩略图窗口的鼠标输入交给它的手势状态机，再把输出换成协调器事件或窗口移动。
    fn thumbnail_input(&mut self, id: WindowId, input: ThumbnailInput, runtime: &Rc<Runtime>) {
        let outputs = match input {
            ThumbnailInput::Enter => {
                self.send(Event::HoverChanged { id, hovering: true }, runtime);
                Vec::new()
            }
            ThumbnailInput::Leave => {
                // 拖动中鼠标被捕获，离开不算结束悬停；松开后再离开时才算。
                if !self.thumbnails.gesture(id).is_some_and(|g| g.is_dragging()) {
                    self.send(Event::HoverChanged { id, hovering: false }, runtime);
                }
                Vec::new()
            }
            ThumbnailInput::Press {
                button,
                modifiers,
                point,
            } => {
                let context = self.coordinator.drag_context(id);
                let modifiers = Modifiers {
                    ctrl: modifiers.ctrl,
                    alt: modifiers.alt,
                    shift: modifiers.shift,
                };
                // 上下文在按下时取一次：拖动开始前客户端可能消失，手势按「不能拖动」处理。
                self.thumbnails
                    .gesture(id)
                    .map(|g| g.press(gesture_button(button), modifiers, point, context))
                    .unwrap_or_default()
            }
            ThumbnailInput::Move { point, modifiers } => {
                let context = self.coordinator.drag_context(id);
                let Some(gesture) = self.thumbnails.gesture(id) else {
                    return;
                };
                let outputs = gesture.moved(point, modifiers.shift);
                let edges = gesture.hover_edges(point, context.as_ref());
                self.thumbnails.set_cursor(id, cursor_for(edges));
                outputs
            }
            ThumbnailInput::Release(button) => self
                .thumbnails
                .gesture(id)
                .map(|g| g.release(gesture_button(button)))
                .unwrap_or_default(),
            ThumbnailInput::CaptureLost => {
                if self.thumbnails.gesture(id).is_some_and(|g| g.cancel()) {
                    self.send(Event::DragCancelled(id), runtime);
                }
                Vec::new()
            }
        };
        for output in outputs {
            self.gesture_output(id, output, runtime);
        }
    }

    /// 执行手势的一个输出。
    fn gesture_output(&mut self, id: WindowId, output: GestureOutput, runtime: &Rc<Runtime>) {
        let topmost = self.coordinator.profile().behavior.always_on_top;
        match output {
            GestureOutput::Click => self.send(Event::ThumbnailClicked(id), runtime),
            GestureOutput::Minimize => self.send(Event::ThumbnailMinimizeRequested(id), runtime),
            GestureOutput::Menu => self.context_menu(id, runtime),
            GestureOutput::DragBegan(frame) => {
                self.thumbnails.set_live_frame(id, frame, topmost);
                self.send(Event::DragBegan(id), runtime);
            }
            GestureOutput::LiveFrame(frame) => self.thumbnails.set_live_frame(id, frame, topmost),
            GestureOutput::DragEnded(frame) => self.send(Event::DragEnded { id, frame }, runtime),
        }
    }

    // MARK: 菜单与设置窗口

    /// 在光标处弹出缩略图的右键菜单。
    fn context_menu(&mut self, id: WindowId, runtime: &Rc<Runtime>) {
        let Some(model) = self.coordinator.context_menu(id) else {
            return;
        };
        let chosen = menu::popup(
            self.tray.hwnd(),
            cursor_point(),
            &menus::context_menu(&model, self.language),
        );
        if let Some(action) = chosen.ok().flatten().and_then(menus::context_action) {
            self.send(Event::ContextMenu { id, action }, runtime);
        }
    }

    /// 在光标处弹出托盘菜单。
    fn tray_menu(&mut self, runtime: &Rc<Runtime>) {
        let model = self.coordinator.tray();
        let chosen = menu::popup(
            self.tray.hwnd(),
            cursor_point(),
            &menus::tray_menu(&model, self.language),
        );
        if let Some(action) = chosen
            .ok()
            .flatten()
            .and_then(|id| menus::tray_action(id, &model))
        {
            self.send(Event::Tray(action), runtime);
        }
    }

    /// 打开设置窗口并切到某一页。第一次打开时建窗口、接上回调，并按系统外观选明暗。
    fn open_settings(&mut self, page: SettingsPage, runtime: &Rc<Runtime>) {
        // 设置窗口第一次打开时才创建，关掉后只是隐藏，下次打开保留滚动位置与所在页。
        if self.settings.is_none() {
            // 创建失败（例如图形后端不可用）时什么也不做，托盘菜单仍可用。
            let Ok(window) = eveo_ui::SettingsWindow::new() else {
                return;
            };
            // 明暗只在建窗口时读一次；系统在窗口开着时切换明暗，下次打开设置窗口才跟上。
            window.set_dark(appearance::apps_use_dark_theme());
            // 界面文字按当前语言填；之后语言变了由 update_language 重填。
            eveo_ui::set_language(&window, self.language);
            // 回调只排队，不在 Slint 的事件处理中途借用应用（见 Runtime::post）。
            let model = window.global::<eveo_ui::PreviewsModel>();
            let weak = Rc::downgrade(runtime);
            model.on_edited(move || post(&weak, Input::SettingsEdited));
            let weak = Rc::downgrade(runtime);
            model.on_unify_sizes(move || post(&weak, Input::UnifySizes));
            // 「客户端」页：回调带角色名，转成 ClientEdit 排队。
            // 带角色名而不是下标：回调排队期间列表可能因轮询重排，下标会指错角色。
            let clients = window.global::<eveo_ui::ClientsModel>();
            let weak = Rc::downgrade(runtime);
            clients.on_hide_all_toggled(move |hide| post(&weak, Input::HideAll(hide)));
            let weak = Rc::downgrade(runtime);
            clients.on_shown_toggled(move |name, shown| {
                let name = name.to_string();
                post(&weak, Input::ClientEdit(bind::ClientEdit::Shown { name, shown }));
            });
            let weak = Rc::downgrade(runtime);
            clients.on_color_edited(move |name, text| {
                let (name, text) = (name.to_string(), text.to_string());
                post(&weak, Input::ClientEdit(bind::ClientEdit::Color { name, text }));
            });
            let weak = Rc::downgrade(runtime);
            clients.on_color_reset(move |name| {
                let name = name.to_string();
                post(&weak, Input::ClientEdit(bind::ClientEdit::ResetColor { name }));
            });
            switching_page::connect(&window, runtime);
            profiles::connect(&window, runtime);
            general::connect(&window, runtime);
            alerts::connect(&window, runtime);
            chat::connect(&window, runtime);
            translation::connect(&window, runtime);
            environment::connect(&window, runtime);
            self.settings = Some(window);
        }
        let Some(window) = &self.settings else {
            return;
        };
        self.show_settings_pages(window);
        // 托盘的「设置」、左键与首次启动（都是 General）打开「预览与布局」：最常改的设置在那一页，
        // 「通用」页的几项很少动，从导航进入。
        window.set_page(match page {
            SettingsPage::Clients => 0,
            SettingsPage::Previews | SettingsPage::General => 1,
            SettingsPage::Switching => 2,
            SettingsPage::Intel => 4,
            SettingsPage::Translation => 5,
            SettingsPage::Profiles => 6,
            SettingsPage::About => 8,
        });
        // 第一次显示前放到主屏可用区域的正中：缩略图总在最前，多半排在屏幕左上，
        // 放在系统默认的左上位置会被它们挡住导航（真机测试发现）。之后保留用户拖到的位置。
        if !window.window().is_visible() && !self.settings_placed {
            if let Some(position) = centered_position(&self.screens) {
                window.window().set_position(position);
            }
            self.settings_placed = true;
        }
        let _ = window.show();
        // 标题栏的明暗与切到前台要在原生窗口建好、显示出来之后做。第一次打开时 show 只是请求，
        // 原生窗口到事件循环的下一轮才出现（真机测试：第一次打开没到前台，之后几次都到了），
        // 所以记下来交给定时器做；窗口已经存在时这里立即就能做完。
        self.settings_focus_pending = true;
        self.focus_settings();
    }

    /// 设置窗口显示后的收尾：标题栏跟着系统的明暗走，并切到前台。原生窗口还没出现时什么也不做，
    /// 留给下一次定时器。从托盘打开时前台还在托盘的溢出窗口上，不切的话新窗口会落在游戏后面；
    /// 先直接设前台，被系统拒绝时挂接输入队列再试（不分发消息，见 bring_forward）。最小化着时一并还原。
    fn focus_settings(&mut self) {
        if !self.settings_focus_pending {
            return;
        }
        let Some(window) = &self.settings else {
            self.settings_focus_pending = false;
            return;
        };
        // 句柄拿不到或窗口还没显示出来：下一轮定时器再试。
        let Some(hwnd) =
            settings_hwnd(window).filter(|&hwnd| activation::is_visible(eveo_platform_win::window_id(hwnd)))
        else {
            return;
        };
        self.settings_focus_pending = false;
        appearance::set_dark_title_bar(hwnd, window.get_dark());
        // 这里可能在定时器里（Slint 的事件回调中），不能用会分发消息的 activate，见 bring_forward。
        let _ = activation::bring_forward(eveo_platform_win::window_id(hwnd));
    }

    /// 设置窗口里改了值：从当前配置出发读回「预览与布局」页，有变化才交给协调器。
    /// `unify` 为真时再清掉各角色单独调过的尺寸。
    fn settings_edited(&mut self, unify: bool, runtime: &Rc<Runtime>) {
        let Some(window) = &self.settings else {
            return;
        };
        // 从协调器手里的配置出发，而不是窗口上次显示的：拖动缩略图等改动可能在这期间发生，
        // 从旧副本出发会把它们覆盖掉。
        let mut config = self.coordinator.config().clone();
        let Some(profile) = config.active_profile_mut() else {
            return;
        };
        bind::read_previews(window, profile);
        if unify {
            bind::unify_sizes(profile);
        }
        // 没有变化（例如输入框里的颜色还没输完）就不打扰协调器：省一次重算，也不排一次写盘。
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
    }
}

impl App {
    /// 「客户端」页上改了某个角色：作用到当前配置的副本上，有变化才交给协调器。
    /// 与 settings_edited 一样从协调器手里的配置出发，不会覆盖期间别处的改动。
    fn client_edited(&mut self, edit: &bind::ClientEdit, runtime: &Rc<Runtime>) {
        let mut config = self.coordinator.config().clone();
        let Some(profile) = config.active_profile_mut() else {
            return;
        };
        bind::apply_client_edit(profile, edit);
        // 没有变化（颜色输到一半、开关与现状相同）就不打扰协调器。
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
    }
}

/// 平台层的鼠标按键换成手势状态机的按键。两边各自定义，是因为 app-core 不依赖平台层。
pub(crate) fn gesture_button(button: MouseButton) -> Button {
    match button {
        MouseButton::Left => Button::Left,
        MouseButton::Right => Button::Right,
    }
}

/// 缩放边对应的光标形状。
pub(crate) fn cursor_for(edges: ResizeEdges) -> CursorShape {
    let horizontal = edges.contains(ResizeEdges::LEFT) || edges.contains(ResizeEdges::RIGHT);
    let vertical = edges.contains(ResizeEdges::TOP) || edges.contains(ResizeEdges::BOTTOM);
    let main_diagonal = (edges.contains(ResizeEdges::LEFT) && edges.contains(ResizeEdges::TOP))
        || (edges.contains(ResizeEdges::RIGHT) && edges.contains(ResizeEdges::BOTTOM));
    match (horizontal, vertical) {
        (true, true) if main_diagonal => CursorShape::SizeNorthwestSoutheast,
        (true, true) => CursorShape::SizeNortheastSouthwest,
        (true, false) => CursorShape::SizeWestEast,
        (false, true) => CursorShape::SizeNorthSouth,
        (false, false) => CursorShape::Arrow,
    }
}

/// 当前光标位置（弹菜单用）。
fn cursor_point() -> eveo_core::geometry::ScreenPoint {
    eveo_platform_win::thumbnail::cursor_position()
}

/// 设置窗口首次显示的位置：主屏可用区域（去掉任务栏）的正中，物理像素。
/// 窗口大小按 settings.slint 的首选尺寸与主屏的缩放算；屏幕比窗口小时贴左上角。
fn centered_position(screens: &[ScreenInfo]) -> Option<slint::PhysicalPosition> {
    let screen = eveo_core::geometry::main_screen(screens)?;
    let area = screen.visible_frame;
    let (width, height) = (
        SETTINGS_SIZE.0 * screen.size_scale,
        SETTINGS_SIZE.1 * screen.size_scale,
    );
    let x = area.x + ((area.width - width) / 2.0).max(0.0);
    let y = area.y + ((area.height - height) / 2.0).max(0.0);
    Some(slint::PhysicalPosition::new(x.round() as i32, y.round() as i32))
}

/// 设置窗口的 Win32 句柄；窗口还没显示或不是 Win32 窗口时返回 `None`。
fn settings_hwnd(window: &eveo_ui::SettingsWindow) -> Option<HWND> {
    // Slint 经 raw-window-handle 交出底层窗口；窗口还没显示时可能拿不到句柄，这时返回 None。
    let handle = window.window().window_handle();
    let raw = handle.window_handle().ok()?;
    // 在 Windows 上只会是 Win32 句柄；其他变体只为让 match 完整。
    match raw.as_raw() {
        RawWindowHandle::Win32(win32) => Some(HWND(win32.hwnd.get() as *mut core::ffi::c_void)),
        _ => None,
    }
}
