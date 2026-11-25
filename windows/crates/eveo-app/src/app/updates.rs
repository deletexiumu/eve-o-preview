// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动更新接进应用（docs/windows/architecture.md 6.3 节）：更新状态机（eveo_app_core::update::machine）
// 决定做什么，这里执行它的命令、把结果交回去，并管更新窗口、托盘菜单的提示项、通知与「通用」页的状态行。
//
// - 状态机的每次调用都经 with_state 拿到 StateStore（chat.state）里的更新记录，调用完由 StateStore 写盘
//   （内容没变时不写）。启动时的确认（update_launch）也写这份记录，二者不会互相覆盖。
// - 检查、下载与替换在新线程里做（update_jobs），结果经通道交回，定时器里取（每 250 毫秒一次）。
// - 自动检查发现新版本、自动安装关着时发一条托盘通知；点通知打开更新窗口。崩溃的通知也走同一个回调，
//   所以记下最近一条通知是谁发的。
// - 托盘菜单：总有「检查更新…」（更新功能停用时没有）；有新版本时顶部多「有可用更新：<版本>…」，
//   已下载好时是「重新启动以更新到 <版本>」。
// - 重新启动：带 `--after-update <本进程编号> --background` 启动新 exe，然后走正常的退出流程；
//   新进程等本进程退出后再做单实例检查（update_launch）。启动不了时窗口提示手动重新打开。
// - 退出时：已下载好且两个开关都开着时安装（不重新启动），最多等 8 秒。
//
// 公钥：正式构建的公钥在打包时由环境变量 EVEO_UPDATE_PUBLIC_KEY 编进 exe（64 位十六进制）；
// 没有时只提示不安装。使用测试地址（EVEO_UPDATE_FEED_URL）时可以用运行时的 EVEO_UPDATE_TEST_PUBLIC_KEY，
// 正式地址下忽略它：环境变量不能让正式渠道接受另一把钥匙签的包。
// 日志只写版本号、阶段与错误名，不写发布说明的全文、地址与路径。

//! 自动更新的运行时。

use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

use eveo_app_core::log::Logger;
use eveo_app_core::paths::DataPaths;
use eveo_app_core::state_store::UpdateState;
use eveo_app_core::update::machine::{
    CheckOutcome, Command, MenuHint, Progress, Switches, UpdateMachine, UpdatePhase,
};
use eveo_app_core::update::state::PreparedUpdate;
use eveo_core::model::AppLanguage;
use eveo_core::update::feed::UpdateFeed;
use eveo_core::update::install::{AFTER_UPDATE_ARG, PendingSwap};
use eveo_core::update::models::{InstallBlocker, InstallCapability, RunningApp, UpdateError};
use eveo_core::update::version::SemanticVersion;
use eveo_platform_win::update as platform;
use eveo_platform_win::{activation, appearance};
use eveo_ui::update::{PhaseKind, UpdateView};
use slint::ComponentHandle;

use super::intel::wall_clock;
use super::update_jobs::{self, PrepareContext};
use super::update_launch::version_label;
use super::{App, Input, Runtime, post, shell};

/// 更新的日志。
const LOG: Logger = Logger::new("Update");
/// 更新窗口的大小（逻辑像素），用来放在主屏正中。
const WINDOW_SIZE: (f64, f64) = (640.0, 540.0);
/// 退出时安装最多等多久。
const QUIT_INSTALL_TIMEOUT: Duration = Duration::from_secs(8);
/// 更新推进的间隔。
const TICK_INTERVAL: Duration = Duration::from_millis(250);
/// 下载进度最多多久交一次（字节）：每 256 KiB 一次，窗口的进度条够流畅，通道也不会塞满。
const PROGRESS_STEP: u64 = 256 * 1024;

/// 更新窗口与托盘菜单的操作。
#[derive(Debug, Clone, Copy)]
pub(super) enum UpdateInput {
    /// 安装更新。
    Install,
    /// 跳过此版本。
    Skip,
    /// 稍后。
    Later,
    /// 取消下载。
    Cancel,
    /// 关闭窗口。
    Close,
    /// 重试。
    Retry,
    /// 打开发布页。
    OpenReleasePage,
    /// 托盘菜单与「通用」页的「检查更新」。
    CheckNow,
    /// 托盘菜单的「有可用更新…」：显示窗口。
    ShowWindow,
    /// 托盘菜单的「重新启动以更新」。
    RestartToInstall,
}

/// 后台任务交回的结果。
///
/// 每种结果对应状态机的一个方法；通道是无界的，进度已在下载线程里节流（每 256 KiB 一条），
/// 一次下载最多几百条，定时器每 250 毫秒取空一次，不会堆积。
enum WorkResult {
    /// 检查的结果，与清单的序号（正式地址下检查成功时才有）。
    Checked(CheckOutcome, Option<u64>),
    /// 下载的进度。
    Progress(Progress),
    /// 下载、核对与解包的结果。
    Prepared(Result<PreparedUpdate, UpdateError>),
    /// 替换的结果。
    Installed(Result<PendingSwap, UpdateError>),
}

