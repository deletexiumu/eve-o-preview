// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用里的异常退出检测，对应 macOS 的 SessionTracker.swift 接进 AppDelegate 的部分（v1.1 设计 6.1～6.3 节）：
// - 启动：建本次的会话标记（编号与日志的会话头相同），读上一次的标记归类，记一行日志。
//   上一个进程是否还在：标记里的 PID 取得到进程信息，且映像文件名与本进程相同。
// - 上一次异常结束：后台线程在启动后 5 秒找一次崩溃的证据（WER 报告目录、日志里那次会话的 fault 行），
//   没找到时 30 秒再找一次。结果经通道交回主线程，在定时器里取。
// - 找到证据、且那次会话不在「不报告」的名单里：写进 state.json 的 diagnostics.pendingCrash，记一行日志，
//   并弹一条托盘通知；托盘菜单顶部也多一项提示，点了打开崩溃情境的报告窗口（report 模块）。
//   没找到证据（断电、强制结束）只记日志。
// - 正常退出：收尾时（销毁缩略图之后、释放热键与托盘之前）把标记改成已结束。
// 日志只有会话编号的前 8 位、WER 报告的个数与 fault 行的条数，不写路径。
// 调试版另有一个测试入口：环境变量 EVEO_DEBUG_PANIC_AFTER=<秒> 时，启动这么多秒后在主线程上 panic，
// 用来在真机上验证崩溃的检测。发布版没有这个入口。

//! 会话标记与上一次崩溃的检测。

use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use eveo_app_core::log::Logger;
use eveo_app_core::paths::DataPaths;
use eveo_app_core::session::{CrashEvidence, SessionTracker, find_crash_evidence};
use eveo_app_core::state_store::PendingCrash;
use eveo_core::diagnostics::crash::short_session_id;
use eveo_core::diagnostics::session::{PreviousRunOutcome, SessionMarker};
use eveo_core::logging::rotating::LogFileLayout;
use eveo_platform_win::process::process_info;

use super::App;
use super::intel::wall_clock;
use super::logging::build_label;

/// 诊断的日志。
const LOG: Logger = Logger::new("Diagnostics");
/// 第一次找证据前等的时间：WER 写报告要几秒。
const FIRST_SCAN: Duration = Duration::from_secs(5);
/// 第一次没找到时，再等多久找第二次（从启动算是 30 秒）。
const SECOND_SCAN: Duration = Duration::from_secs(25);

/// 异常退出检测在应用里的状态。
#[derive(Debug)]
pub(super) struct Diagnostics {
    /// 会话标记的持有者。
    tracker: SessionTracker,
    /// 后台找证据的结果；没有在找时为 None。
    scan: Option<Receiver<Option<CrashEvidence>>>,
    /// 打开着的问题报告窗口。
    pub(super) report: Option<super::report::ReportSession>,
}

impl Diagnostics {
    /// 建本次的标记、归类上一次，上一次异常结束时开始在后台找证据。
    pub(super) fn start(paths: &DataPaths, session_id: &str, logs_dir: PathBuf) -> Self {
        let marker = SessionMarker {
            marker_version: eveo_core::diagnostics::session::MARKER_VERSION,
            session_id: session_id.to_owned(),
            pid: std::process::id(),
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
            build_label: build_label().to_owned(),
            started_at: wall_clock(),
            ended_cleanly: false,
        };
        let (tracker, written) = SessionTracker::start(paths.session_file(), marker, is_this_app);
        if let Err(error) = written {
            LOG.error(format_args!("写 session.json 失败：{:?}", error.kind()));
        }
        let previous = tracker.previous().clone();
        match &previous {
            PreviousRunOutcome::Abnormal(marker) | PreviousRunOutcome::StillRunning(marker) => {
                LOG.info(format_args!(
                    "上一次运行：{}（会话 {}，版本 {}）",
                    previous.raw(),
                    short_session_id(&marker.session_id),
                    marker.app_version
                ));
            }
            _ => LOG.info(format_args!("上一次运行：{}", previous.raw())),
        }
        let scan = match previous {
            PreviousRunOutcome::Abnormal(marker) => spawn_scan(marker, logs_dir),
            _ => None,
        };
        Self {
            tracker,
            scan,
            report: None,
        }
    }

    /// 上一次运行的归类名（问题报告的运行时摘要用）。
    pub(super) fn previous_run(&self) -> &'static str {
        self.tracker.previous().raw()
    }

    /// 把本次运行记为正常结束（退出收尾的最后一步）。
    pub(super) fn mark_ended_cleanly(&mut self) {
        if let Err(error) = self.tracker.mark_ended_cleanly() {
            LOG.error(format_args!("写 session.json 失败：{:?}", error.kind()));
        }
    }
}

