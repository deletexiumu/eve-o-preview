// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告在应用里的流程，对应 macOS 的 ProblemReportController（v1.1 设计 7.1 节）：
// 1. 打开（托盘的「报告问题…」、「通用」页的按钮、崩溃后的托盘提示与通知）：建窗口、显示收集中，
//    在主线程上取快照：运行时摘要、配置摘要、角色名（全部配置方案加上在线的客户端）。
// 2. 后台线程收集：系统信息、本机名字、环境报告、日志与 WER 报告，全部脱敏（eveo-app-core 的 report::collect）。
//    结果经通道交回，在定时器里取。
// 3. 窗口显示文件列表与预览。用户确认之前不写任何文件、不打开浏览器。
// 4. 「只生成报告」或「生成报告并打开 GitHub」：把勾选的项加上 manifest.json 写成 Reports 下的 zip，
//    在资源管理器里选中它；选了后者再打开预填的 Issue 地址（标题与正文也经脱敏）。崩溃情境下清掉 pendingCrash。
//    失败时窗口显示原因，不打开浏览器。
// 5. 「以后再说」「取消」与关窗口：崩溃的提示保留；「不报告」：清掉 pendingCrash，把那次会话记进不再提示的名单。
// 日志只记情境、文件个数与结果，不记路径与地址。

//! 问题报告窗口的流程。

use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver};

use eveo_app_core::log::Logger;
use eveo_app_core::report::{self, CollectRequest, CrashSource, ManifestInfo, ReportItem, zip::DosTime};
use eveo_app_core::state_store::PendingCrash;
use eveo_core::chat_log::ChatLogStatus;
use eveo_core::combat_log::CombatLogStatus;
use eveo_core::diagnostics::issue::{self, problem_report_draft};
use eveo_core::diagnostics::redactor::{RedactionTerms, Redactor, character_names};
use eveo_core::diagnostics::summary::{
    AppEnvironment, DiagnosticsBundlePlanner, EnvironmentReport, RuntimeSummary, config_summary, pretty_json,
};
use eveo_core::model::ClientIdentity;
use eveo_core::support::time::civil_from_days;
use eveo_platform_win::{activation, appearance, system_info};
use eveo_ui::report::{FileKind, FileView, ReportState};
use slint::ComponentHandle;

use super::intel::wall_clock;
use super::logging::build_label;
use super::{App, Input, Runtime, post, shell};

/// 问题报告的日志。
const LOG: Logger = Logger::new("Report");

/// 新建 Issue 地址的上限（字节）。macOS 用 6000；Windows 上地址交给 ShellExecuteW 再转给浏览器，
/// 超过 INTERNET_MAX_URL_LENGTH（2083）的地址可能被截断或打不开，留些余量取 2000。
/// 放不下时 issue_url 先整段省掉可选的小节，再逐行删环境信息；完整的一份在压缩包的 summary.md 里。
const ISSUE_URL_BYTES: usize = 2000;
/// report.slint 里窗口的首选尺寸（逻辑像素），首次显示时居中用。
const REPORT_SIZE: (f64, f64) = (800.0, 560.0);

/// 报告窗口发给应用的输入。
#[derive(Debug, Clone)]
pub(super) enum ReportInput {
    /// 勾选或取消勾选一行。
    Toggled(usize, bool),
    /// 选中一行。
    Select(usize),
    /// 生成报告；为真时随后打开 GitHub。
    Create(bool),
    /// 取消、以后再说或关窗口。
    Dismiss,
    /// 不报告（崩溃情境）。
    DontReport,
    /// 完成页：在资源管理器中显示。
    Reveal,
    /// 完成页：再次打开 GitHub。
    OpenIssue,
    /// 完成页：关闭。
    Close,
}

/// 后台收集的结果。
struct Collected {
    /// 环境报告（Issue 正文要用）。
    environment: EnvironmentReport,
    /// 脱敏后的预览项。
    items: Vec<ReportItem>,
    /// 脱敏的词表（Issue 的标题与正文也要用）。
    terms: RedactionTerms,
}

/// 一个打开着的报告窗口与它的状态。
pub(super) struct ReportSession {
    /// 窗口。
    window: eveo_ui::ProblemReportWindow,
    /// 崩溃情境下待报告的崩溃；手动情境为 None。
    crash: Option<PendingCrash>,
    /// 后台收集的结果；收集完后为 None。
    collecting: Option<Receiver<Collected>>,
    /// 收集到的结果。
    collected: Option<Collected>,
    /// 选中的行（最后一行是 manifest.json）。
    selected: usize,
    /// 打开窗口的时刻，作为报告的生成时刻。
    opened_at: f64,
    /// 已写出的压缩包。
    archive: Option<PathBuf>,
    /// 已打开过的 Issue 地址（完成页的「再次打开 GitHub」）。
    issue_url: Option<String>,
    /// 显示后还没切到前台。
    focus_pending: bool,
}