/// 自动更新的运行时状态。
pub(super) struct Updates {
    /// 状态机。
    machine: UpdateMachine,
    /// 正在运行的应用（下载任务核对新 exe 时用）。
    running: RunningApp,
    /// 下一次推进的时刻：定时器每 50 毫秒一次，更新只需每 250 毫秒推进一次。
    next_tick: Instant,
    /// 本进程的 exe（正式文件名时才有；否则不能安装）。
    exe: Option<PathBuf>,
    /// 更新缓存目录。
    cache_dir: PathBuf,
    /// 验签的公钥。
    public_key: Option<[u8; 32]>,
    /// 后台任务交回结果的通道。
    sender: Sender<WorkResult>,
    /// 结果的接收端。
    receiver: Receiver<WorkResult>,
    /// 取消下载的标志。每次下载换一个新的，旧任务晚到的取消不影响新任务。
    cancel: Arc<AtomicBool>,
    /// 更新窗口；关掉后丢弃，下次重建。
    window: Option<eveo_ui::UpdateWindow>,
    /// 窗口固定文字所用的语言；新建的窗口是 None。界面语言变了时重填。
    window_language: Option<AppLanguage>,
    /// 窗口显示后要切到前台。
    focus_pending: bool,
    /// 最近一条托盘通知是更新发的（点通知时打开更新窗口而不是崩溃报告）。
    pub(super) last_notification: bool,
    /// 最近一次交给状态机的开关；配置变了才通知它。
    switches: Switches,
}

/// 正式构建的公钥（打包时编进来）。
///
/// 私钥只在 GitHub Actions 的密钥里，签名在发布流程里做；源码与本机构建都没有私钥，
/// 所以本机构建出的 exe 没有公钥，更新功能只提示、不安装（窗口里说明原因）。
const BUILT_IN_PUBLIC_KEY: Option<&str> = option_env!("EVEO_UPDATE_PUBLIC_KEY");

impl Updates {
    /// 建运行时：算出正在运行的应用、检查地址与公钥，状态机还没有开始（见 App::start_updates）。
    pub(super) fn new(paths: &DataPaths, switches: Switches) -> Self {
        let override_url = std::env::var("EVEO_UPDATE_FEED_URL").ok();
        let feed = UpdateFeed::resolve(override_url.as_deref());
        if override_url.as_deref().is_some_and(|url| !url.is_empty()) && !feed.is_test_feed {
            LOG.error("EVEO_UPDATE_FEED_URL 不是 https，也不是回环主机的 http，已忽略");
        }
        // 测试公钥只在测试地址下生效；正式地址只认编进 exe 的公钥。
        let test_key = feed
            .is_test_feed
            .then(|| std::env::var("EVEO_UPDATE_TEST_PUBLIC_KEY").ok())
            .flatten();
        let public_key = test_key
            .as_deref()
            .or(BUILT_IN_PUBLIC_KEY)
            .and_then(update_jobs::parse_public_key);
        let exe = super::update_launch::own_exe();
        let label = version_label();
        let running = RunningApp {
            version: env!("CARGO_PKG_VERSION").to_owned(),
            build_label: label.to_owned(),
            // 调试构建只在测试地址下能安装（真机测试用，测试地址还要求测试公钥）；
            // 开发与 PR 构建的标签总是只提示。
            is_development: (cfg!(debug_assertions) && !feed.is_test_feed) || is_development_label(label),
            location_writable: exe.as_deref().is_some_and(platform::folder_writable),
            has_signing_key: public_key.is_some(),
        };
        let machine = UpdateMachine::new(running.clone(), feed, switches);
        let (sender, receiver) = mpsc::channel();
        Self {
            machine,
            running,
            next_tick: Instant::now(),
            exe,
            cache_dir: paths.updates_dir(),
            public_key,
            sender,
            receiver,
            cancel: Arc::new(AtomicBool::new(false)),
            window: None,
            window_language: None,
            focus_pending: false,
            last_notification: false,
            switches,
        }
    }

    /// 托盘菜单的提示项，以及「检查更新…」是否出现。
    ///
    /// 托盘菜单每次弹出时都重新取：提示随检查结果与下载进度变化，菜单里不缓存。
    pub(super) fn menu(&self) -> (MenuHint, bool) {
        (
            self.machine.menu_hint(),
            self.machine.capability() != InstallCapability::Unavailable,
        )
    }
}

/// 配置里的两个更新开关。
pub(super) fn switches(general: &eveo_core::model::GeneralSettings) -> Switches {
    Switches {
        check: general.check_for_updates,
        auto_install: general.auto_install_updates,
    }
}

/// 构建标签是否表示开发或 PR 构建：预发布标识里有 `dev` 或 `pr` 段（如 `0.9.0-pr.70.abc1234`）。
///
/// CI 的测试构建与本机构建的标签带 `pr`、`dev` 段，它们没有经过发布流程，不该自己换成正式版：
/// 换了之后开发者就不知道自己在测哪个版本了。
fn is_development_label(label: &str) -> bool {
    SemanticVersion::parse(label).is_some_and(|version| {
        version
            .prerelease
            .iter()
            .any(|segment| segment.eq_ignore_ascii_case("dev") || segment.eq_ignore_ascii_case("pr"))
    })
}