/// pid 的进程是否还在、且是本应用（映像文件名与本进程相同，不区分大小写）。
fn is_this_app(pid: u32) -> bool {
    let Some(own) = executable_name() else {
        return false;
    };
    process_info(pid).is_some_and(|info| info.image_name.eq_ignore_ascii_case(&own))
}

/// 本进程的可执行文件名，如 `eve-o-preview.exe`。
pub(super) fn executable_name() -> Option<String> {
    let path = std::env::current_exe().ok()?;
    Some(path.file_name()?.to_string_lossy().into_owned())
}

/// WER 的报告目录：当前用户与全机的 ReportArchive、ReportQueue。
pub(super) fn wer_directories() -> Vec<PathBuf> {
    ["LOCALAPPDATA", "PROGRAMDATA"]
        .into_iter()
        .filter_map(std::env::var_os)
        .flat_map(|root| {
            let wer = PathBuf::from(root).join(r"Microsoft\Windows\WER");
            [wer.join("ReportArchive"), wer.join("ReportQueue")]
        })
        .collect()
}

/// 后台线程：5 秒后找一次证据，没找到时再过 25 秒找一次，结果交回主线程。线程建不出来时不找。
fn spawn_scan(previous: SessionMarker, logs_dir: PathBuf) -> Option<Receiver<Option<CrashEvidence>>> {
    let (sender, receiver) = mpsc::channel();
    let executable = executable_name().unwrap_or_else(|| "eve-o-preview.exe".to_owned());
    let logs = LogFileLayout::in_dir(logs_dir);
    std::thread::Builder::new()
        .name("crash-scan".to_owned())
        .spawn(move || {
            let directories = wer_directories();
            let scan = || find_crash_evidence(&previous, &directories, &logs, &executable, wall_clock());
            std::thread::sleep(FIRST_SCAN);
            let mut evidence = scan();
            if evidence.is_none() {
                std::thread::sleep(SECOND_SCAN);
                evidence = scan();
            }
            // 应用已退出、通道已丢时发送失败，结果也就不需要了。
            let _ = sender.send(evidence);
        })
        .ok()?;
    Some(receiver)
}

impl App {
    /// 调试版的测试入口：EVEO_DEBUG_PANIC_AFTER 给的秒数到了就 panic（见文件头）。
    pub(super) fn debug_panic_check(&self) {
        if !cfg!(debug_assertions) {
            return;
        }
        let after = std::env::var("EVEO_DEBUG_PANIC_AFTER")
            .ok()
            .and_then(|value| value.parse::<u64>().ok());
        if let Some(after) = after
            && self.started.elapsed() >= Duration::from_secs(after)
        {
            panic!("EVEO_DEBUG_PANIC_AFTER：测试用的 panic");
        }
    }

    /// 定时器里调用：取后台找证据的结果；找到时记下待报告的崩溃。
    pub(super) fn poll_crash_scan(&mut self) {
        let Some(receiver) = &self.diagnostics.scan else {
            return;
        };
        let Ok(evidence) = receiver.try_recv() else {
            return;
        };
        self.diagnostics.scan = None;
        let PreviousRunOutcome::Abnormal(previous) = self.diagnostics.tracker.previous().clone() else {
            return;
        };
        let session = short_session_id(&previous.session_id);
        let Some(evidence) = evidence else {
            LOG.info(format_args!(
                "上一次运行（会话 {session}）异常结束，没有找到崩溃的证据"
            ));
            return;
        };
        LOG.notice(format_args!(
            "上一次运行（会话 {session}）崩溃了：WER 报告 {} 个，日志里的 fault {} 行",
            evidence.reports.len(),
            evidence.faults.len()
        ));
        let pending = PendingCrash {
            session_id: previous.session_id.clone(),
            app_version: previous.app_version.clone(),
            started_at: previous.started_at,
            detected_at: wall_clock(),
            report_file_names: evidence.reports,
        };
        // 记下这次是否真的写进了 pendingCrash（被「不报告」挡掉时不弹通知）。
        let mut recorded = false;
        let result = self.chat.state.update_diagnostics(|diagnostics| {
            // 用户对这次会话选过「不报告」时不再记。
            if !diagnostics.dismissed_session_ids.contains(&pending.session_id) {
                diagnostics.pending_crash = Some(pending);
                recorded = true;
            }
        });
        if let Err(error) = result {
            LOG.error(format_args!("写 state.json 失败：{:?}", error.kind()));
        }
        // 通知只在这次新记下时弹；专注助手与全屏游戏时系统不弹，托盘菜单的提示项仍在。
        if recorded {
            let text = eveo_l10n::diagnostics(self.language);
            // 记下结果：系统不显示通知时（真机上遇到过），日志能说明是调用失败还是被系统压下。
            match self.tray.notify("EVE-O Preview", text.menu_crash_pending()) {
                Ok(()) => LOG.info("已请求系统显示崩溃通知"),
                Err(code) => LOG.error(format_args!("崩溃通知没有发出：错误码 {code}")),
            }
        }
    }
}