impl std::fmt::Debug for ReportSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReportSession")
            .field("crash", &self.crash.is_some())
            .field("selected", &self.selected)
            .finish_non_exhaustive()
    }
}

/// 接上窗口的回调：都转成输入排队，不在 Slint 的事件处理中途借用应用。
fn connect(window: &eveo_ui::ProblemReportWindow, runtime: &Rc<Runtime>) {
    let sender = |runtime: &Rc<Runtime>| {
        let weak = Rc::downgrade(runtime);
        move |input: ReportInput| post(&weak, Input::Report(input))
    };
    // 每个回调各持有一个弱引用：窗口关掉、应用退出后回调不会让应用多活。
    let model = window.global::<eveo_ui::ReportModel>();
    let send = sender(runtime);
    // 行号来自 Slint 的 int，不会是负数；保险起见夹到 0。
    model.on_toggled(move |row, checked| send(ReportInput::Toggled(row.max(0) as usize, checked)));
    let send = sender(runtime);
    model.on_select(move |row| send(ReportInput::Select(row.max(0) as usize)));
    let send = sender(runtime);
    model.on_create(move |open| send(ReportInput::Create(open)));
    let send = sender(runtime);
    model.on_dismiss(move || send(ReportInput::Dismiss));
    let send = sender(runtime);
    model.on_dont_report(move || send(ReportInput::DontReport));
    let send = sender(runtime);
    model.on_reveal(move || send(ReportInput::Reveal));
    let send = sender(runtime);
    model.on_open_issue(move || send(ReportInput::OpenIssue));
    let send = sender(runtime);
    model.on_close(move || send(ReportInput::Close));
    // 标题栏的关闭按钮等于「取消」或「以后再说」：交给应用收尾，窗口先隐藏。
    let send = sender(runtime);
    window.window().on_close_requested(move || {
        send(ReportInput::Dismiss);
        slint::CloseRequestResponse::HideWindow
    });
}

impl App {
    /// 打开报告窗口。crash 为真时用 state.json 里待报告的崩溃（没有时按手动情境）。
    /// 已有窗口在收集或等用户确认时只把它切到前台。
    pub(super) fn open_report(&mut self, crash: bool, runtime: &Rc<Runtime>) {
        // 同时只有一个报告窗口：正在收集或等确认的窗口再次打开时切到前台，不重新收集；
        // 已到完成页的窗口换成新的（用户想再报一次）。
        if let Some(session) = &mut self.diagnostics.report
            && session.archive.is_none()
        {
            let _ = session.window.show();
            session.focus_pending = true;
            return;
        }
        // 崩溃情境要 state.json 里的待报告崩溃；已被清掉（例如另一个窗口刚报告过）时按手动情境。
        let pending = if crash {
            self.chat.state.state().diagnostics.pending_crash.clone()
        } else {
            None
        };
        let Ok(window) = eveo_ui::ProblemReportWindow::new() else {
            return;
        };
        // 明暗只在建窗口时读一次；界面文字按当前语言填，窗口开着时换语言不跟（窗口很快就关）。
        window.set_dark(appearance::apps_use_dark_theme());
        eveo_ui::report::set_language(&window, self.language);
        connect(&window, runtime);
        // 先显示收集中：系统信息与日志要在后台读一会儿，窗口立即出现，按钮不可用。
        let state = ReportState {
            crash: pending.is_some(),
            collecting: true,
            ..ReportState::default()
        };
        eveo_ui::report::show_state(&window, &state);
        // 放在主屏正中：缩略图多半排在左上角，系统默认的位置会被挡住。
        if let Some(position) = super::centered_position(&self.screens, REPORT_SIZE) {
            window.window().set_position(position);
        }
        let _ = window.show();
        LOG.info(format_args!(
            "打开问题报告：{}",
            if pending.is_some() { "崩溃" } else { "手动" }
        ));
        // 报告的生成时刻取打开窗口的时刻：压缩包的名字、summary.md 与清单里的时间一致。
        let opened_at = wall_clock();
        let collecting = self.spawn_collect(pending.as_ref(), opened_at);
        self.diagnostics.report = Some(ReportSession {
            window,
            crash: pending,
            collecting,
            collected: None,
            selected: 0,
            opened_at,
            archive: None,
            issue_url: None,
            focus_pending: true,
        });
    }

