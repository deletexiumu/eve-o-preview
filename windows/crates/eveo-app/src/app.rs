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
use eveo_app_core::gesture::{Button, GestureOutput, Modifiers};
use eveo_app_core::paths::DataPaths;
use eveo_app_core::{Coordinator, Effect, Event, ForegroundOwner, SettingsPage};
use eveo_core::geometry::ScreenInfo;
use eveo_core::layout::ResizeEdges;
use eveo_core::model::WindowId;
use eveo_platform_win::discovery::{ClientFilter, candidate_windows};
use eveo_platform_win::events::{
    WindowEvent, WindowEventHooks, foreground_window, local_timestamp, window_pid,
};
use eveo_platform_win::hotkey::{HotkeyMessage, HotkeyWindow};
use eveo_platform_win::thumbnail::{CursorShape, MouseButton, ThumbnailInput};
use eveo_platform_win::tray::{TrayEvent, TrayIcon};
use eveo_platform_win::{activation, menu, screens, single_instance};
use slint::ComponentHandle;

use crate::hotkeys::HotkeyService;
use crate::menus;
use crate::thumbnails::ThumbnailManager;

/// 定时器的周期：取窗口事件、检查轮询、唤醒与写盘。
const TICK: Duration = Duration::from_millis(50);
/// 兜底轮询的间隔（架构文档 4.1 节的 pollIntervalMs 默认值）。
const POLL_INTERVAL: Duration = Duration::from_millis(1000);
/// 有窗口事件时，两次轮询之间至少隔这么久，避免客户端窗口连续移动时每 50 毫秒枚举一次。
const EVENT_POLL_SPACING: Duration = Duration::from_millis(150);
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
}

/// 启动应用，跑主循环直到退出。
pub fn run() -> ExitCode {
    // 先声明每显示器 DPI 感知：之后取到的屏幕、窗口与光标坐标都是物理像素，与 Core 的约定一致（4.6 节）。
    screens::enable_per_monitor_dpi();
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
        thumbnails: ThumbnailManager::default(),
        tray,
        settings: None,
    };
    let runtime = Rc::new(Runtime {
        queue: RefCell::new(VecDeque::new()),
        app: RefCell::new(app),
    });
    connect_callbacks(&runtime);

    // 启动：注册热键、第一次规划，并要求立即轮询（下一次定时器就会枚举窗口）。
    runtime.post(Input::Event(Event::Started));
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
                self.open_settings(SettingsPage::General);
            }
            Input::Tick => self.tick(runtime),
        }
    }

    /// 把事件交给协调器并执行它给出的效果。
    fn send(&mut self, event: Event, runtime: &Rc<Runtime>) {
        // 效果按顺序执行；执行中产生的新输入（缩略图状态等）排进队列，由 Runtime::post 的循环接着处理。
        let effects = self.coordinator.handle(event, self.now());
        for effect in effects {
            self.execute(effect, runtime);
        }
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
                    .set_tooltip(&menus::tray_tooltip(&self.coordinator.tray()));
            }
            // 热键服务自己处理代数与作用范围，这里只转交。
            Effect::RegisterHotkeys(bindings) => self.hotkeys.replace(bindings),
            Effect::SetGameForeground(game) => self.hotkeys.set_game_foreground(game),
            // 配置变化：推迟写盘，连续改动（例如拖动后又改设置）只写一次。设置窗口的同步随设置页一起做。
            Effect::ConfigChanged(_) => {
                if self.writable {
                    self.save_at = Some(Instant::now() + SAVE_DELAY);
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
            Effect::OpenSettings(page) => self.open_settings(page),
            // 退出：先写盘，再让主循环返回到 run() 的收尾。
            Effect::Quit => {
                self.flush();
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
        let windows = candidate_windows(&self.filter)
            .into_iter()
            .map(|c| c.window)
            .collect();
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
        let chosen = menu::popup(self.tray.hwnd(), cursor_point(), &menus::context_menu(&model));
        if let Some(action) = chosen.ok().flatten().and_then(menus::context_action) {
            self.send(Event::ContextMenu { id, action }, runtime);
        }
    }

    /// 在光标处弹出托盘菜单。
    fn tray_menu(&mut self, runtime: &Rc<Runtime>) {
        let model = self.coordinator.tray();
        let chosen = menu::popup(self.tray.hwnd(), cursor_point(), &menus::tray_menu(&model));
        if let Some(action) = chosen
            .ok()
            .flatten()
            .and_then(|id| menus::tray_action(id, &model))
        {
            self.send(Event::Tray(action), runtime);
        }
    }

    /// 打开设置窗口并切到某一页。设置窗口目前是视觉原型（M4），各页的内容随后补上。
    fn open_settings(&mut self, page: SettingsPage) {
        if self.settings.is_none() {
            self.settings = eveo_ui::SettingsWindow::new().ok();
        }
        let Some(window) = &self.settings else {
            return;
        };
        window.set_page(match page {
            SettingsPage::Clients => 0,
            SettingsPage::Previews => 1,
            SettingsPage::Switching => 2,
            SettingsPage::Profiles => 6,
            SettingsPage::General => 7,
            SettingsPage::About => 8,
        });
        let _ = window.show();
    }
}

/// 平台层的鼠标按键换成手势状态机的按键。两边各自定义，是因为 app-core 不依赖平台层。
fn gesture_button(button: MouseButton) -> Button {
    match button {
        MouseButton::Left => Button::Left,
        MouseButton::Right => Button::Right,
    }
}

/// 缩放边对应的光标形状。
fn cursor_for(edges: ResizeEdges) -> CursorShape {
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
