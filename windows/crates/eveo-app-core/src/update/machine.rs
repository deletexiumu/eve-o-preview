// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新流程的状态机，移植 macOS 的 UpdateController（v1.1 设计 8.5、8.6、9.2～9.5 节）。
// 状态机不做 I/O：每个入口改 `phase` 与传入的 state.json 更新记录，返回要应用层执行的命令
// （发检查请求、下载、安装、重新启动、显示窗口、托盘通知、删文件、打开网页）。命令的结果由应用层
// 经对应的入口交回（check_finished、progress、prepare_finished、install_finished）。
// state.json 的记录由调用方的 StateStore 持有，每次调用都传进来，状态机不留副本：
// 启动时的确认（update_launch）与这里改的是同一份数据，不会互相覆盖。
//
// 流程：
// - 启动：算出 capability；Unavailable 时什么都不做。否则恢复上次的状态（不发请求），10 秒后第一次醒来，
//   之后每小时醒一次，到时就检查（policy::is_check_due，启动时那一次按 1 小时的最小间隔）。
// - 检查失败（网络、状态码）不写 lastCheckAt，下一次醒来时重试。被限流时记下可以再试的时刻。
// - 发现新版本：用户发起的检查直接显示窗口；自动检查时，「自动安装」打开、能安装、这个版本没装失败过，
//   就在后台下载；否则进入「可用」并发一条托盘通知（每个版本每次运行只发一次）。
//   macOS 在这里弹出窗口（EVE 在前台时推迟）；Windows 改用托盘通知加托盘菜单项，不在游戏时弹窗。
// - 下载好：进入「待安装」。没有 EVE 客户端运行满 1 分钟时安装并重新启动；用户点托盘菜单的
//   「重新启动以更新」时立即安装；用户退出时安装但不重新启动。
// - 每次安装失败都写 lastInstall（失败），失败过的版本不再自动安装，只普通提示。
// - 「跳过此版本」只影响自动检查；「稍后」在失败后按记录重新定出阶段。
//
// 时间都是墙上时钟的秒数（Unix 时间），由调用方传入；测试里直接给数字。
//
// 阶段的转换（括号里是触发的入口）：
//   空闲 ──(check_now)──→ 检查中 ──(check_finished)──→ 已是最新 / 可用 / 失败
//   空闲 ──(tick 到时，自动检查)──→ 可用（只通知）或 下载中（自动安装）
//   可用 ──(install)──→ 下载中 ──(progress 收齐)──→ 核对中 ──(prepare_finished)──→ 安装中
//   下载中/核对中 ──(prepare_finished，后台下载)──→ 待安装
//   下载中/核对中 ──(cancel → prepare_finished(Cancelled))──→ 可用
//   待安装 ──(tick 空闲满 1 分钟 / restart_to_install)──→ 安装中 ──(install_finished)──→ 重新启动中
//   待安装 ──(quit)──→ 安装中（不重新启动）
//   安装中 ──(install_finished 失败)──→ 失败 ──(later)──→ 按记录重新定出（可用或空闲）
//   可用/待安装/失败 ──(skip)──→ 空闲
// 「忙」指下载中、核对中、安装中与重新启动中：这时不发检查请求，不响应第二次安装，开关的变化只记下不改阶段。
//
// 与 macOS 的差别：
// - 没有「演示模式」与 EVEO_UPDATE_UI_STATE 的调试入口：Windows 的界面截图工具直接用样例阶段画窗口。
// - macOS 的 isUsable 还核对 dmg 在缓存目录下；这里由应用层在删文件、读文件前核对路径，状态机只看版本。
// - 重新启动：macOS 用 NSWorkspace 打开新包、等 15 秒看旧实例是否还在；Windows 由应用层启动新 exe，
//   启动调用失败就立即报告（relaunch_did_fail），成功则本进程退出，新进程等本进程退出后才做单实例检查。

//! 更新流程的状态机。

use eveo_core::update::feed::{RELEASES_PAGE_URL, UpdateFeed, archive_name};
use eveo_core::update::history;
use eveo_core::update::install::InstallRecord;
use eveo_core::update::install::PendingSwap;
use eveo_core::update::models::{InstallCapability, ReleaseInfo, RunningApp, UpdateError};
use eveo_core::update::parser::ReleaseList;
use eveo_core::update::policy::{self, UpdateOffer, UpdateSkipReason};
use eveo_core::update::version::SemanticVersion;

use super::state::{PreparedUpdate, UpdateState};

/// 启动后第一次醒来前等的秒数。
pub const FIRST_CHECK_DELAY: f64 = 10.0;
/// 之后醒来的间隔（秒）。
pub const WAKE_INTERVAL: f64 = 3_600.0;
/// 没有 EVE 客户端运行满这么多秒时，自动安装已下载好的更新。
pub const IDLE_INSTALL_DELAY: f64 = 60.0;