    /// 在主线程取快照，起后台线程收集。线程建不出来时返回 None（窗口停在收集中，用户可以取消）。
    fn spawn_collect(&self, crash: Option<&PendingCrash>, now: f64) -> Option<Receiver<Collected>> {
        // 这些只能在主线程上取：配置、客户端登记与各服务的状态都属于应用。
        let config = self.coordinator.config();
        // 在线客户端的角色名：配置里没出现过的新角色也要脱敏（日志里可能有它的窗口标题）。
        let online: Vec<String> = self
            .coordinator
            .registry()
            .clients()
            .iter()
            .filter_map(|client| match &client.identity {
                ClientIdentity::Character(name) => Some(name.clone()),
                _ => None,
            })
            .collect();
        let names = character_names(config, &online);
        let config_text = pretty_json(&config_summary(config, None, &[]));
        let runtime = self.runtime_summary();
        // 崩溃情境只带那次崩溃找到的报告；手动情境带最近 7 天的（可能与用户遇到的问题有关）。
        let crashes = match crash {
            Some(pending) => CrashSource::Named(pending.report_file_names.clone()),
            None => CrashSource::Recent,
        };
        let logs = eveo_core::logging::rotating::LogFileLayout::in_dir(self.logs_dir.clone());
        let (sender, receiver) = mpsc::channel();
        std::thread::Builder::new()
            .name("report-collect".to_owned())
            .spawn(move || {
                // 系统信息与本机名字在后台读：DXGI 枚举显卡可能要几十毫秒。
                let environment = EnvironmentReport {
                    app: app_environment(),
                    system: system_info::system_info(),
                    runtime,
                };
                // 词表：本机名字加上角色名；summary.md 也经它处理（显卡名等不会含名字，但统一处理更稳妥）。
                let mut terms = system_info::sensitive_names();
                terms.character_names = names;
                let request = CollectRequest {
                    summary: environment.markdown(now),
                    config_summary: config_text,
                    logs,
                    crashes,
                    wer_dirs: super::diagnostics::wer_directories(),
                    executable: super::diagnostics::executable_name()
                        .unwrap_or_else(|| "eve-o-preview.exe".to_owned()),
                    now,
                    terms: terms.clone(),
                };
                let items = report::collect(&request);
                // 窗口已关、通道已丢时发送失败，结果也就不需要了。
                let _ = sender.send(Collected {
                    environment,
                    items,
                    terms,
                });
            })
            .ok()?;
        Some(receiver)
    }

    /// 运行时摘要：只有状态名与个数。
    fn runtime_summary(&self) -> RuntimeSummary {
        // 客户端按身份计数；无法识别的客户端不单列（Windows 上按标题判断，几乎不出现）。
        let clients = self.coordinator.registry().clients();
        let count = |f: fn(&ClientIdentity) -> bool| clients.iter().filter(|c| f(&c.identity)).count();
        let mut thumbnail_states = std::collections::BTreeMap::new();
        for presentation in &self.coordinator.last_plan().presentations {
            let state = if presentation.is_visible {
                "shown"
            } else {
                "hidden"
            };
            *thumbnail_states.entry(state.to_owned()).or_insert(0) += 1;
        }
        // 热键的问题分两类：系统注册失败（被别的程序占用）与配置里的问题（冲突、无法解析）。
        let mut hotkey_failures = std::collections::BTreeMap::new();
        let failed = self.hotkeys.failures().len();
        if failed > 0 {
            hotkey_failures.insert("registerFailed".to_owned(), failed);
        }
        let issues = self.coordinator.hotkey_plan().issues.len();
        if issues > 0 {
            hotkey_failures.insert("configIssues".to_owned(), issues);
        }
        let features = &self.chat.features;
        RuntimeSummary {
            ui_language: eveo_core::support::StringEnum::raw(self.language).to_owned(),
            combat_log_status: combat_status_text(&self.combat_status),
            chat_log_status: chat_status_text(features.chat_log_status()),
            static_data: features.static_data_state().to_owned(),
            translation_status: on_off(features.translation().is_some()),
            pilot_lookup_status: on_off(self.coordinator.profile().intel.resolve_pilot_names),
            character_clients: count(|identity| matches!(identity, ClientIdentity::Character(_))),
            login_clients: count(|identity| matches!(identity, ClientIdentity::Login)),
            thumbnail_states,
            hotkey_bindings: self.coordinator.hotkey_plan().bindings.len(),
            hotkey_failures,
            screens: self.screens.iter().map(screen_text).collect(),
            uptime_seconds: self.started.elapsed().as_secs(),
            previous_run: self.diagnostics.previous_run().to_owned(),
        }
    }

