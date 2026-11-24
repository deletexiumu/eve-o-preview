// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志目录的查找与文件的取舍，对应 macOS 的 ChatLogDirectory.swift（设计文档 5.2 节、5.4 节）。只做纯计算。
// - candidates：general.eveLogDirectory 可能指向 logs、Gamelogs 或 Chatlogs，都换算成 Chatlogs 的候选。路径是
//   Windows 的写法，正反斜杠都认，拼接用反斜杠；自动查找的 logs 目录由调用方给出（「文档」已知文件夹）。
// - game_log_candidates：位置线索要读的游戏日志目录。combat_log 的候选本来就把 Chatlogs 当作上一级处理。
// - parse_file_name：文件名是「频道名_yyyyMMdd_HHmmss_数字.txt」，频道名里可以有 `.`、`+`、`_`，所以从右边解析。
// - select_followed：每个（收听者，频道 ID）只跟踪最新的文件，至多 48 个。
// - aligned_offset、backfill_start：UTF-16 的偏移量都取偶数，否则之后的每个字符都错位。

//! 聊天日志目录的候选、文件名的解析与跟踪文件的取舍。

use crate::combat_log::directory::{
    self as combat, CHATLOGS, GAMELOGS, join, log_root, split_last, trim_separators,
};

/// 同时跟踪的聊天日志文件数上限。
pub const MAX_FOLLOWED_FILES: usize = 48;
/// 只看修改时间在这么多秒以内的文件：48 小时。
pub const RECENT_SECONDS: f64 = 172_800.0;

/// 文件名解析出的三部分。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileName {
    /// 文件名里的频道名。
    pub channel: String,
    /// 时间戳 `yyyyMMdd_HHmmss`，可按字符串比较新旧。
    pub stamp: String,
    /// 末尾的数字。
    pub suffix: String,
}

/// 一个读过文件头的候选文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// 文件名（不含目录）。
    pub name: String,
    /// 文件名里的时间戳 `yyyyMMdd_HHmmss`。
    pub stamp: String,
    /// 文件头的收听者。
    pub listener: String,
    /// 文件头的 Channel ID。
    pub channel_id: String,
}

/// 按优先顺序返回可能的 Chatlogs 目录路径。`configured` 是 `general.eveLogDirectory`，`automatic` 是自动查找的 logs 目录：
/// - `None` 或空白：返回 `<automatic>\Chatlogs`。
/// - 最后一段是 `Chatlogs`（不区分大小写）：只返回它自己。
/// - 最后一段是 `Gamelogs`：返回同级的 `Chatlogs`。
/// - 其他：返回 `[<configured>\Chatlogs, <configured>]`。
pub fn candidates(configured: Option<&str>, automatic: &str) -> Vec<String> {
    let Some(path) = configured.map(str::trim).filter(|text| !text.is_empty()) else {
        return vec![join(&log_root(None, automatic), CHATLOGS)];
    };
    let trimmed = trim_separators(path);
    match split_last(trimmed) {
        Some((_, last)) if last.eq_ignore_ascii_case(CHATLOGS) => vec![trimmed.to_owned()],
        Some((_, last)) if last.eq_ignore_ascii_case(GAMELOGS) => {
            vec![join(&log_root(Some(path), automatic), CHATLOGS)]
        }
        _ => vec![join(trimmed, CHATLOGS), trimmed.to_owned()],
    }
}

/// 游戏日志目录的候选（位置线索用，5.6 节）。设置指向 Chatlogs 时，combat_log 的规则已按它的上一级找 Gamelogs。
pub fn game_log_candidates(configured: Option<&str>, automatic: &str) -> Vec<String> {
    combat::candidates(configured, automatic)
}

/// 解析聊天日志的文件名。以 `.txt` 结尾（不区分大小写）；去掉扩展名后从右边取 3 段：一段数字、6 位数字、
/// 8 位数字，各由 `_` 隔开；再往左的全部内容是频道名，不能为空。不符合时返回 `None`。
pub fn parse_file_name(name: &str) -> Option<FileName> {
    if name.len() <= 4
        || !name.is_char_boundary(name.len() - 4)
        || !name[name.len() - 4..].eq_ignore_ascii_case(".txt")
    {
        return None;
    }
    let base = &name[..name.len() - 4];
    let mut parts = base.rsplitn(4, '_');
    let suffix = parts.next()?;
    let time = parts.next()?;
    let date = parts.next()?;
    let channel = parts.next()?;
    let valid = is_digits(suffix, None)
        && is_digits(time, Some(6))
        && is_digits(date, Some(8))
        && !channel.is_empty();
    valid.then(|| FileName {
        channel: channel.to_owned(),
        stamp: format!("{date}_{time}"),
        suffix: suffix.to_owned(),
    })
}

/// 选出要跟踪的文件名：每个（收听者，频道 ID）只留时间戳最大的文件（相同时取文件名大的），
/// 再按时间戳从新到旧取前 `limit` 个。
pub fn select_followed(candidates: &[Candidate], limit: usize) -> Vec<String> {
    let mut newest: Vec<&Candidate> = Vec::new();
    for candidate in candidates {
        match newest
            .iter_mut()
            .find(|c| c.listener == candidate.listener && c.channel_id == candidate.channel_id)
        {
            Some(current) if is_newer(candidate, current) => *current = candidate,
            Some(_) => {}
            None => newest.push(candidate),
        }
    }
    newest.sort_by(|a, b| key(b).cmp(&key(a)));
    newest.into_iter().take(limit).map(|c| c.name.clone()).collect()
}

/// 把字节偏移量向下取成偶数（UTF-16 的码元边界）。
pub fn aligned_offset(offset: u64) -> u64 {
    offset & !1
}

/// 补读的起点：文件长度减 `max_bytes`，不小于 0，取偶数。
pub fn backfill_start(file_size: u64, max_bytes: u64) -> u64 {
    aligned_offset(file_size.saturating_sub(max_bytes))
}

/// 是否全是 ASCII 数字；`count` 不为 `None` 时还要求长度相同（为 `None` 时至少 1 位）。
fn is_digits(text: &str, count: Option<usize>) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) && count.is_none_or(|n| text.len() == n)
}

/// 新旧比较的键：先比时间戳，相同时比文件名。
fn key(candidate: &Candidate) -> (&str, &str) {
    (&candidate.stamp, &candidate.name)
}

/// `a` 是否比 `b` 新。
fn is_newer(a: &Candidate, b: &Candidate) -> bool {
    key(a) > key(b)
}