/// 下载的进度。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    /// 已收到的字节数。
    pub received: u64,
    /// 总字节数；不知道时是 None。
    pub total: Option<u64>,
}

/// 界面阶段：更新窗口、设置页与托盘菜单按它显示。
///
/// 窗口按阶段选择内容：检查中与已是最新只有一行说明；可用与失败（带发布版时）显示发布说明与按钮；
/// 下载中、核对中、安装中与重新启动中显示进度，只有下载中与核对中能取消。
#[derive(Debug, Clone, PartialEq)]
pub enum UpdatePhase {
    /// 没有要显示的东西。
    Idle,
    /// 用户发起的检查正在进行。
    Checking,
    /// 用户发起的检查：已是最新，关联值是检查的时刻。
    UpToDate(f64),
    /// 有新版本可以安装。
    Available(ReleaseInfo),
    /// 下载中。
    Downloading(ReleaseInfo, Progress),
    /// 下载完，核对签名与校验和、解包中。
    Verifying(ReleaseInfo),
    /// 已下载好，等空闲或退出时安装。
    ReadyToInstall(ReleaseInfo),
    /// 替换 exe 中。
    Installing(ReleaseInfo),
    /// 已换好，正在启动新版。
    Relaunching,
    /// 检查或安装失败；安装失败时带着发布版。
    Failed(UpdateError, Option<ReleaseInfo>),
}

/// 一次检查的结果，由应用层的检查任务交回。
#[derive(Debug, Clone, PartialEq)]
pub enum CheckOutcome {
    /// 200：解析好的列表与答复的 ETag。
    List(ReleaseList, Option<String>),
    /// 304：与上次相同。
    NotModified,
    /// 被限流，关联值是可以再试的时刻。
    RateLimited(Option<f64>),
    /// 失败。
    Failed(UpdateError),
}

/// 要应用层执行的命令。
///
/// 执行的约定：
/// - Check、Prepare 在后台线程里做（网络与解包会阻塞），结果经主线程的队列交回对应的入口；
/// - Install 在后台线程里做，退出时安装的那一次由主线程同步等待，最多 8 秒；
/// - 每次调用之后应用层把 state 写盘（StateStore 只在内容变了时才写），Relaunch 之前一定要先写盘：
///   新版启动后靠 state.json 里的待确认记录判断要不要回滚；
/// - DeleteFile 的路径来自 state.json，删之前核对它在更新缓存目录下，不在时只记日志；
/// - 命令按返回的顺序执行。
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// 取 Release 列表；有缓存的发布信息时带上 ETag。结果交给 check_finished。
    Check {
        /// If-None-Match 的值。
        etag: Option<String>,
    },
    /// 下载、核对并解出新 exe。进度交给 progress，结果交给 prepare_finished。
    Prepare(ReleaseInfo),
    /// 取消进行中的下载。
    CancelPrepare,
    /// 替换 exe。结果交给 install_finished。
    Install {
        /// 要装的新 exe。
        prepared: PreparedUpdate,
        /// 是否在换好后启动新版（退出时安装为假）。
        relaunch: bool,
    },
    /// 启动新版并退出本进程。启动失败时调用 relaunch_failed。
    Relaunch,
    /// 显示更新窗口；activate 为真时切到前台（用户点出来的）。
    ShowWindow {
        /// 是否激活窗口。
        activate: bool,
    },
    /// 托盘通知：有新版本可用，关联值是版本号。
    Notify(String),
    /// 删掉更新缓存目录里的一个文件（应用层要先核对它在缓存目录下）。
    DeleteFile(String),
    /// 用默认浏览器打开网页。
    OpenUrl(String),
}

/// 托盘菜单里与更新有关的提示项。
///
/// 托盘菜单总有「检查更新…」（更新功能停用时没有）；有提示项时放在菜单顶部，与崩溃报告的提示项并列。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuHint {
    /// 没有提示项。
    None,
    /// 「有可用更新：<版本>…」，点了显示更新窗口。
    Available(String),
    /// 「重新启动以更新到 <版本>」，点了立即安装。
    Ready(String),
}

/// 两个开关：自动检查与自动安装。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Switches {
    /// general.checkForUpdates。
    pub check: bool,
    /// general.autoInstallUpdates。
    pub auto_install: bool,
}

/// 正在进行的安装（或为安装而做的下载）。
#[derive(Debug, Clone, PartialEq)]
struct InstallJob {
    /// 要装的发布版。
    release: ReleaseInfo,
    /// 换好后是否启动新版。
    relaunch: bool,
    /// 是用户点的（失败时弹窗口）还是自动的。
    user_initiated: bool,
}