    /// 定时器里调用：取后台收集的结果；报告窗口显示后切到前台。
    pub(super) fn report_tick(&mut self) {
        let language = self.language;
        let Some(session) = &mut self.diagnostics.report else {
            return;
        };
        // 原生窗口在 show 之后的下一轮事件循环才出现，切前台与标题栏的明暗留到这里做（与设置窗口相同）。
        if session.focus_pending
            && let Some(hwnd) = super::window_hwnd(session.window.window())
            && activation::is_visible(eveo_platform_win::window_id(hwnd))
        {
            session.focus_pending = false;
            appearance::set_dark_title_bar(hwnd, session.window.get_dark());
            let _ = activation::bring_forward(eveo_platform_win::window_id(hwnd));
        }
        let Some(receiver) = &session.collecting else {
            return;
        };
        // 还没收集完：下一轮定时器再看。线程意外结束（通道断开）时窗口停在收集中，用户可以取消。
        let Ok(collected) = receiver.try_recv() else {
            return;
        };
        session.collecting = None;
        LOG.info(format_args!("收集完成：{} 个文件", collected.items.len()));
        session.collected = Some(collected);
        session.selected = 0;
        let state = ReportState {
            crash: session.crash.is_some(),
            ..ReportState::default()
        };
        eveo_ui::report::show_state(&session.window, &state);
        show_session(session, language);
    }

    /// 处理报告窗口的输入。
    pub(super) fn report_input(&mut self, input: ReportInput) {
        let language = self.language;
        let Some(session) = &mut self.diagnostics.report else {
            return;
        };
        match input {
            // 勾选只改内存里的项；清单的预览随之重算（show_session）。
            ReportInput::Toggled(row, included) => {
                if let Some(item) = session.collected.as_mut().and_then(|c| c.items.get_mut(row))
                    && item.optional()
                {
                    item.included = included;
                }
                show_session(session, language);
            }
            ReportInput::Select(row) => {
                session.selected = row;
                show_session(session, language);
            }
            ReportInput::Create(open) => self.create_report(open),
            ReportInput::Dismiss | ReportInput::Close => {
                // 崩溃情境的「以后再说」记一行：崩溃的提示保留，下次还会出现。
                if session.crash.is_some() && matches!(input, ReportInput::Dismiss) {
                    LOG.info("崩溃报告：以后再说");
                }
                self.close_report();
            }
            // 「不报告」：这次崩溃不再提示，名单最多记 20 个会话。
            ReportInput::DontReport => {
                if let Some(crash) = session.crash.clone() {
                    LOG.info("崩溃报告：不报告，这次崩溃不再提示");
                    self.update_crash_state(|diagnostics| {
                        diagnostics.dismiss(&crash.session_id);
                        diagnostics.pending_crash = None;
                    });
                }
                self.close_report();
            }
            ReportInput::Reveal => {
                if let Some(path) = &session.archive {
                    shell::reveal(path);
                }
            }
            ReportInput::OpenIssue => {
                if let Some(url) = &session.issue_url {
                    shell::open_url(url);
                }
            }
        }
    }