/// 接上更新窗口的按钮：都转成输入排队。
///
/// 窗口的回调里不直接借用 App（Slint 正在派发事件，App 可能已被借用），只把输入放进队列，
/// 由 Runtime::post 的循环接着处理，与设置窗口、报告窗口的做法相同。
fn connect(window: &eveo_ui::UpdateWindow, runtime: &Rc<Runtime>) {
    let sender = |runtime: &Rc<Runtime>| {
        let weak = Rc::downgrade(runtime);
        move |input: UpdateInput| post(&weak, Input::Update(input))
    };
    let model = window.global::<eveo_ui::UpdateModel>();
    let send = sender(runtime);
    model.on_install(move || send(UpdateInput::Install));
    let send = sender(runtime);
    model.on_skip(move || send(UpdateInput::Skip));
    let send = sender(runtime);
    model.on_later(move || send(UpdateInput::Later));
    let send = sender(runtime);
    model.on_cancel(move || send(UpdateInput::Cancel));
    let send = sender(runtime);
    model.on_close(move || send(UpdateInput::Close));
    let send = sender(runtime);
    model.on_retry(move || send(UpdateInput::Retry));
    let send = sender(runtime);
    model.on_open_release_page(move || send(UpdateInput::OpenReleasePage));
    // 标题栏的关闭按钮等于「稍后」：下载中关窗口不取消，下载在后台继续。
    let send = sender(runtime);
    window.window().on_close_requested(move || {
        send(UpdateInput::Close);
        slint::CloseRequestResponse::HideWindow
    });
}

impl App {
    /// 调用状态机：拿到 state.json 的更新记录，调用完写盘（没变时不写）。
    ///
    /// 状态机本身不做 I/O：它改的是传进来的记录，写盘由 StateStore 负责（内容没变时不写）。
    /// 写盘失败只记日志：记录丢了最多是下次多检查一次或重新下载一次，不影响正在运行的应用。
    fn with_updates<R>(&mut self, call: impl FnOnce(&mut UpdateMachine, &mut UpdateState) -> R) -> R {
        let machine = &mut self.updates.machine;
        let mut result = None;
        let written = self
            .chat
            .state
            .update_updates(|state| result = Some(call(machine, state)));
        if let Err(error) = written {
            LOG.error(format_args!("写 state.json 失败：{:?}", error.kind()));
        }
        // update_updates 总会调用闭包；None 只在闭包没被调用时出现（不会发生）。
        result.expect("update_updates 调用了闭包")
    }

    /// 启动更新：恢复上次的状态，安排第一次检查。在 App 建好之后调用一次。
    ///
    /// state.json 里记的新 exe 要先确认还在、并且在缓存目录里：用户清理过缓存，或记录被手改过时，
    /// 状态机会把「已下载好」降回「可用」，不会去安装一个不存在的文件。
    pub(super) fn start_updates(&mut self, runtime: &Rc<Runtime>) {
        let capability = self.updates.machine.capability();
        let feed = self.updates.machine.feed().clone();
        LOG.info(format_args!(
            "更新功能：版本 {}，能否安装 {capability:?}{}",
            version_label(),
            if feed.is_test_feed {
                "，使用测试地址"
            } else {
                ""
            }
        ));
        let exists = self
            .chat
            .state
            .state()
            .updates
            .prepared
            .as_ref()
            .is_some_and(|p| {
                update_jobs::is_inside(std::path::Path::new(&p.exe_path), &self.updates.cache_dir)
            });
        let now = wall_clock();
        let commands = self.with_updates(|machine, state| {
            // 1.5.0 起检查不再走 GitHub 的接口，不会被限流：1.4.x 留下的限流时刻与 ETag 清掉，免得挡住第一次检查。
            state.rate_limited_until = None;
            state.etag = None;
            machine.start(state, now, exists)
        });
        self.run_update_commands(commands, runtime);
    }

    /// 定时器里调用：取后台任务的结果、交给状态机、按开关与客户端的情况推进，刷新窗口与「通用」页。
    pub(super) fn updates_tick(&mut self, runtime: &Rc<Runtime>) {
        // 节流：主定时器每 50 毫秒一次，而更新的事都不急（检查按小时、空闲安装按分钟），
        // 每 250 毫秒推进一次足够让下载进度条流畅，也少写几次「通用」页的属性。
        if Instant::now() < self.updates.next_tick {
            return;
        }
        self.updates.next_tick = Instant::now() + TICK_INTERVAL;
        let now = wall_clock();
        // 开关变了（设置页或配置文件）：交给状态机。
        let switches = switches(&self.coordinator.config().general);
        if switches != self.updates.switches {
            self.updates.switches = switches;
            let commands = self.with_updates(|machine, state| machine.switches_changed(state, now, switches));
            self.run_update_commands(commands, runtime);
        }
        // 进度只改状态机内部的数字，不写 state.json；其余三种结果都可能改记录，经 with_updates 写盘。
        // 后台任务的结果，按到达的顺序处理。
        while let Ok(result) = self.updates.receiver.try_recv() {
            let commands = match result {
                WorkResult::Checked(outcome, sequence) => {
                    log_check(&outcome);
                    self.with_updates(|machine, state| {
                        // 记下接受过的最大序号：之后更旧的清单当作那个源失败（防止旧清单被重放）。
                        if let Some(sequence) = sequence {
                            state.manifest_sequence =
                                Some(state.manifest_sequence.map_or(sequence, |old| old.max(sequence)));
                        }
                        machine.check_finished(state, now, outcome)
                    })
                }
                WorkResult::Progress(progress) => {
                    self.updates.machine.progress(progress);
                    Vec::new()
                }
                WorkResult::Prepared(result) => {
                    match &result {
                        Ok(prepared) => LOG.info(format_args!("更新 {} 已下载并核对", prepared.version)),
                        Err(UpdateError::Cancelled) => LOG.info("下载更新已取消"),
                        Err(error) => LOG.error(format_args!("下载更新失败：{}", error.code())),
                    }
                    self.with_updates(|machine, state| machine.prepare_finished(state, now, result))
                }
                WorkResult::Installed(result) => {
                    match &result {
                        Ok(swap) => LOG.notice(format_args!("已换上 {}", swap.version)),
                        Err(error) => LOG.error(format_args!("安装更新失败：{}", error.code())),
                    }
                    self.with_updates(|machine, state| machine.install_finished(state, now, result))
                }
            };
            self.run_update_commands(commands, runtime);
        }
        // 空闲安装只在没有 EVE 客户端时进行（状态机自己记「多久没有客户端」）：
        // 换 exe 后重新启动会让缩略图消失几秒，不能在玩家正在用的时候发生。
        let clients = !self.coordinator.registry().clients().is_empty();
        let commands = self.with_updates(|machine, state| machine.tick(state, now, clients));
        self.run_update_commands(commands, runtime);
        self.refresh_update_views();
    }