/// 更新流程的状态机。
#[derive(Debug, Clone)]
pub struct UpdateMachine {
    /// 界面阶段。
    phase: UpdatePhase,
    /// 能否自动安装。
    capability: InstallCapability,
    /// 正在运行的应用。
    running: RunningApp,
    /// 检查地址。
    feed: UpdateFeed,
    /// 两个开关。
    switches: Switches,
    /// 是否有一次检查在进行。
    is_checking: bool,
    /// 进行中的检查是否用户发起。
    check_user_initiated: bool,
    /// 用户发起检查前的阶段：「已下载好」要按检查前的看。
    phase_before_check: Option<UpdatePhase>,
    /// 下一次醒来的时刻。
    next_wake_at: f64,
    /// 下一次醒来是否算启动时的检查。
    wake_at_launch: bool,
    /// 没有 EVE 客户端运行的起始时刻。
    idle_since: Option<f64>,
    /// 正在进行的安装。
    job: Option<InstallJob>,
    /// 应用已开始退出。
    is_terminating: bool,
    /// 换好之后启动新版失败。
    relaunch_failed: bool,
    /// 这次运行已为哪个版本发过托盘通知。
    notified_version: Option<String>,
}

impl UpdateMachine {
    /// 建状态机。调用 start 之后才开始工作。
    ///
    /// capability 在这里算一次：正在运行的版本、公钥与 exe 所在位置在一次运行里不会变。
    /// 用户把 exe 挪到别处要重启应用才生效，与 macOS 相同。
    pub fn new(running: RunningApp, feed: UpdateFeed, switches: Switches) -> Self {
        let capability = policy::capability(&running, feed.is_test_feed);
        Self {
            phase: UpdatePhase::Idle,
            capability,
            running,
            feed,
            switches,
            is_checking: false,
            check_user_initiated: false,
            phase_before_check: None,
            next_wake_at: f64::INFINITY,
            wake_at_launch: true,
            idle_since: None,
            job: None,
            is_terminating: false,
            relaunch_failed: false,
            notified_version: None,
        }
    }

    /// 界面阶段。
    pub fn phase(&self) -> &UpdatePhase {
        &self.phase
    }

    /// 能否自动安装。
    pub fn capability(&self) -> InstallCapability {
        self.capability
    }

    /// 检查地址。
    pub fn feed(&self) -> &UpdateFeed {
        &self.feed
    }

    /// 换好之后启动新版是否失败（窗口提示用户手动重新打开）。
    pub fn relaunch_failed(&self) -> bool {
        self.relaunch_failed
    }

    /// 正在下载、核对、安装或重新启动。
    pub fn is_busy(&self) -> bool {
        matches!(
            self.phase,
            UpdatePhase::Downloading(..)
                | UpdatePhase::Verifying(_)
                | UpdatePhase::Installing(_)
                | UpdatePhase::Relaunching
        )
    }

    /// 当前阶段对应的发布版。
    pub fn current_release(&self) -> Option<&ReleaseInfo> {
        match &self.phase {
            UpdatePhase::Available(release)
            | UpdatePhase::Downloading(release, _)
            | UpdatePhase::Verifying(release)
            | UpdatePhase::ReadyToInstall(release)
            | UpdatePhase::Installing(release) => Some(release),
            UpdatePhase::Failed(_, release) => release.as_ref(),
            UpdatePhase::Idle
            | UpdatePhase::Checking
            | UpdatePhase::UpToDate(_)
            | UpdatePhase::Relaunching => None,
        }
    }

    /// 托盘菜单的提示项。
    pub fn menu_hint(&self) -> MenuHint {
        match &self.phase {
            UpdatePhase::Available(release) => MenuHint::Available(release.version.clone()),
            UpdatePhase::ReadyToInstall(release) => MenuHint::Ready(release.version.clone()),
            _ => MenuHint::None,
        }
    }

    // MARK: 启动与恢复

    /// 恢复上次的状态（不发请求），安排第一次醒来。prepared_exists：state 里记的新 exe 文件还在。
    ///
    /// 应用层在建好 StateStore、读完配置之后调用一次。返回的命令只会是删文件（过时的新 exe）。
    /// 恢复之后托盘菜单立即有对应的提示项：1 小时内重启，「有可用更新」或「重新启动以更新」仍在。
    pub fn start(&mut self, state: &mut UpdateState, now: f64, prepared_exists: bool) -> Vec<Command> {
        let mut commands = Vec::new();
        if self.capability == InstallCapability::Unavailable {
            return commands;
        }
        // 测试地址留下的缓存在正式地址下不认（反之亦然），连同 ETag 与中间版本的说明一起丢掉。
        if state
            .cached_release
            .as_ref()
            .is_some_and(|cached| !self.feed.accepts(&cached.page_url))
        {
            state.cached_release = None;
            state.etag = None;
            state.intermediate_notes = None;
        }
        // 记下的新 exe 不见了或不再适用（已装上、版本过时）：清掉记录，文件还在就删掉。
        if let Some(prepared) = state.prepared.clone()
            && !(prepared_exists && self.is_usable(&prepared, state))
        {
            state.prepared = None;
            if prepared_exists {
                commands.push(Command::DeleteFile(prepared.exe_path));
            }
        }
        // 中间版本的说明是为某个最新版取的；最新版变了就作废。
        let latest = state.cached_release.as_ref().map(|r| r.version.as_str());
        if state
            .intermediate_notes
            .as_ref()
            .is_some_and(|notes| Some(notes.latest_version.as_str()) != latest)
        {
            state.intermediate_notes = None;
        }
        self.rederive(state);
        self.next_wake_at = now + FIRST_CHECK_DELAY;
        self.wake_at_launch = true;
        commands
    }