    /// 写压缩包，在资源管理器里选中；open 为真时打开预填的 Issue。
    fn create_report(&mut self, open: bool) {
        let reports_dir = self.paths_reports_dir();
        let Some(session) = &mut self.diagnostics.report else {
            return;
        };
        let Some(collected) = &session.collected else {
            return;
        };
        let crash = session.crash.is_some();
        let busy = ReportState {
            crash,
            busy: true,
            ..ReportState::default()
        };
        eveo_ui::report::show_state(&session.window, &busy);
        // 写压缩包只要几十毫秒（几 MiB 的文字，不压缩），直接在主线程上做。
        let name = DiagnosticsBundlePlanner::archive_name(session.opened_at);
        let info = manifest_info(session.opened_at, crash);
        let written = report::write_archive(
            &reports_dir,
            &name,
            &collected.items,
            &info,
            dos_time(session.opened_at),
        );
        let path = match written {
            Ok(path) => path,
            Err(error) => {
                // 显示错误的类别（如 PermissionDenied），不显示路径；不打开浏览器。
                LOG.error(format_args!("写报告失败：{:?}", error.kind()));
                let failed = ReportState {
                    crash,
                    error: format!("{:?}", error.kind()),
                    ..ReportState::default()
                };
                eveo_ui::report::show_state(&session.window, &failed);
                return;
            }
        };
        let included = collected.items.iter().filter(|item| item.included).count();
        LOG.info(format_args!("已生成报告：{included} 个文件，打开 GitHub：{open}"));
        // 先在资源管理器里选中压缩包，再打开浏览器：用户在浏览器里拖文件时资源管理器已经在旁边。
        shell::reveal(&path);
        if open {
            let pending = session.crash.as_ref();
            let draft = problem_report_draft(
                crash,
                &collected.environment,
                pending.map(|c| c.app_version.as_str()),
                pending.map_or(0, |c| c.report_file_names.len()),
                &format!("{name}.zip"),
            );
            // 标题与正文也过一遍脱敏：系统信息里一般没有名字，但显卡名、语言列表等不受我们控制。
            let redactor = Redactor::new(&collected.terms);
            let mut draft = draft;
            draft.title = redactor.redact(&draft.title).0;
            for section in &mut draft.sections {
                section.body = redactor.redact(&section.body).0;
            }
            let url = issue::issue_url(&draft, ISSUE_URL_BYTES);
            shell::open_url(&url);
            session.issue_url = Some(url);
        } else {
            // 只生成报告时，完成页的「再次打开 GitHub」打开空白的新建 Issue 页。
            session.issue_url = Some(issue::base_url());
        }
        session.archive = Some(path);
        let done = ReportState {
            crash,
            done: true,
            ..ReportState::default()
        };
        eveo_ui::report::show_state(&session.window, &done);
        if crash {
            self.update_crash_state(|diagnostics| diagnostics.pending_crash = None);
        }
    }

    /// 关掉报告窗口。
    fn close_report(&mut self) {
        if let Some(session) = self.diagnostics.report.take() {
            let _ = session.window.hide();
        }
    }

    /// 改 state.json 的 diagnostics；写失败只记日志。
    fn update_crash_state(&mut self, change: impl FnOnce(&mut eveo_app_core::state_store::DiagnosticsState)) {
        if let Err(error) = self.chat.state.update_diagnostics(change) {
            LOG.error(format_args!("写 state.json 失败：{:?}", error.kind()));
        }
    }

    /// 报告所在的目录：日志目录旁边的 Reports（都在 %LOCALAPPDATA%\EVE-O Preview 下）。
    fn paths_reports_dir(&self) -> PathBuf {
        self.logs_dir
            .parent()
            .map_or_else(|| self.logs_dir.join("Reports"), |dir| dir.join("Reports"))
    }

    /// 是否有待报告的崩溃（托盘菜单的提示项）。
    pub(super) fn crash_pending(&self) -> bool {
        self.chat.state.state().diagnostics.pending_crash.is_some()
    }
}

/// 把会话的列表与选中项的预览交给窗口。列表最后一行是 manifest.json，预览按当前的勾选现算。
fn show_session(session: &mut ReportSession, language: eveo_core::model::AppLanguage) {
    let Some(collected) = &session.collected else {
        return;
    };
    // 清单不在收集的项里：它列的是勾选的项，勾选一变就要重算。
    let manifest = report::manifest_text(
        &collected.items,
        &manifest_info(session.opened_at, session.crash.is_some()),
    );
    let mut files: Vec<FileView> = collected
        .items
        .iter()
        .map(|item| FileView {
            kind: match item.kind {
                report::ItemKind::Summary => FileKind::Summary,
                report::ItemKind::Config => FileKind::Config,
                report::ItemKind::Log => FileKind::Log(item.path.trim_start_matches("logs/").to_owned()),
                report::ItemKind::Crash(number) => FileKind::Crash(number),
            },
            bytes: item.text.len(),
            optional: item.optional(),
            included: item.included,
        })
        .collect();
    files.push(FileView {
        kind: FileKind::Manifest,
        bytes: manifest.len(),
        optional: false,
        included: true,
    });
    // 列表至少有清单这一行，下标夹到范围内。
    session.selected = session.selected.min(files.len() - 1);
    eveo_ui::report::show_files(&session.window, &files, session.selected, language);
    match collected.items.get(session.selected) {
        Some(item) => eveo_ui::report::show_preview(&session.window, &item.text, item.counts.total()),
        None => eveo_ui::report::show_preview(&session.window, &manifest, 0),
    }
}

