// SPDX-License-Identifier: GPL-3.0-or-later
//
// 会话标记的持有者与崩溃证据的查找，对应 macOS 的 SessionTracker.swift（v1.1 设计 6.1～6.3 节）：
// - 启动：读上一次的 session.json，判断上一个进程是否还在（PID 不是本进程、且映像是本应用，由调用方判断），
//   归类后写入本次的标记（endedCleanly 为假）。重复启动后自己退出的实例不碰标记（它不会走到这一步）。
// - 正常退出：收尾的最后一步把标记改成已结束。
// - 上一次异常结束时，调用方在后台线程里调 `find_crash_evidence`（启动后 5 秒一次，没找到时 30 秒再一次）：
//   列 WER 的报告目录、读本应用的日志，交给 Core 的 diagnostics::crash 判断。
// 标记里没有个人信息；WER 目录名只有可执行文件名与哈希。

//! 会话标记与崩溃的证据。

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use eveo_core::diagnostics::crash::{WerReport, fault_lines, select_reports};
use eveo_core::diagnostics::session::{PreviousRunOutcome, SessionMarker, outcome};
use eveo_core::logging::rotating::LogFileLayout;

use crate::atomic_file::write_atomic;

/// session.json 的持有者。
#[derive(Debug)]
pub struct SessionTracker {
    /// 文件的位置。
    path: PathBuf,
    /// 本次运行的标记。
    marker: SessionMarker,
    /// 上一次运行的归类。
    previous: PreviousRunOutcome,
}

impl SessionTracker {
    /// 读上一次的标记并归类，然后写入本次的标记。alive(pid) 判断那个进程是否还在且是本应用。
    /// 返回持有者与写盘的结果（写不了只影响下次的判断）。
    pub fn start(
        path: impl Into<PathBuf>,
        marker: SessionMarker,
        alive: impl FnOnce(u32) -> bool,
    ) -> (Self, io::Result<()>) {
        let path = path.into();
        let previous_marker = fs::read(&path)
            .ok()
            .and_then(|bytes| SessionMarker::decode(&bytes));
        let previous_alive = previous_marker
            .as_ref()
            .is_some_and(|m| m.pid != marker.pid && alive(m.pid));
        let previous = outcome(previous_marker, previous_alive);
        let tracker = Self {
            path,
            marker,
            previous,
        };
        let written = tracker.save();
        (tracker, written)
    }

    /// 上一次运行的归类。
    pub fn previous(&self) -> &PreviousRunOutcome {
        &self.previous
    }

    /// 本次运行的标记。
    pub fn marker(&self) -> &SessionMarker {
        &self.marker
    }

    /// 把本次运行记为正常结束并写盘。
    pub fn mark_ended_cleanly(&mut self) -> io::Result<()> {
        self.marker.ended_cleanly = true;
        self.save()
    }

    /// 写盘（原子写入）。
    fn save(&self) -> io::Result<()> {
        write_atomic(&self.path, &self.marker.encode(), "session")
    }
}

/// 找到的崩溃证据。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CrashEvidence {
    /// WER 报告的目录名，最新的在前。
    pub reports: Vec<String>,
    /// 那次会话在日志里写的 fault 行。
    pub faults: Vec<String>,
}

/// 找上一次运行（previous）崩溃的证据；两种都没有时为 None。
/// wer_dirs 是 WER 的 ReportArchive、ReportQueue 等目录；executable 是可执行文件名；now 是现在的时刻。
pub fn find_crash_evidence(
    previous: &SessionMarker,
    wer_dirs: &[PathBuf],
    logs: &LogFileLayout,
    executable: &str,
    now: f64,
) -> Option<CrashEvidence> {
    let candidates: Vec<WerReport> = wer_dirs.iter().flat_map(|dir| wer_reports(dir)).collect();
    let reports = select_reports(&candidates, executable, previous.started_at, now)
        .into_iter()
        .map(|r| r.name)
        .collect::<Vec<_>>();
    // 日志按时间从早到晚：existing 是最新的在前，倒过来读。
    let text: Vec<String> = logs
        .existing()
        .iter()
        .rev()
        .filter_map(|file| fs::read(file).ok())
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .collect();
    let faults = fault_lines(text.iter().flat_map(|t| t.lines()), &previous.session_id);
    (!reports.is_empty() || !faults.is_empty()).then_some(CrashEvidence { reports, faults })
}