    /// 已下载的新 exe 还能不能用：版本大于正在运行的版本，且与缓存的最新版相同。文件是否存在由调用方看。
    fn is_usable(&self, prepared: &PreparedUpdate, state: &UpdateState) -> bool {
        let Some(version) = SemanticVersion::parse(&prepared.version) else {
            return false;
        };
        let newer = policy::comparable_version(&self.running).is_some_and(|running| running < version);
        let cached = state
            .cached_release
            .as_ref()
            .and_then(|release| SemanticVersion::parse(&release.version));
        newer && cached == Some(version)
    }

    /// 这个版本是否装失败过（失败过的版本不再自动安装）。
    fn has_failed_install(state: &UpdateState, version: &str) -> bool {
        state.last_install.as_ref().is_some_and(|record| {
            !record.succeeded && SemanticVersion::parse(&record.version) == SemanticVersion::parse(version)
        })
    }

    /// 只按记录与开关定出阶段，不发请求：
    /// 已下载好、两个开关都打开、能安装、没装失败过时是「待安装」；否则缓存的发布版仍该提示时是「可用」；否则空闲。
    fn rederive(&mut self, state: &UpdateState) {
        let ready = state.prepared.as_ref().filter(|prepared| {
            self.switches.check
                && self.switches.auto_install
                && self.capability == InstallCapability::CanInstall
                && self.is_usable(prepared, state)
                && !Self::has_failed_install(state, &prepared.version)
        });
        if let (Some(_), Some(release)) = (ready, &state.cached_release) {
            self.phase = UpdatePhase::ReadyToInstall(release.clone());
            self.idle_since = None;
            return;
        }
        let offer = state
            .cached_release
            .as_ref()
            .filter(|_| self.switches.check)
            .map(|cached| policy::offer(cached, &self.running, state.skipped_version.as_deref(), false));
        self.phase = match offer {
            Some(UpdateOffer::Offer(release)) => UpdatePhase::Available(release),
            _ => UpdatePhase::Idle,
        };
    }

    // MARK: 定时

    /// 定时器里调用（间隔不限，每秒一次即可）。clients_running：现在有没有 EVE 客户端在运行。
    ///
    /// 空闲安装与定时检查都在这里：前者每次都看（客户端的进出要及时反映），后者只在到了醒来的时刻才看。
    /// 两者同一次只做一件：空闲安装开始后本次不再检查，安装中 is_busy 为真，之后的检查也会让开。
    pub fn tick(&mut self, state: &mut UpdateState, now: f64, clients_running: bool) -> Vec<Command> {
        let mut commands = Vec::new();
        if self.capability == InstallCapability::Unavailable {
            return commands;
        }
        // 待安装时看空闲：没有客户端运行的时长从第一次看到「没有」时算起，看到有客户端就清零。
        if matches!(self.phase, UpdatePhase::ReadyToInstall(_)) && !self.is_terminating {
            if clients_running {
                self.idle_since = None;
            } else {
                let since = *self.idle_since.get_or_insert(now);
                if now - since >= IDLE_INSTALL_DELAY {
                    self.idle_since = None;
                    commands.extend(self.restart_to_install(state));
                    return commands;
                }
            }
        } else {
            self.idle_since = None;
        }
        if now >= self.next_wake_at {
            self.next_wake_at = now + WAKE_INTERVAL;
            let at_launch = std::mem::replace(&mut self.wake_at_launch, false);
            commands.extend(self.automatic_check_if_due(state, now, at_launch));
            // 只在启动后的第一次醒来补一次：之后每小时的醒来要么到时检查（检查完成时自己决定是否下载），
            // 要么什么都不做；已经在检查或下载时 commands 非空或 is_checking 为真，不会重复发 Prepare。
            if at_launch && commands.is_empty() && !self.is_checking {
                commands.extend(self.resume_cached_download(state));
            }
        }
        commands
    }

    /// 启动后第一次醒来、距上次检查不到 1 小时而不检查时：缓存里的版本仍该提示、两个开关都打开、能安装、
    /// 没装失败过，就接着在后台下载。否则上次运行检查到新版本但没下完就退出的话，要等下一次检查（最长 24 小时）
    /// 才会开始下载。条件与检查完成时自动下载的条件相同（evaluate）。
    fn resume_cached_download(&mut self, state: &mut UpdateState) -> Vec<Command> {
        let UpdatePhase::Available(release) = &self.phase else {
            return Vec::new();
        };
        if !(self.switches.check
            && self.switches.auto_install
            && self.capability == InstallCapability::CanInstall
            && !Self::has_failed_install(state, &release.version))
        {
            return Vec::new();
        }
        let release = release.clone();
        self.prepare_in_background(state, release)
    }