/// 清单的元数据。
fn manifest_info(generated_at: f64, crash: bool) -> ManifestInfo {
    ManifestInfo {
        app_version: env!("CARGO_PKG_VERSION").to_owned(),
        build_label: build_label().to_owned(),
        generated_at,
        crash,
    }
}

/// 压缩包里的时间：UTC（报告的名字也按 UTC，两者一致）。
fn dos_time(at: f64) -> DosTime {
    // 早于 1970 年的时刻（时钟异常）按 1970 年算；DosTime 自己再夹到 1980 年起。
    let seconds = at.max(0.0) as i64;
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let in_day = seconds.rem_euclid(86_400);
    DosTime {
        year: year as u16,
        month: month as u16,
        day: day as u16,
        hour: (in_day / 3600) as u16,
        minute: (in_day % 3600 / 60) as u16,
        second: (in_day % 60) as u16,
    }
}

/// 应用的运行环境：版本、构建类别、提交（构建时的环境变量 EVEO_BUILD_COMMIT，没有时为 None）与安装位置的类别。
fn app_environment() -> AppEnvironment {
    // 只写类别，不写路径：路径里可能有用户名。
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(PathBuf::from));
    // 不区分大小写地比较前缀：环境变量与实际路径的大小写可能不同。
    let under = |var: &str| {
        let root = std::env::var_os(var).map(PathBuf::from);
        exe_dir.as_ref().zip(root).is_some_and(|(dir, root)| {
            dir.to_string_lossy()
                .to_lowercase()
                .starts_with(&root.to_string_lossy().to_lowercase())
        })
    };
    let install_location = if under("ProgramFiles") || under("ProgramFiles(x86)") {
        "programFiles"
    } else if under("LOCALAPPDATA") {
        "localAppData"
    } else {
        "other"
    };
    AppEnvironment {
        version: env!("CARGO_PKG_VERSION").to_owned(),
        build_label: build_label().to_owned(),
        commit: option_env!("EVEO_BUILD_COMMIT").map(|c| c.chars().take(7).collect()),
        install_location: install_location.to_owned(),
        location_writable: exe_dir.as_deref().is_some_and(directory_writable),
    }
}

/// 目录是否可写：试建一个临时文件再删掉。
fn directory_writable(dir: &std::path::Path) -> bool {
    // 只读属性与 ACL 都可能让写入失败，直接试最可靠；文件名带进程号，不会与别的实例冲突。
    let probe = dir.join(format!(".eveo-write-test-{}", std::process::id()));
    let writable = std::fs::write(&probe, b"").is_ok();
    let _ = std::fs::remove_file(&probe);
    writable
}

/// 开关的写法。
fn on_off(on: bool) -> String {
    if on { "on" } else { "off" }.to_owned()
}

/// 游戏日志的状态，不含路径。
fn combat_status_text(status: &CombatLogStatus) -> String {
    match status {
        CombatLogStatus::Stopped => "stopped".to_owned(),
        CombatLogStatus::Watching { followed_files, .. } => format!("watching ({followed_files} files)"),
        CombatLogStatus::DirectoryNotFound(_) => "directoryNotFound".to_owned(),
        CombatLogStatus::AccessDenied(_) => "accessDenied".to_owned(),
    }
}

/// 聊天日志的状态，不含路径。
fn chat_status_text(status: &ChatLogStatus) -> String {
    match status {
        ChatLogStatus::Stopped => "stopped".to_owned(),
        ChatLogStatus::Watching { followed_files, .. } => format!("watching ({followed_files} files)"),
        ChatLogStatus::DirectoryNotFound(_) => "directoryNotFound".to_owned(),
        ChatLogStatus::AccessDenied(_) => "accessDenied".to_owned(),
    }
}

/// 屏幕的写法：`2560x1440 @150%`，主屏另加 ` primary`（原点在 (0, 0) 的是主屏）。
fn screen_text(screen: &eveo_core::geometry::ScreenInfo) -> String {
    // frame 是物理像素；缩放比例写成百分数，与 Windows 设置里的「缩放」一致。
    let frame = screen.frame;
    let primary = frame.x == 0.0 && frame.y == 0.0;
    format!(
        "{}x{} @{}%{}",
        frame.width.round(),
        frame.height.round(),
        (screen.scale * 100.0).round(),
        if primary { " primary" } else { "" }
    )
}