    /// 更新窗口、托盘菜单与「通用」页的操作。
    pub(super) fn update_input(&mut self, input: UpdateInput, runtime: &Rc<Runtime>) {
        let now = wall_clock();
        let commands = match input {
            UpdateInput::Install => self.with_updates(|machine, state| machine.install(state)),
            UpdateInput::RestartToInstall => {
                self.with_updates(|machine, state| machine.restart_to_install(state))
            }
            UpdateInput::Skip => {
                let commands = self.with_updates(|machine, state| machine.skip(state));
                self.close_update_window();
                commands
            }
            UpdateInput::Later | UpdateInput::Close => {
                self.with_updates(|machine, state| machine.later(state));
                self.close_update_window();
                Vec::new()
            }
            // 取消只在下载与核对时有意义；状态机发出 CancelPrepare，下载线程看到标志后以 Cancelled 结束。
            UpdateInput::Cancel => self.updates.machine.cancel(),
            // 重试：失败的是安装（带着发布版）时重新安装，否则重新检查。
            UpdateInput::Retry => match self.updates.machine.phase() {
                UpdatePhase::Failed(_, Some(_)) => self.with_updates(|machine, state| machine.install(state)),
                _ => self.with_updates(|machine, state| machine.check_now(state, now)),
            },
            // 发布页的地址来自检查结果（已核对是 GitHub 上本仓库的地址），状态机只给出 OpenUrl。
            UpdateInput::OpenReleasePage => {
                let state = &self.chat.state.state().updates;
                self.updates.machine.open_release_page(state)
            }
            UpdateInput::CheckNow => self.with_updates(|machine, state| machine.check_now(state, now)),
            UpdateInput::ShowWindow => vec![Command::ShowWindow { activate: true }],
        };
        self.run_update_commands(commands, runtime);
        self.refresh_update_views();
    }

    /// 点了托盘通知：最近一条是更新的通知时打开更新窗口，否则交给崩溃报告。返回是否已处理。
    ///
    /// 托盘图标只有一个通知回调，分不出点的是哪一条，所以记下最近一条是谁发的。
    pub(super) fn update_notification_clicked(&mut self, runtime: &Rc<Runtime>) -> bool {
        if !self.updates.last_notification {
            return false;
        }
        self.update_input(UpdateInput::ShowWindow, runtime);
        true
    }

    /// 执行状态机的命令。
    fn run_update_commands(&mut self, commands: Vec<Command>, runtime: &Rc<Runtime>) {
        for command in commands {
            match command {
                Command::Check { .. } => self.spawn_check(),
                Command::Prepare(release) => self.spawn_prepare(release),
                Command::CancelPrepare => self.updates.cancel.store(true, Ordering::Relaxed),
                // 是否重新启动由状态机记着：替换完成后它按 install_finished 的结果发 Relaunch，这里不用看。
                Command::Install {
                    prepared,
                    relaunch: _,
                } => self.spawn_install(prepared),
                Command::Relaunch => self.relaunch(runtime),
                Command::ShowWindow { activate } => self.show_update_window(activate, runtime),
                Command::Notify(version) => {
                    // 标题写哪个版本可用，正文告诉用户点通知能做什么；应用名由通知来源一栏显示，不再重复。
                    let strings = eveo_l10n::updates(self.language);
                    let title = strings.headline(&version);
                    match self.tray.notify(&title, strings.notification_body()) {
                        Ok(()) => LOG.info(format_args!("已通知新版本 {version}")),
                        Err(code) => LOG.error(format_args!("更新通知没有发出：错误码 {code}")),
                    }
                    self.updates.last_notification = true;
                }
                Command::DeleteFile(path) => {
                    let path = PathBuf::from(path);
                    // 路径来自 state.json：不在更新缓存目录下时不删。
                    if update_jobs::is_inside(&path, &self.updates.cache_dir) {
                        if let Err(error) = std::fs::remove_file(&path) {
                            LOG.error(format_args!("删除缓存的更新失败：{:?}", error.kind()));
                        }
                    } else if path.exists() {
                        LOG.error("state.json 记录的新 exe 不在更新缓存目录下，不删");
                    }
                }
                Command::OpenUrl(url) => shell::open_url(&url),
            }
        }
    }