    /// 自动检查：开关打开、没有在忙、到时才检查。
    fn automatic_check_if_due(&mut self, state: &UpdateState, now: f64, at_launch: bool) -> Vec<Command> {
        if !self.switches.check || self.is_busy() || self.is_checking {
            return Vec::new();
        }
        if !policy::is_check_due(now, state.last_check_at, state.rate_limited_until, at_launch) {
            return Vec::new();
        }
        self.begin_check(state, false)
    }

    /// 开始一次检查：只在有缓存的发布信息时带 ETag（304 要靠缓存继续判断）。
    fn begin_check(&mut self, state: &UpdateState, user_initiated: bool) -> Vec<Command> {
        self.is_checking = true;
        self.check_user_initiated = user_initiated;
        let etag = state.cached_release.as_ref().and(state.etag.clone());
        vec![Command::Check { etag }]
    }

    /// 两个开关变了。自动检查从关变开时立即按非启动时的间隔判断一次。
    pub fn switches_changed(
        &mut self,
        state: &mut UpdateState,
        now: f64,
        switches: Switches,
    ) -> Vec<Command> {
        let was_checking = self.switches.check;
        self.switches = switches;
        if self.capability == InstallCapability::Unavailable || self.is_busy() {
            return Vec::new();
        }
        // 开关影响「待安装」与「可用」：不在忙、也不在显示检查或失败的结果时重新定出阶段。
        if !matches!(
            self.phase,
            UpdatePhase::Checking | UpdatePhase::UpToDate(_) | UpdatePhase::Failed(..)
        ) {
            self.rederive(state);
        }
        if !was_checking && switches.check {
            return self.automatic_check_if_due(state, now, false);
        }
        Vec::new()
    }

    // MARK: 检查

    /// 立即检查一次（菜单或设置页的按钮）。用户发起时不看间隔；被限流时不发请求，窗口直接显示限流的说明。
    ///
    /// 正在下载或安装时不发第二个请求，只把窗口切到前台，让用户看到进度。
    /// 检查前的阶段记在 phase_before_check：答复回来时「已下载好」与否要按检查前的阶段判断。
    pub fn check_now(&mut self, state: &mut UpdateState, now: f64) -> Vec<Command> {
        if self.capability == InstallCapability::Unavailable {
            return Vec::new();
        }
        if self.is_busy() || self.is_checking {
            return vec![Command::ShowWindow { activate: true }];
        }
        if let Some(until) = state.rate_limited_until.filter(|&until| until > now) {
            self.phase = UpdatePhase::Failed(UpdateError::RateLimited(Some(until)), None);
            return vec![Command::ShowWindow { activate: true }];
        }
        self.phase_before_check = Some(std::mem::replace(&mut self.phase, UpdatePhase::Checking));
        let mut commands = vec![Command::ShowWindow { activate: true }];
        commands.extend(self.begin_check(state, true));
        commands
    }

    /// 检查的结果：按 macOS 8.4 节的表写记录，再按 8.6 节决定提示。
    ///
    /// outcome 来自应用层的检查任务；不在检查中时（例如重复交回）忽略。
    /// 自动检查的失败与限流都不改界面：用户没有发起，不该看到错误；下一次醒来时再试。
    pub fn check_finished(
        &mut self,
        state: &mut UpdateState,
        now: f64,
        outcome: CheckOutcome,
    ) -> Vec<Command> {
        if !self.is_checking {
            return Vec::new();
        }
        self.is_checking = false;
        let user = self.check_user_initiated;
        let previous = self
            .phase_before_check
            .take()
            .unwrap_or_else(|| self.phase.clone());
        // 等答复期间用户可能已点了「安装更新」：之后只写记录，不改阶段，免得盖掉进度。
        let keep_phase = self.is_busy();
        let mut commands = Vec::new();
        match outcome {
            CheckOutcome::List(list, etag) => {
                state.last_check_at = Some(now);
                state.rate_limited_until = None;
                match policy::latest(&list.releases, &self.running).cloned() {
                    Some(release) => {
                        state.etag = etag;
                        state.intermediate_notes = self.intermediate(&list, &release);
                        state.cached_release = Some(release.clone());
                        if !keep_phase {
                            commands.extend(self.evaluate(state, release, user, now, previous));
                        }
                    }
                    // 还没有适用的版本（例如只有 macOS 版）：清掉缓存，下次取完整答复。
                    None => {
                        state.etag = None;
                        state.cached_release = None;
                        state.intermediate_notes = None;
                        if !keep_phase {
                            commands.extend(self.no_offer(UpdateSkipReason::NotNewer, user, now, previous));
                        }
                    }
                }
            }
            CheckOutcome::NotModified => {
                state.last_check_at = Some(now);
                match state.cached_release.clone() {
                    Some(cached) if !keep_phase => {
                        commands.extend(self.evaluate(state, cached, user, now, previous));
                    }
                    Some(_) => {}
                    // 304 却没有缓存（不应发生）：丢掉 ETag，下次取完整答复。
                    None => {
                        state.etag = None;
                        if !keep_phase {
                            commands.extend(self.no_offer(UpdateSkipReason::NotNewer, user, now, previous));
                        }
                    }
                }
            }
            CheckOutcome::RateLimited(until) => {
                state.rate_limited_until = until;
                if !keep_phase {
                    self.phase = if user {
                        UpdatePhase::Failed(UpdateError::RateLimited(until), None)
                    } else {
                        previous
                    };
                }
                if user {
                    commands.push(Command::ShowWindow { activate: true });
                }
            }
            CheckOutcome::Failed(error) => {
                if !keep_phase {
                    self.phase = if user {
                        UpdatePhase::Failed(error, None)
                    } else {
                        previous
                    };
                }
                if user {
                    commands.push(Command::ShowWindow { activate: true });
                }
            }
        }
        commands
    }

