// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志目录的查找与文件的取舍（反馈文档 7.3 节），对应 macOS 的 CombatLogDirectory.swift。
// 只做纯计算，读目录与文件由平台层的跟踪服务做。除了候选目录，这里还放跟踪服务的几条纯规则，便于单元测试：
// - is_recent：只看修改时间在最近 48 小时内的文件。
// - select_followed：同一个收听者只跟踪文件名最大的文件，总数至多 16 个。
// - starts_at_end：跟踪开始前已有的文件从末尾读起，跟踪开始后才建的文件从头读起。
// - read_start：文件变短时视为被截断，从头重读。
//
// 与 macOS 的区别只在路径：Windows 的路径用反斜杠，大小写不敏感，没有 `~`。路径按字符串处理（正反斜杠都认），
// 这样在 Linux 上跑测试时结果与 Windows 相同。

//! 游戏日志目录与文件的规则。

use std::collections::HashMap;

/// 同时跟踪的文件数上限（7.3 节第 6 条）。
pub const MAX_FOLLOWED_FILES: usize = 16;
/// 只看修改时间在这么多秒以内的文件：48 小时（7.3 节第 2 条）。
pub const RECENT_WINDOW: f64 = 48.0 * 3_600.0;
/// 判断「跟踪开始前已有的文件」时，给启动时刻留的余量：2 秒。
pub const START_GRACE: f64 = 2.0;
/// 游戏日志所在的子文件夹。
pub const GAMELOGS: &str = "Gamelogs";
/// 聊天日志所在的子文件夹。
pub const CHATLOGS: &str = "Chatlogs";

/// 用到的日志目录（logs 那一级）：设置了就用设置的，否则用自动查找的位置。
///
/// 用户常把 Chatlogs 或 Gamelogs 本身填进来（「提醒」页的说明写的是 logs 文件夹，但很容易选深一级），
/// 这时取它的上一级，两个子文件夹都从 logs 那一级找。末尾的分隔符去掉。
pub fn log_root(configured: Option<&str>, automatic: &str) -> String {
    let path = configured
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .unwrap_or(automatic);
    let trimmed = trim_separators(path);
    match split_last(trimmed) {
        Some((parent, last))
            if last.eq_ignore_ascii_case(CHATLOGS) || last.eq_ignore_ascii_case(GAMELOGS) =>
        {
            parent.to_owned()
        }
        _ => trimmed.to_owned(),
    }
}

/// 按优先顺序返回可能的 Gamelogs 目录路径。
///
/// - `configured` 为 `None` 或空白：返回 `<automatic>\Gamelogs`（`automatic` 是自动查找的 logs 目录）。
/// - 最后一段是 `Gamelogs`（不区分大小写）：只返回它自己。
/// - 最后一段是 `Chatlogs`：按它的上一级（logs）处理。
/// - 其余：返回 `[<logs>\Gamelogs, <logs>]`，用户选 logs 目录、或直接放日志文件的目录都能用。
pub fn candidates(configured: Option<&str>, automatic: &str) -> Vec<String> {
    let configured = configured.map(str::trim).filter(|text| !text.is_empty());
    let Some(path) = configured else {
        return vec![join(&log_root(None, automatic), GAMELOGS)];
    };
    let trimmed = trim_separators(path);
    if split_last(trimmed).is_some_and(|(_, last)| last.eq_ignore_ascii_case(GAMELOGS)) {
        return vec![trimmed.to_owned()];
    }
    let root = log_root(Some(path), automatic);
    vec![join(&root, GAMELOGS), root]
}

/// 文件名是否像游戏日志：以 `.txt` 结尾（不区分大小写），不以 `.` 开头。
pub fn is_log_file_name(name: &str) -> bool {
    !name.starts_with('.') && name.to_ascii_lowercase().ends_with(".txt")
}

/// 修改时间是否在最近 48 小时内。时间都是 1970 年以来的秒数。
pub fn is_recent(modified_at: f64, now: f64) -> bool {
    now - modified_at <= RECENT_WINDOW
}

/// 一个有收听者的候选文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// 文件名（不含目录）。
    pub name: String,
    /// 文件头里的收听者。
    pub listener: String,
}

/// 选出要跟踪的文件名，按文件名从大到小排列。
///
/// 同一个收听者有多个文件时只取文件名最大的（文件名以 UTC 时间开头，最大即最新）；
/// 总数超过 `limit` 时保留文件名最大的 `limit` 个。
pub fn select_followed(candidates: &[Candidate], limit: usize) -> Vec<String> {
    let mut newest: HashMap<&str, &str> = HashMap::new();
    for candidate in candidates {
        let entry = newest.entry(&candidate.listener).or_insert(&candidate.name);
        if candidate.name.as_str() > *entry {
            *entry = &candidate.name;
        }
    }
    let mut names: Vec<String> = newest.into_values().map(str::to_owned).collect();
    names.sort_unstable_by(|a, b| b.cmp(a));
    names.truncate(limit);
    names
}

/// 开始跟踪一个文件时是否从文件末尾读起。
///
/// 文件的创建时间早于跟踪服务的启动时刻减 2 秒时，是启动前已有的文件，历史内容不读、不触发提醒；
/// 否则是启动后才建的新文件，从头读起。读不到创建时间时按已有文件处理。
/// 启动后建的文件也可能晚跟踪，从头读起会带出旧历史；这部分由 [`super::replay`] 按行里的时间过滤。
pub fn starts_at_end(created_at: Option<f64>, tailer_started_at: f64) -> bool {
    created_at.is_none_or(|created| created < tailer_started_at - START_GRACE)
}

/// 一次读取的起点与是否被截断。文件长度小于已读偏移量时视为被截断，返回 `(0, true)`，
/// 调用方应同时重置分行器。
pub fn read_start(offset: u64, file_size: u64) -> (u64, bool) {
    if file_size < offset {
        (0, true)
    } else {
        (offset, false)
    }
}

/// 是否为路径分隔符（正反斜杠都认）。
fn is_separator(c: char) -> bool {
    c == '\\' || c == '/'
}

/// 去掉路径末尾多余的分隔符；只剩分隔符或盘符根（`C:\`）时保留一个。
fn trim_separators(path: &str) -> &str {
    let trimmed = path.trim_end_matches(is_separator);
    if trimmed.is_empty() || trimmed.ends_with(':') {
        // 根目录：保留原来的第一个分隔符。
        let keep = trimmed.len() + usize::from(path.len() > trimmed.len());
        &path[..keep]
    } else {
        trimmed
    }
}

/// 拆出上一级与最后一段；没有分隔符时返回 `None`。
fn split_last(path: &str) -> Option<(&str, &str)> {
    let index = path.rfind(is_separator)?;
    Some((&path[..index], &path[index + 1..]))
}

/// 在目录后接一段名字，用反斜杠连接；目录已以分隔符结尾时不再加。
fn join(directory: &str, name: &str) -> String {
    if directory.ends_with(is_separator) {
        format!("{directory}{name}")
    } else {
        format!("{directory}\\{name}")
    }
}