    /// 在新线程里检查。
    ///
    /// 检查按顺序试清单的源，通常一个请求、最多几秒；线程结束时把结果放进通道，不碰应用的任何状态。
    /// 1.5.0 起不用 ETag（清单很小，每天一次），状态机给的 etag 不再使用。
    fn spawn_check(&mut self) {
        let feed = self.updates.machine.feed().clone();
        let sender = self.updates.sender.clone();
        let public_key = self.updates.public_key;
        let min_sequence = self.chat.state.state().updates.manifest_sequence;
        LOG.info("检查更新");
        let spawned = std::thread::Builder::new()
            .name("update-check".into())
            .spawn(move || {
                let (outcome, sequence) = update_jobs::check(&feed, public_key, min_sequence);
                let _ = sender.send(WorkResult::Checked(outcome, sequence));
            });
        // 线程建不出来（极少见）：当作网络错误交回，状态机按失败处理，下次醒来再试。
        if spawned.is_err() {
            let _ = self.updates.sender.send(WorkResult::Checked(
                CheckOutcome::Failed(UpdateError::Network("thread".into())),
                None,
            ));
        }
    }

    /// 在新线程里下载、核对与解包。
    fn spawn_prepare(&mut self, release: eveo_core::update::models::ReleaseInfo) {
        let Some(public_key) = self.updates.public_key else {
            let _ = self
                .updates
                .sender
                .send(WorkResult::Prepared(Err(UpdateError::Blocked(
                    InstallBlocker::NoSigningKey,
                ))));
            return;
        };
        // 下载线程拿到的是这一刻的副本：检查地址、公钥、正在运行的版本与缓存目录在下载期间都不会变，
        // 线程不需要回头读应用的状态，也就不需要锁。
        // 每次下载换一个新的取消标志：上一次的取消不会影响这一次。
        self.updates.cancel = Arc::new(AtomicBool::new(false));
        let context = PrepareContext {
            feed: self.updates.machine.feed().clone(),
            public_key,
            running: self.updates.running.clone(),
            cache_dir: self.updates.cache_dir.clone(),
            own_exe: self.updates.exe.clone(),
            cancel: Arc::clone(&self.updates.cancel),
        };
        let sender = self.updates.sender.clone();
        LOG.info(format_args!("下载更新 {}", release.version));
        let spawned = std::thread::Builder::new()
            .name("update-download".into())
            .spawn(move || {
                let mut reported = 0u64;
                let progress_sender = sender.clone();
                let result = update_jobs::prepare(&context, &release, &mut |progress| {
                    // 节流：每 256 KiB 或收齐时交一次。
                    let done = progress.total.is_some_and(|total| progress.received >= total);
                    if done || progress.received >= reported + PROGRESS_STEP {
                        reported = progress.received;
                        let _ = progress_sender.send(WorkResult::Progress(progress));
                    }
                });
                let _ = sender.send(WorkResult::Prepared(result));
            });
        if spawned.is_err() {
            let _ = self
                .updates
                .sender
                .send(WorkResult::Prepared(Err(UpdateError::Network("thread".into()))));
        }
    }

    /// 在新线程里替换 exe。
    ///
    /// 替换只是几次改名与一次写文件，通常不到一秒；放进线程是因为杀毒软件可能在改名时扫描新 exe，
    /// 卡住几秒也不能让托盘与缩略图停下来。
    fn spawn_install(&self, prepared: PreparedUpdate) {
        let sender = self.updates.sender.clone();
        let job = install_job(&self.updates, prepared);
        let spawned = std::thread::Builder::new()
            .name("update-install".into())
            .spawn(move || {
                let _ = sender.send(WorkResult::Installed(job()));
            });
        if spawned.is_err() {
            let _ = self
                .updates
                .sender
                .send(WorkResult::Installed(Err(UpdateError::ReplaceFailed(0))));
        }
    }

    /// 启动新版并退出本进程。启动不了时窗口提示手动重新打开。
    ///
    /// 新进程带 `--background`：不打开设置窗口，与开机自启一样安静地回到托盘。
    /// 本进程走正常的退出流程（写配置、标记正常结束），新进程等它退出后再做单实例检查。
    fn relaunch(&mut self, runtime: &Rc<Runtime>) {
        let Some(exe) = self.updates.exe.clone() else {
            let commands = self.updates.machine.relaunch_did_fail();
            self.run_update_commands(commands, runtime);
            return;
        };
        let args = [
            AFTER_UPDATE_ARG.to_owned(),
            std::process::id().to_string(),
            "--background".to_owned(),
        ];
        match platform::launch(&exe, &args) {
            Ok(pid) => {
                LOG.notice(format_args!("已启动新版（进程 {pid}），本进程退出"));
                self.quit_timer = Some(super::logging::QuitTimer::start("更新后重新启动"));
                let _ = slint::quit_event_loop();
            }
            Err(code) => {
                LOG.error(format_args!("启动新版失败：错误码 {code}"));
                let commands = self.updates.machine.relaunch_did_fail();
                self.run_update_commands(commands, runtime);
            }
        }
    }