    /// 从同一页列表挑出最新版与正在运行的版本之间的说明。版本号解析不了时没有。
    fn intermediate(
        &self,
        list: &ReleaseList,
        latest: &ReleaseInfo,
    ) -> Option<history::IntermediateReleaseNotes> {
        let running = policy::comparable_version(&self.running)?;
        let latest_version = SemanticVersion::parse(&latest.version)?;
        let channel = policy::channel_releases(&list.releases, &self.running);
        Some(history::record(&channel, list.is_full, &running, &latest_version))
    }

    /// 按 policy::offer 决定提示、后台下载或什么都不做。previous 是检查前的阶段。
    fn evaluate(
        &mut self,
        state: &mut UpdateState,
        release: ReleaseInfo,
        user: bool,
        now: f64,
        previous: UpdatePhase,
    ) -> Vec<Command> {
        let offered = match policy::offer(&release, &self.running, state.skipped_version.as_deref(), user) {
            UpdateOffer::Offer(offered) => offered,
            UpdateOffer::None(reason) => return self.no_offer(reason, user, now, previous),
        };
        // 同一个版本已下载好、等待安装：保持原样。
        if let UpdatePhase::ReadyToInstall(ready) = &previous
            && ready.version == offered.version
        {
            self.phase = previous;
            return if user {
                vec![Command::ShowWindow { activate: true }]
            } else {
                Vec::new()
            };
        }
        if user {
            self.phase = UpdatePhase::Available(offered);
            return vec![Command::ShowWindow { activate: true }];
        }
        if self.switches.auto_install
            && self.capability == InstallCapability::CanInstall
            && !Self::has_failed_install(state, &offered.version)
        {
            return self.prepare_in_background(state, offered);
        }
        self.prompt_automatically(offered)
    }

    /// 自动检查的普通提示：「可用」与一条托盘通知（同一个版本每次运行只通知一次）。
    fn prompt_automatically(&mut self, release: ReleaseInfo) -> Vec<Command> {
        let first_time = self.notified_version.as_deref() != Some(release.version.as_str());
        self.notified_version = Some(release.version.clone());
        let version = release.version.clone();
        self.phase = UpdatePhase::Available(release);
        if first_time {
            vec![Command::Notify(version)]
        } else {
            Vec::new()
        }
    }

    /// 不提示：用户发起的检查显示「已是最新」；自动检查不显示任何东西。
    fn no_offer(
        &mut self,
        reason: UpdateSkipReason,
        user: bool,
        now: f64,
        previous: UpdatePhase,
    ) -> Vec<Command> {
        let show = if user {
            vec![Command::ShowWindow { activate: true }]
        } else {
            Vec::new()
        };
        // 已下载好、等待安装时保持原样。
        if matches!(previous, UpdatePhase::ReadyToInstall(_)) {
            self.phase = previous;
            return show;
        }
        // 自动检查遇到「跳过此版本」时不说「已是最新」：用户知道有新版本。
        self.phase = if reason == UpdateSkipReason::SkippedByUser || !user {
            UpdatePhase::Idle
        } else {
            UpdatePhase::UpToDate(now)
        };
        show
    }

    // MARK: 下载

    /// 下载开始前的进度：0 字节，总数取压缩包附件声明的大小。
    fn initial_progress(release: &ReleaseInfo) -> Progress {
        Progress {
            received: 0,
            total: release
                .asset(&archive_name(&release.version))
                .and_then(|asset| asset.size),
        }
    }