/// 一个 WER 目录下的子目录与它们的修改时间；目录不存在或读不了时为空。
fn wer_reports(dir: &Path) -> Vec<WerReport> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let metadata = entry.metadata().ok().filter(fs::Metadata::is_dir)?;
            let modified = metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
            Some(WerReport {
                name: entry.file_name().to_string_lossy().into_owned(),
                modified_at: modified.as_secs_f64(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用的临时目录，用完删掉。
    struct TempDir(PathBuf);

    impl TempDir {
        /// 新建一个空目录。
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!("eveo-session-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// 一个标记。
    fn marker(id: &str, pid: u32) -> SessionMarker {
        SessionMarker {
            marker_version: 1,
            session_id: id.to_owned(),
            pid,
            app_version: "0.9.0".to_owned(),
            build_label: "test".to_owned(),
            started_at: 1_700_000_000.0,
            ended_cleanly: false,
        }
    }

    /// 第一次没有记录；没有正常结束的上一次是异常（进程不在）或还在运行；正常结束后是 clean。
    #[test]
    fn tracks_runs() {
        let dir = TempDir::new("track");
        let path = dir.0.join("session.json");
        let (first, written) = SessionTracker::start(&path, marker("A", 1), |_| false);
        written.unwrap();
        assert_eq!(first.previous(), &PreviousRunOutcome::NoRecord);
        let (_, _) = SessionTracker::start(&path, marker("B", 2), |_| true);
        let (third, _) = SessionTracker::start(&path, marker("C", 3), |_| false);
        assert_eq!(third.previous().raw(), "abnormal", "B 没有正常结束，进程也不在");
        let (mut fourth, _) = SessionTracker::start(&path, marker("D", 4), |pid| pid == 3);
        assert_eq!(fourth.previous().raw(), "stillRunning");
        fourth.mark_ended_cleanly().unwrap();
        let (fifth, _) = SessionTracker::start(&path, marker("E", 5), |_| false);
        assert_eq!(fifth.previous(), &PreviousRunOutcome::Clean);
        // 上一次的 PID 与本进程相同（PID 被复用）时不当作还在运行。
        let (sixth, _) = SessionTracker::start(&path, marker("F", 5), |_| true);
        assert_eq!(sixth.previous().raw(), "abnormal");
    }

    /// 证据：WER 目录与日志里的 fault 行；都没有时为 None。
    #[test]
    fn finds_evidence() {
        let dir = TempDir::new("evidence");
        let wer = dir.0.join("ReportArchive");
        fs::create_dir_all(wer.join("AppCrash_eve-o-preview.e_abc_123")).unwrap();
        fs::create_dir_all(wer.join("AppCrash_other.exe_abc_123")).unwrap();
        let logs = LogFileLayout::in_dir(dir.0.join("logs"));
        fs::create_dir_all(&logs.directory).unwrap();
        fs::write(
            logs.current(),
            "t INFO [Session] 会话开始 abcdef12：版本\nt FAULT [Fault] panic 于线程 main\n",
        )
        .unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        let previous = SessionMarker {
            started_at: now - 60.0,
            ..marker("ABCDEF12-0000", 9)
        };
        let evidence = find_crash_evidence(
            &previous,
            std::slice::from_ref(&wer),
            &logs,
            "eve-o-preview.exe",
            now,
        )
        .unwrap();
        assert_eq!(evidence.reports, ["AppCrash_eve-o-preview.e_abc_123"]);
        assert_eq!(evidence.faults.len(), 1);
        // 别的会话、报告在窗口之外：没有证据。
        let other = SessionMarker {
            started_at: now + 600.0,
            ..marker("99999999-0000", 9)
        };
        assert_eq!(
            find_crash_evidence(&other, &[wer], &logs, "eve-o-preview.exe", now + 600.0),
            None
        );
    }
}