    /// 退出前调用：已下载好时安装（不重新启动），最多等 8 秒。
    ///
    /// 退出时安装不重新启动：用户是主动退出的，不该看到应用自己又开起来。下次手动打开时就是新版，
    /// 启动时的确认（update_launch）照常进行。超过时限时放弃等待，替换线程随进程结束而终止；
    /// 平台层的替换是先写 .new 再改名，半途终止只会留下 .new，下次启动时清掉。
    pub(super) fn updates_quit(&mut self) {
        let commands = self.with_updates(|machine, state| machine.quit(state));
        let Some(prepared) = commands.into_iter().find_map(|command| match command {
            Command::Install { prepared, .. } => Some(prepared),
            _ => None,
        }) else {
            return;
        };
        LOG.info(format_args!("退出时安装更新 {}", prepared.version));
        let job = install_job(&self.updates, prepared);
        let (sender, receiver) = mpsc::channel();
        // 在线程里装，主线程只等有限的时间：替换卡住（杀毒软件扫描）时不挂住退出。
        let spawned = std::thread::Builder::new()
            .name("update-install".into())
            .spawn(move || {
                let _ = sender.send(job());
            });
        let result = match spawned {
            Ok(_) => receiver.recv_timeout(QUIT_INSTALL_TIMEOUT).ok(),
            Err(_) => None,
        };
        let Some(result) = result else {
            LOG.error("退出时安装超过时限，不再等待");
            return;
        };
        match &result {
            Ok(swap) => LOG.notice(format_args!("退出时已换上 {}", swap.version)),
            Err(error) => LOG.error(format_args!("退出时安装失败：{}", error.code())),
        }
        let now = wall_clock();
        let commands = self.with_updates(|machine, state| machine.install_finished(state, now, result));
        // 退出时只剩删缓存文件这一种命令；窗口与重新启动都不会出现（状态机已在退出中）。
        for command in commands {
            if let Command::DeleteFile(path) = command {
                let path = PathBuf::from(path);
                if update_jobs::is_inside(&path, &self.updates.cache_dir) {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }

    /// 显示更新窗口；activate 为真时切到前台。
    ///
    /// 窗口第一次显示时才建，关掉后丢弃：更新窗口很少打开，常驻一份只会占内存。
    fn show_update_window(&mut self, activate: bool, runtime: &Rc<Runtime>) {
        if self.updates.window.is_none() {
            let Ok(window) = eveo_ui::UpdateWindow::new() else {
                return;
            };
            window.set_dark(appearance::apps_use_dark_theme());
            connect(&window, runtime);
            if let Some(position) = super::centered_position(&self.screens, WINDOW_SIZE) {
                window.window().set_position(position);
            }
            self.updates.window = Some(window);
        }
        self.refresh_update_views();
        if let Some(window) = &self.updates.window {
            let _ = window.show();
        }
        // 自动的失败提示不抢焦点；只有用户点出来的才切到前台。
        self.updates.focus_pending = activate;
    }

    /// 关掉更新窗口。
    fn close_update_window(&mut self) {
        if let Some(window) = self.updates.window.take() {
            let _ = window.hide();
        }
        self.updates.window_language = None;
    }

    /// 刷新更新窗口、切前台，以及「通用」页的更新状态行。
    fn refresh_update_views(&mut self) {
        let language = self.language;
        let state = self.chat.state.state().updates.clone();
        if let Some(window) = &self.updates.window {
            // 新建的窗口与界面语言变了的窗口：重填固定的文字（按钮、小标题）。
            if self.updates.window_language != Some(language) {
                self.updates.window_language = Some(language);
                eveo_ui::update::set_language(window, language);
            }
            // 状态机回到空闲（例如跳过之后）时窗口没有内容可显示，关掉。
            match view(&self.updates.machine, &state, language) {
                Some(view) => eveo_ui::update::apply(window, &view),
                None => {
                    self.close_update_window();
                    return;
                }
            }
            if self.updates.focus_pending
                && let Some(hwnd) = super::window_hwnd(window.window())
                && activation::is_visible(eveo_platform_win::window_id(hwnd))
            {
                self.updates.focus_pending = false;
                appearance::set_dark_title_bar(hwnd, window.get_dark());
                let _ = activation::bring_forward(eveo_platform_win::window_id(hwnd));
            }
        }
        if let Some(settings) = &self.settings {
            let (status, can_check) = settings_status(&self.updates.machine, &state, language);
            let text = eveo_l10n::updates(language);
            let last = state
                .last_check_at
                .map_or_else(|| text.last_checked_never().to_owned(), local_date_time);
            eveo_ui::general::show_update_status(settings, version_label(), &last, &status, can_check);
        }
    }
}

/// 替换 exe 的任务（在线程里调用）。本进程不是以正式文件名运行时直接失败。
///
/// 退出时同步安装与平时在线程里安装用同一个任务，保证两条路径的检查完全一样。
fn install_job(
    updates: &Updates,
    prepared: PreparedUpdate,
) -> impl FnOnce() -> Result<PendingSwap, UpdateError> + Send + 'static {
    let cache_dir = updates.cache_dir.clone();
    let exe = updates.exe.clone();
    let label = version_label().to_owned();
    move || match exe {
        Some(exe) => update_jobs::install(&prepared, &cache_dir, &exe, &label),
        None => Err(UpdateError::Blocked(InstallBlocker::LocationNotWritable)),
    }
}

/// 检查结果的日志：只写结果的种类与版本号。
///
/// 发布说明与地址不进日志：说明可能很长，地址对排查没有帮助，版本数与错误名已经够用。
fn log_check(outcome: &CheckOutcome) {
    match outcome {
        CheckOutcome::List(list, _) => match list.releases.first() {
            Some(latest) => LOG.info(format_args!("检查更新：Windows 的最新版是 {}", latest.version)),
            None => LOG.info("检查更新：清单里没有 Windows 版"),
        },
        CheckOutcome::NotModified => LOG.info("检查更新：与上次相同"),
        CheckOutcome::RateLimited(_) => LOG.error("检查更新被限流"),
        CheckOutcome::Failed(error) => LOG.error(format_args!("检查更新失败：{}", error.code())),
    }
}

/// 时刻写成本地的「yyyy-MM-dd HH:mm」。
///
/// 时差按此刻的本地时区算（含夏令时）；记录里的时刻离现在最多几天，跨过夏令时切换的误差可以忽略。
fn local_date_time(time: f64) -> String {
    let shifted = time + eveo_platform_win::events::local_offset_seconds();
    // ISO 8601 的「2026-11-24T16:30:00Z」取日期与时分。
    let text = eveo_core::support::time::iso8601_seconds(shifted);
    format!("{} {}", &text[..10], &text[11..16])
}

/// 时刻写成本地的「HH:mm」（限流的「请在 HH:mm 之后再试」）。
fn local_time(time: f64) -> String {
    local_date_time(time)[11..].to_owned()
}

/// 不能安装的原因写成一句话。
///
/// 原因接在「此版本只能提示更新。」之后显示，告诉用户为什么没有「安装更新」按钮、该怎么办。
fn blocker_text(blocker: InstallBlocker, language: AppLanguage) -> String {
    let text = eveo_l10n::updates(language);
    match blocker {
        InstallBlocker::LocationNotWritable => text.blocker_location_not_writable(),
        InstallBlocker::DevelopmentBuild => text.blocker_development_build(),
        InstallBlocker::NoSigningKey => text.blocker_no_signing_key(),
    }
    .to_owned()
}

/// 错误写成一句话；取消时是空串。
///
/// 错误的细节（HTTP 状态码以外的内部原因）只写进日志：用户能做的只有重试或去发布页手动下载，
/// 多写几种措辞只会让人困惑。
fn error_text(error: &UpdateError, language: AppLanguage) -> String {
    let text = eveo_l10n::updates(language);
    match error {
        UpdateError::Network(_) => text.error_network().to_owned(),
        UpdateError::HttpStatus(code) => text.error_http_status(i64::from(*code)),
        UpdateError::RateLimited(Some(until)) => text.status_rate_limited(&local_time(*until)),
        UpdateError::RateLimited(None) => text.status_rate_limited_later().to_owned(),
        UpdateError::MalformedFeed(_) => text.error_malformed_feed().to_owned(),
        UpdateError::AssetMissing(_) => text.error_asset_missing().to_owned(),
        UpdateError::InsufficientDiskSpace => text.error_disk_space().to_owned(),
        UpdateError::ChecksumListInvalid
        | UpdateError::ChecksumEntryMissing(_)
        | UpdateError::ChecksumMismatch => text.error_checksum().to_owned(),
        // 签名、解包、版本与架构的核对失败对用户都是「无法验证新版本」；具体原因在日志里。
        UpdateError::DownloadTooLarge
        | UpdateError::SignatureInvalid
        | UpdateError::ArchiveInvalid(_)
        | UpdateError::VersionMismatch { .. }
        | UpdateError::NotNewer
        | UpdateError::ArchitectureMismatch => text.error_verification().to_owned(),
        UpdateError::Blocked(blocker) => blocker_text(*blocker, language),
        UpdateError::ReplaceFailed(_) => text.error_swap_failed().to_owned(),
        UpdateError::Cancelled => String::new(),
    }
}

/// 窗口要显示的内容；空闲时没有（窗口关掉）。
///
/// 阶段与窗口的对应与 macOS 的 UpdateView 相同：
/// - 检查中、已是最新：只有标题与「关闭」；
/// - 可用、待安装：标题是「EVE-O Preview x.y.z 可用」，下面是发布说明；只提示的构建多一行原因；
/// - 下载中、核对中、安装中：标题不变，进度条与进度文字在说明下面；
/// - 重新启动中：标题换成「正在重新启动…」，启动失败时副标题请用户手动重新打开；
/// - 失败：副标题是失败原因（红字由界面按阶段决定），带着发布版时可以重试安装或打开发布页。
fn view(machine: &UpdateMachine, state: &UpdateState, language: AppLanguage) -> Option<UpdateView> {
    let text = eveo_l10n::updates(language);
    let current = text.current_version_line(version_label());
    let notify_only = match machine.capability() {
        InstallCapability::NotifyOnly(blocker) => {
            format!("{} {}", text.notify_only_intro(), blocker_text(blocker, language))
        }
        _ => String::new(),
    };
    // 发布说明：最新版加上中间版本（按正在运行的版本再过滤一次）。
    let notes_for = |release: &eveo_core::update::models::ReleaseInfo| {
        let mut versions: Vec<(&str, &str)> = vec![(release.version.as_str(), release.notes.as_str())];
        let intermediate = state
            .intermediate_notes
            .as_ref()
            .filter(|notes| notes.latest_version == release.version);
        if let Some(notes) = intermediate {
            versions.extend(
                notes
                    .entries
                    .iter()
                    .map(|e| (e.version.as_str(), e.notes.as_str())),
            );
        }
        let more = intermediate.is_some_and(|notes| notes.has_more);
        let blocks = eveo_ui::update::notes_blocks(language, &versions, |v| text.version_notes_title(v));
        (blocks, more)
    };
    let mut view = UpdateView {
        phase: PhaseKind::Checking,
        headline: String::new(),
        subtitle: current.clone(),
        notify_only: String::new(),
        test_feed: machine.feed().is_test_feed,
        notes: Vec::new(),
        more_on_release_page: false,
        progress: None,
        progress_text: String::new(),
        has_release: false,
        relaunch_failed: machine.relaunch_failed(),
    };
    match machine.phase() {
        UpdatePhase::Idle => return None,
        UpdatePhase::Checking => view.headline = text.status_checking().to_owned(),
        UpdatePhase::UpToDate(_) => {
            view.phase = PhaseKind::UpToDate;
            view.headline = text.status_up_to_date().to_owned();
        }
        UpdatePhase::Available(release) | UpdatePhase::ReadyToInstall(release) => {
            let ready = matches!(machine.phase(), UpdatePhase::ReadyToInstall(_));
            view.phase = if ready {
                PhaseKind::Ready
            } else {
                PhaseKind::Available
            };
            view.headline = text.headline(&release.version);
            if ready {
                view.subtitle = text.status_ready(&release.version);
            }
            view.notify_only = notify_only;
            (view.notes, view.more_on_release_page) = notes_for(release);
        }
        UpdatePhase::Downloading(release, progress) => {
            view.phase = PhaseKind::Downloading;
            view.headline = text.headline(&release.version);
            view.progress = progress
                .total
                .filter(|&total| total > 0)
                .map(|total| (progress.received as f64 / total as f64).min(1.0) as f32);
            let received = eveo_ui::update::byte_size(progress.received);
            let total = progress.total.map(eveo_ui::update::byte_size);
            view.progress_text = text.progress_downloading(&received, total.as_deref());
            (view.notes, view.more_on_release_page) = notes_for(release);
        }
        UpdatePhase::Verifying(release) | UpdatePhase::Installing(release) => {
            let installing = matches!(machine.phase(), UpdatePhase::Installing(_));
            view.phase = if installing {
                PhaseKind::Installing
            } else {
                PhaseKind::Verifying
            };
            view.headline = text.headline(&release.version);
            view.progress_text = if installing {
                text.progress_installing()
            } else {
                text.progress_verifying()
            }
            .to_owned();
            (view.notes, view.more_on_release_page) = notes_for(release);
        }
        UpdatePhase::Relaunching => {
            view.phase = PhaseKind::Relaunching;
            view.headline = text.progress_relaunching().to_owned();
            if machine.relaunch_failed() {
                view.subtitle = text.reopen_manually().to_owned();
            }
        }
        UpdatePhase::Failed(error, release) => {
            view.phase = PhaseKind::Failed;
            view.has_release = release.is_some();
            view.headline = release
                .as_ref()
                .map_or_else(|| text.window_title().to_owned(), |r| text.headline(&r.version));
            // 安装失败时补一句「当前版本没有变化」，让用户放心。
            view.subtitle = match release {
                Some(_) => format!(
                    "{} {}",
                    error_text(error, language),
                    text.current_version_unchanged()
                ),
                None => error_text(error, language),
            };
        }
    }
    Some(view)
}

/// 「通用」页的状态行与「立即检查」能否点。
///
/// 状态行只写一句话：窗口里的细节（发布说明、进度）不放进设置页。
/// 正在检查、下载或安装时「立即检查」不能点，免得用户以为点了没反应又连点几次。
fn settings_status(machine: &UpdateMachine, state: &UpdateState, language: AppLanguage) -> (String, bool) {
    let text = eveo_l10n::updates(language);
    if machine.capability() == InstallCapability::Unavailable {
        return (text.status_unavailable().to_owned(), false);
    }
    let status = match machine.phase() {
        UpdatePhase::Checking => text.status_checking().to_owned(),
        UpdatePhase::UpToDate(_) => text.status_up_to_date().to_owned(),
        UpdatePhase::Available(release) => text.status_available(&release.version),
        UpdatePhase::ReadyToInstall(release) => text.status_ready(&release.version),
        UpdatePhase::Downloading(release, _)
        | UpdatePhase::Verifying(release)
        | UpdatePhase::Installing(release) => text.headline(&release.version),
        UpdatePhase::Failed(error, _) => error_text(error, language),
        UpdatePhase::Relaunching => text.progress_relaunching().to_owned(),
        // 空闲时：被限流就说明，否则不写。
        UpdatePhase::Idle => match state.rate_limited_until.filter(|&until| until > wall_clock()) {
            Some(until) => text.status_rate_limited(&local_time(until)),
            None => String::new(),
        },
    };
    (status, !machine.is_busy())
}