    /// 自动安装的后台下载，不显示窗口。已有可用的下载时直接进入「待安装」。
    fn prepare_in_background(&mut self, state: &mut UpdateState, release: ReleaseInfo) -> Vec<Command> {
        if self.capability != InstallCapability::CanInstall || self.is_busy() {
            return self.prompt_automatically(release);
        }
        if let Some(prepared) = &state.prepared
            && prepared.version == release.version
            && self.is_usable(prepared, state)
        {
            self.become_ready(release);
            return Vec::new();
        }
        self.job = None;
        self.phase = UpdatePhase::Downloading(release.clone(), Self::initial_progress(&release));
        vec![Command::Prepare(release)]
    }

    /// 下载好、等待安装。
    fn become_ready(&mut self, release: ReleaseInfo) {
        self.phase = UpdatePhase::ReadyToInstall(release);
        self.idle_since = None;
    }

    /// 下载的进度：收齐时进入「核对中」。不在下载时（晚到的回调）忽略。
    ///
    /// 进度只用于显示，不写 state.json。应用层可以按需节流（例如每 64 KiB 交一次），这里不再限频。
    pub fn progress(&mut self, progress: Progress) {
        let release = match &self.phase {
            UpdatePhase::Downloading(release, _) | UpdatePhase::Verifying(release) => release.clone(),
            _ => return,
        };
        self.phase = if progress.total.is_some_and(|total| progress.received >= total) {
            UpdatePhase::Verifying(release)
        } else {
            UpdatePhase::Downloading(release, progress)
        };
    }

    /// 下载、核对与解包的结果。
    ///
    /// 成功时 prepared 已经通过了签名、校验和、版本与架构的核对，文件在更新缓存目录里。
    /// 为安装而下载的（job 有值）接着安装；后台下载的进入「待安装」。
    pub fn prepare_finished(
        &mut self,
        state: &mut UpdateState,
        now: f64,
        result: Result<PreparedUpdate, UpdateError>,
    ) -> Vec<Command> {
        let release = match &self.phase {
            UpdatePhase::Downloading(release, _) | UpdatePhase::Verifying(release) => release.clone(),
            _ => return Vec::new(),
        };
        let job = self.job.take();
        match result {
            Ok(prepared) => {
                state.prepared = Some(prepared.clone());
                match job {
                    // 为安装而下载的：接着安装。
                    Some(job) => self.begin_install(prepared, job),
                    None => {
                        self.become_ready(release);
                        Vec::new()
                    }
                }
            }
            Err(UpdateError::Cancelled) => {
                self.phase = UpdatePhase::Available(release);
                Vec::new()
            }
            Err(error) => match job {
                // 用户点的安装：记失败、显示失败的原因。
                Some(job) => {
                    self.record_failure(state, now, &error, &job.release.version);
                    self.phase = UpdatePhase::Failed(error, Some(job.release));
                    vec![Command::ShowWindow { activate: false }]
                }
                // 后台下载失败：退回普通提示。
                None => self.prompt_automatically(release),
            },
        }
    }

    /// 取消进行中的下载或核对。安装开始后不能取消。
    pub fn cancel(&mut self) -> Vec<Command> {
        match self.phase {
            UpdatePhase::Downloading(..) | UpdatePhase::Verifying(_) => vec![Command::CancelPrepare],
            _ => Vec::new(),
        }
    }

    // MARK: 安装

    /// 窗口的「安装更新」：下载（已有可用的下载时跳过）、安装、重新启动。只提示的构建改为打开发布页。
    ///
    /// 从「可用」「待安装」或失败的阶段都能点；忙的时候（连点、按钮与菜单项同时）第二次什么都不做：
    /// 第一次调用已同步把阶段改成下载中或安装中。
    pub fn install(&mut self, state: &mut UpdateState) -> Vec<Command> {
        match self.capability {
            InstallCapability::Unavailable => Vec::new(),
            InstallCapability::NotifyOnly(_) => vec![self.release_page_command(state)],
            InstallCapability::CanInstall => match self.current_release().cloned() {
                Some(release) if !self.is_busy() => self.start_install(state, release, true, true),
                _ => Vec::new(),
            },
        }
    }

    /// 托盘菜单的「重新启动以更新」，以及空闲时的自动安装。
    pub fn restart_to_install(&mut self, state: &mut UpdateState) -> Vec<Command> {
        if self.capability != InstallCapability::CanInstall || self.is_busy() || self.is_terminating {
            return Vec::new();
        }
        match self.phase.clone() {
            UpdatePhase::ReadyToInstall(release) => self.start_install(state, release, true, false),
            _ => Vec::new(),
        }
    }

