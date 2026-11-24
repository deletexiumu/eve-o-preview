// SPDX-License-Identifier: GPL-3.0-or-later
//
// 上一次运行异常结束（会话标记没有标为已结束）时找崩溃的证据，对应 macOS 的 CrashReportMatcher.swift
// （v1.1 设计 6.2 节）。异常结束不等于崩溃：断电、强制结束进程也会这样，那些情况不应换来一个报告窗口。
//
// Windows 上的两种证据：
// 1. WER 的报告目录：%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive 与 ReportQueue 下，
//    崩溃的报告是一个子目录，名字形如 `AppCrash_<可执行文件名的前若干个字符>_<哈希>_<编号>`
//    （WER 会截短长名字，如 `AppCrash_eve-o-preview.e_…`）。规则：
//    - 名字不区分大小写以 `AppCrash_` 开头，下一段（到下一个 `_` 为止）至少 8 个字符，且是可执行文件名的前缀；
//    - 目录的修改时间不早于标记的 startedAt 减 5 秒，不晚于扫描时刻加 5 秒；
//    - 按修改时间从新到旧，最多取 3 个。
// 2. 本应用的日志：那次会话（会话头里有会话编号的前 8 位）里写过 fault 行（panic 钩子、顶层异常过滤器）。
//    日志在崩溃前已经交给了系统，所以 WER 被关掉时也有这条证据。
// 读目录与文件由应用层做，这里只判断，Linux 上可测。

//! 崩溃的证据。

/// 最多取几个 WER 报告。
pub const MAX_REPORTS: usize = 3;

/// 时间窗口两头各放宽的秒数。
pub const WINDOW_SLACK: f64 = 5.0;

/// 最多带几行日志里的 fault。
pub const MAX_FAULT_LINES: usize = 5;

/// WER 报告目录里的一个子目录。
#[derive(Debug, Clone, PartialEq)]
pub struct WerReport {
    /// 子目录名（不含路径）。
    pub name: String,
    /// 修改时间（1970 年以来的秒数）。
    pub modified_at: f64,
}

/// 子目录名是不是本应用的崩溃报告。executable 是可执行文件名，如 `eve-o-preview.exe`。
pub fn is_crash_report_name(name: &str, executable: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("appcrash_") else {
        return false;
    };
    let app = rest.split('_').next().unwrap_or_default();
    app.len() >= 8 && executable.to_ascii_lowercase().starts_with(app)
}

/// 选出属于本应用、修改时间在 [started_at - 5, now + 5] 里的报告，最新的在前，最多 3 个。
pub fn select_reports(
    candidates: &[WerReport],
    executable: &str,
    started_at: f64,
    now: f64,
) -> Vec<WerReport> {
    let window = (started_at - WINDOW_SLACK)..=(now + WINDOW_SLACK);
    let mut matched: Vec<WerReport> = candidates
        .iter()
        .filter(|r| is_crash_report_name(&r.name, executable) && window.contains(&r.modified_at))
        .cloned()
        .collect();
    matched.sort_by(|a, b| b.modified_at.total_cmp(&a.modified_at));
    matched.truncate(MAX_REPORTS);
    matched
}

/// 会话头里的会话编号：编号的前 8 个字符，小写（与 macOS 的会话头相同）。
pub fn short_session_id(session_id: &str) -> String {
    session_id.chars().take(8).collect::<String>().to_lowercase()
}

/// 会话头的标志文字；会话头形如 `… INFO [Session] 会话开始 6f1d3c2a：…`。
const SESSION_START: &str = "会话开始 ";

/// 日志里那次会话写过的 fault 行，最多 5 行。lines 按时间从早到晚（旧文件在前）。
/// 从带着这个会话编号的会话头开始，到下一个会话头为止。
pub fn fault_lines<'a>(lines: impl IntoIterator<Item = &'a str>, session_id: &str) -> Vec<String> {
    let header = format!("{SESSION_START}{}", short_session_id(session_id));
    let mut inside = false;
    let mut faults = Vec::new();
    for line in lines {
        if line.contains(SESSION_START) {
            inside = line.contains(&header);
            continue;
        }
        if inside && line.contains(" FAULT [") && faults.len() < MAX_FAULT_LINES {
            faults.push(line.to_owned());
        }
    }
    faults
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 报告名：前缀、截短的可执行文件名、别的应用。
    #[test]
    fn report_names() {
        let exe = "eve-o-preview.exe";
        assert!(is_crash_report_name(
            "AppCrash_eve-o-preview.e_3b1f_cab_0a1b",
            exe
        ));
        assert!(is_crash_report_name("APPCRASH_EVE-O-PREVIEW.EXE_aa_bb", exe));
        assert!(!is_crash_report_name("AppHang_eve-o-preview.e_3b1f", exe));
        assert!(!is_crash_report_name("AppCrash_eve_3b1f", exe), "太短的前缀不算");
        assert!(!is_crash_report_name("AppCrash_exefile.exe_3b1f", exe));
    }

    /// 时间窗口与排序、上限。
    #[test]
    fn selects_in_window() {
        let exe = "eve-o-preview.exe";
        let report = |name: &str, at: f64| WerReport {
            name: name.to_owned(),
            modified_at: at,
        };
        let candidates = [
            report("AppCrash_eve-o-preview.e_1", 90.0),
            report("AppCrash_eve-o-preview.e_2", 96.0),
            report("AppCrash_eve-o-preview.e_3", 150.0),
            report("AppCrash_eve-o-preview.e_4", 120.0),
            report("AppCrash_eve-o-preview.e_5", 130.0),
            report("AppCrash_eve-o-preview.e_6", 300.0),
            report("AppCrash_other.exe_7", 120.0),
        ];
        let names: Vec<String> = select_reports(&candidates, exe, 100.0, 200.0)
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(
            names,
            [
                "AppCrash_eve-o-preview.e_3",
                "AppCrash_eve-o-preview.e_5",
                "AppCrash_eve-o-preview.e_4"
            ]
        );
    }

    /// 只取那次会话的 fault 行。
    #[test]
    fn faults_of_session() {
        let log = [
            "2026-11-24T05:00:00.000Z INFO [Session] 会话开始 aaaaaaaa：版本 0.9.0",
            "2026-11-24T05:00:01.000Z FAULT [Fault] 别的会话",
            "2026-11-24T05:01:00.000Z INFO [Session] 会话开始 6f1d3c2a：版本 0.9.0",
            "2026-11-24T05:01:01.000Z ERROR [Chat] 不是 fault",
            "2026-11-24T05:01:02.000Z FAULT [Fault] 未处理的异常 0xc0000005，x.dll+0x10",
            "2026-11-24T05:02:00.000Z INFO [Session] 会话开始 bbbbbbbb：版本 0.9.0",
            "2026-11-24T05:02:01.000Z FAULT [Fault] 下一次会话",
        ];
        let faults = fault_lines(log, "6F1D3C2A-0000-4000-8000-000000000001");
        assert_eq!(faults.len(), 1);
        assert!(faults[0].contains("0xc0000005"));
        assert!(fault_lines(log, "CCCCCCCC-1").is_empty());
    }
}