    /// 定出起始阶段：已有可用的下载时直接安装，否则先下载。不能用的旧下载在这里丢掉。
    fn start_install(
        &mut self,
        state: &mut UpdateState,
        release: ReleaseInfo,
        relaunch: bool,
        user_initiated: bool,
    ) -> Vec<Command> {
        let mut commands = Vec::new();
        let job = InstallJob {
            release: release.clone(),
            relaunch,
            user_initiated,
        };
        match state.prepared.clone() {
            Some(prepared) if prepared.version == release.version && self.is_usable(&prepared, state) => {
                commands.extend(self.begin_install(prepared, job));
            }
            stale => {
                if let Some(stale) = stale {
                    state.prepared = None;
                    commands.push(Command::DeleteFile(stale.exe_path));
                }
                self.phase = UpdatePhase::Downloading(release.clone(), Self::initial_progress(&release));
                self.job = Some(job);
                commands.push(Command::Prepare(release));
            }
        }
        commands
    }

    /// 进入「安装中」并发出替换的命令。
    fn begin_install(&mut self, prepared: PreparedUpdate, job: InstallJob) -> Vec<Command> {
        self.phase = UpdatePhase::Installing(job.release.clone());
        let relaunch = job.relaunch;
        self.job = Some(job);
        vec![Command::Install { prepared, relaunch }]
    }

    /// 替换的结果。成功时 swap 是已写好的待确认记录（应用层要在启动新版前把记录写盘）。
    ///
    /// 成功：新 exe 已放到正式文件名，旧的成了 `.old`，state 里写好了待确认的替换；应用层写盘后执行 Relaunch。
    /// 失败：exe 没有变（平台层的 replace_exe 会尽量恢复原样），记一条失败的安装记录。
    pub fn install_finished(
        &mut self,
        state: &mut UpdateState,
        now: f64,
        result: Result<PendingSwap, UpdateError>,
    ) -> Vec<Command> {
        let Some(job) = self.job.take() else {
            return Vec::new();
        };
        let prepared = state.prepared.take();
        match result {
            Ok(swap) => {
                state.pending_swap = Some(swap);
                // 新 exe 已经放到位，缓存里的那份没有用了。
                let mut commands: Vec<Command> = prepared
                    .map(|p| Command::DeleteFile(p.exe_path))
                    .into_iter()
                    .collect();
                if job.relaunch && !self.is_terminating {
                    self.phase = UpdatePhase::Relaunching;
                    commands.push(Command::Relaunch);
                }
                commands
            }
            Err(error) => {
                self.record_failure(state, now, &error, &job.release.version);
                // 缓存里的 exe 坏了（校验和不符、读不出）就丢掉，下次重新下载；别的错误（被占用、没权限）留着再试。
                let broken = matches!(
                    error,
                    UpdateError::ChecksumMismatch | UpdateError::ArchiveInvalid(_)
                );
                let mut commands = Vec::new();
                match prepared {
                    Some(prepared) if broken => commands.push(Command::DeleteFile(prepared.exe_path)),
                    other => state.prepared = other,
                }
                if self.is_terminating {
                    return commands;
                }
                self.phase = UpdatePhase::Failed(error, Some(job.release));
                commands.push(Command::ShowWindow {
                    activate: job.user_initiated,
                });
                commands
            }
        }
    }

    /// 换好之后启动新版失败：窗口提示用户手动重新打开。
    pub fn relaunch_did_fail(&mut self) -> Vec<Command> {
        self.relaunch_failed = true;
        vec![Command::ShowWindow { activate: true }]
    }

    /// 记一次失败：lastInstall（失败）。用户取消不算失败。
    fn record_failure(&self, state: &mut UpdateState, now: f64, error: &UpdateError, version: &str) {
        if *error == UpdateError::Cancelled {
            return;
        }
        state.last_install = Some(InstallRecord {
            version: version.to_owned(),
            from_version: self.running.build_label.clone(),
            at: now,
            succeeded: false,
            error_code: Some(error.code().to_owned()),
        });
    }

    /// 退出前调用：自动安装已下载好时安装，不重新启动。返回的命令由应用层同步执行（有时限）。
    ///
    /// 条件全部成立才安装：两个开关都打开、能安装、有可用的下载、这个版本没装失败过、不在忙。
    /// 退出时只换文件不启动新版：用户要退出，不该又自己起来；下次用户打开的就是新版。
    pub fn quit(&mut self, state: &mut UpdateState) -> Vec<Command> {
        self.is_terminating = true;
        if self.capability != InstallCapability::CanInstall
            || !self.switches.check
            || !self.switches.auto_install
            || self.is_busy()
        {
            return Vec::new();
        }
        let (Some(prepared), Some(release)) = (state.prepared.clone(), state.cached_release.clone()) else {
            return Vec::new();
        };
        if !self.is_usable(&prepared, state) || Self::has_failed_install(state, &prepared.version) {
            return Vec::new();
        }
        let job = InstallJob {
            release,
            relaunch: false,
            user_initiated: false,
        };
        self.begin_install(prepared, job)
    }
}

#[path = "machine_buttons.rs"]
mod buttons;

#[cfg(test)]
#[path = "machine_tests.rs"]
mod tests;
