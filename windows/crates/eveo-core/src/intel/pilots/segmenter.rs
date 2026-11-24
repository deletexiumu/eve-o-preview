// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的分人，对应 macOS 的 PilotSegmenter.swift（设计文档 6.9 节）。解析器推断的人名段经 ESI 核对后，
// 按查到的角色名重新分人；结果在显示时套用，IntelReport 本身不变（星图数据或核对结果更新时可以重算）。
//
// - runs：报告里的人名段。相邻两个 Pilot 段之间只有一段正好一个空格的 Plain 时属于同一段（6.4 节第 6 条把
//   超过 3 个词的一串切成几段，这里接回）。两个以上的空格、标点与术语都是边界。
// - candidates：要发给 ESI 的名字。只有一个词的人名段没有候选名字（单个词就是一个人，不查）；
//   两个词以上的段取连续的 1～3 个词，只留 3～37 个字符、只含英文字母、数字、' - 与空格的组合（E7），按比较键去重。
// - segment：给一个人名段分人。可用的名字（directory 里是 Matched）先取 2～3 个词的，让盖住的词最多；
//   一样多时名字少的优先；仍相同时从左起 3 个词的优先于 2 个词的，取名字优先于空着。没盖住的一串词（空缺）
//   每个词单独都可用时每词一人，否则按 6.4 节每 3 个词一人、状态是没查到。
// - resolve：整条消息的人名与敌对数量。新的人数是分出的人数；hostile_count 取原数量与新人数里较大的一个。
//   「查到」只说明有角色叫这个名字，不说明他在场，所以数量来自人名时不算写明。

//! 按 ESI 核对结果给人名段分人。

use std::collections::{HashMap, HashSet};

use super::{PilotLookupOutcome, key};
use crate::intel::{IntelReport, IntelSegmentKind};

/// 一个角色名至多几个词（E7）。
pub const MAX_NAME_WORDS: usize = 3;
/// 角色名的最短字符数（E7）。
pub const MIN_NAME_LENGTH: usize = 3;
/// 角色名的最长字符数（E7）。
pub const MAX_NAME_LENGTH: usize = 37;

/// 一个人名的核对状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PilotStatus {
    /// 还没有 ESI 的结果，或者这个人名段不查。
    Unchecked,
    /// ESI 有同名的角色，关联值是角色 ID。
    Matched(i64),
    /// 查过，没有同名的角色（含有歧义与被筛掉的组合）。
    NotFound,
}

/// 分出的一个人。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntelPilot {
    /// 查到的用 ESI 返回的写法，其余用原文的写法。
    pub name: String,
    /// 核对状态。
    pub status: PilotStatus,
}

impl IntelPilot {
    /// 用名字与状态建一个人。
    pub fn new(name: &str, status: PilotStatus) -> Self {
        Self {
            name: name.to_owned(),
            status,
        }
    }
}

/// 整条消息核对后的人名与敌对数量。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedPilots {
    /// 各人，按出现顺序。
    pub pilots: Vec<IntelPilot>,
    /// 敌对数量；None 表示判断不出。
    pub hostile_count: Option<i64>,
    /// 数量来自消息里写明的数字。
    pub count_is_explicit: bool,
}

/// 核对的结果表：比较键 → 结果。缓存持有一份，分人时借用。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PilotDirectory {
    /// 键是 [`key`] 的结果。
    outcomes: HashMap<String, PilotLookupOutcome>,
}

impl PilotDirectory {
    /// 用比较键到结果的表建目录。表里的键应已是比较键。
    pub fn new(outcomes: HashMap<String, PilotLookupOutcome>) -> Self {
        Self { outcomes }
    }

    /// 某个名字的结果；没有时为 None。名字先换成比较键再查。
    pub fn outcome(&self, name: &str) -> Option<&PilotLookupOutcome> {
        self.outcomes.get(&key(name))
    }

    /// 没有任何结果（开关关着，或还没查过）。
    pub fn is_empty(&self) -> bool {
        self.outcomes.is_empty()
    }

    /// 放进一项（键已是比较键），给缓存用。
    pub(crate) fn insert(&mut self, outcome_key: String, outcome: PilotLookupOutcome) {
        self.outcomes.insert(outcome_key, outcome);
    }

    /// 去掉一项，给缓存用。
    pub(crate) fn remove(&mut self, outcome_key: &str) {
        self.outcomes.remove(outcome_key);
    }
}

/// 报告里的各个人名段，每段是一串只隔一个空格的词。
pub fn runs(report: &IntelReport) -> Vec<Vec<String>> {
    let mut runs = Vec::new();
    // 正在收集的一串词。
    let mut current: Vec<String> = Vec::new();
    // 上一段是 Pilot 之后，是否只隔着一段正好一个空格的 Plain。
    let mut linkable = false;
    for segment in &report.segments {
        match segment.kind {
            IntelSegmentKind::Pilot => {
                // 中间不是「正好一个空格」：前一串结束。
                if !linkable && !current.is_empty() {
                    runs.push(std::mem::take(&mut current));
                }
                current.extend(segment.text.split(' ').map(str::to_owned));
                linkable = false;
            }
            IntelSegmentKind::Plain if segment.text == " " && !current.is_empty() && !linkable => {
                linkable = true;
            }
            _ => {
                if !current.is_empty() {
                    runs.push(std::mem::take(&mut current));
                }
                linkable = false;
            }
        }
    }
    if !current.is_empty() {
        runs.push(current);
    }
    runs
}

/// 要向 ESI 查的名字：两个词以上的人名段里 1～3 个词的连续组合，按比较键去重，保留先出现的。
pub fn candidates(report: &IntelReport) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for run in runs(report) {
        for name in combinations(&run) {
            if seen.insert(key(&name)) {
                result.push(name);
            }
        }
    }
    result
}

/// 给一个人名段分人。
pub fn segment(run: &[String], directory: &PilotDirectory) -> Vec<IntelPilot> {
    // 先算出这一段全部合规的组合；它们正是 candidates 发给 ESI 的名字，结果齐了才能分人。
    let combos = combinations(run);
    // 没有结果、没有候选名字、或有候选名字还没有结果时，按 6.4 节分人，状态是未核对：
    // 只拿到一部分结果就分人，等其余结果到了显示会跳一下。
    if directory.is_empty() || combos.is_empty() || combos.iter().any(|c| directory.outcome(c).is_none()) {
        return chunked(run, PilotStatus::Unchecked);
    }
    // 可用的名字：组合合规且结果是 Matched。被筛掉的组合不可用。
    let usable = |start: usize, count: usize| -> Option<(i64, String)> {
        let name = run[start..start + count].join(" ");
        if !is_acceptable(&name) {
            return None;
        }
        match directory.outcome(&name)? {
            PilotLookupOutcome::Matched { character_id, name } => Some((*character_id, name.clone())),
            _ => None,
        }
    };
    // 先选多词名字（2～3 个词），单词名字只在空缺里用：单个词查到的往往只是凑巧有人叫这个名字。
    let picks = best_cover(run.len(), |start, count| usable(start, count).is_some());
    let mut pilots = Vec::new();
    // 当前空缺的起点：连续几个没被选中的词。
    let mut gap_start: Option<usize> = None;
    // 把 gap_start..end 的空缺分人：每个词单独都查到时每词一人，否则按 3 个词一人、状态是没查到。
    let flush_gap = |gap_start: &mut Option<usize>, end: usize, pilots: &mut Vec<IntelPilot>| {
        let Some(start) = gap_start.take() else {
            return;
        };
        let singles: Option<Vec<(i64, String)>> = (start..end).map(|i| usable(i, 1)).collect();
        match singles {
            Some(found) => pilots.extend(
                found
                    .into_iter()
                    .map(|(id, name)| IntelPilot::new(&name, PilotStatus::Matched(id))),
            ),
            None => pilots.extend(chunked(&run[start..end], PilotStatus::NotFound)),
        }
    };
    // 从左往右走：选中的起点出一个查到的人，其余的词攒进空缺，遇到下一个选中的名字或走到末尾时分掉。
    let mut index = 0;
    while index < run.len() {
        if let Some(count) = picks[index]
            && let Some((id, name)) = usable(index, count)
        {
            flush_gap(&mut gap_start, index, &mut pilots);
            pilots.push(IntelPilot::new(&name, PilotStatus::Matched(id)));
            index += count;
        } else {
            gap_start.get_or_insert(index);
            index += 1;
        }
    }
    flush_gap(&mut gap_start, run.len(), &mut pilots);
    pilots
}

/// 整条消息的人名与敌对数量。
pub fn resolve(report: &IntelReport, directory: &PilotDirectory) -> ResolvedPilots {
    // 没有任何结果时与解析结果相同，全部未核对。
    if directory.is_empty() {
        return ResolvedPilots {
            pilots: report
                .pilots
                .iter()
                .map(|name| IntelPilot::new(name, PilotStatus::Unchecked))
                .collect(),
            hostile_count: report.hostile_count,
            count_is_explicit: report.count_is_explicit,
        };
    }
    let pilots: Vec<IntelPilot> = runs(report)
        .iter()
        .flat_map(|run| segment(run, directory))
        .collect();
    // 只会变大不会变小：写明的「5」不会因为只认出 2 个人名就变成 2。
    let hostile_count = if pilots.is_empty() {
        report.hostile_count
    } else {
        Some(report.hostile_count.unwrap_or(0).max(pilots.len() as i64))
    };
    // 数量没变时沿用原来的「写明」；变了说明新数量来自人名，人名不算写明。
    let count_is_explicit = hostile_count == report.hostile_count && report.count_is_explicit;
    ResolvedPilots {
        pilots,
        hostile_count,
        count_is_explicit,
    }
}

/// 一个人名段的候选名字：只有一个词时没有；否则取连续的 1～3 个词，只留合规的组合。
pub(crate) fn combinations(run: &[String]) -> Vec<String> {
    if run.len() < 2 {
        return Vec::new();
    }
    let mut result = Vec::new();
    for start in 0..run.len() {
        for count in 1..=MAX_NAME_WORDS {
            if start + count > run.len() {
                break;
            }
            let name = run[start..start + count].join(" ");
            if is_acceptable(&name) {
                result.push(name);
            }
        }
    }
    result
}

/// 组合是否合规：3～37 个字符，只含英文字母、数字、`'`、`-` 与空格（E7）。
pub(crate) fn is_acceptable(name: &str) -> bool {
    let length = name.chars().count();
    (MIN_NAME_LENGTH..=MAX_NAME_LENGTH).contains(&length)
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '\'' | '-' | ' '))
}

/// 6.4 节的分法：从左起每 3 个词一个人。
fn chunked(words: &[String], status: PilotStatus) -> Vec<IntelPilot> {
    words
        .chunks(MAX_NAME_WORDS)
        .map(|chunk| IntelPilot::new(&chunk.join(" "), status))
        .collect()
}

/// 从某个位置到末尾的最好选法。
#[derive(Debug, Clone, Copy)]
struct Best {
    /// 盖住的词数。
    covered: usize,
    /// 名字个数。
    names: usize,
    /// 这个位置取几个词；None 是空着。
    take: Option<usize>,
}

impl Best {
    /// 盖住的词更多，或一样多而名字更少。
    fn is_better_than(self, other: Self) -> bool {
        if self.covered != other.covered {
            return self.covered > other.covered;
        }
        self.names < other.names
    }
}

/// 选一组互不重叠的 2～3 个词的可用名字，盖住的词最多；一样多时名字少的优先；仍相同时从左起
/// 3 个词的优先于 2 个词的，取名字优先于空着。从右到左动态规划，后一种选法严格更好时才替换前一种，
/// 所以先试的（3 个词、取名字）在平手时留下。返回每个起点选中的词数（没选中的位置为 None）。
pub(crate) fn best_cover(word_count: usize, usable: impl Fn(usize, usize) -> bool) -> Vec<Option<usize>> {
    let empty = Best {
        covered: 0,
        names: 0,
        take: None,
    };
    // best[i] 是从第 i 个词到末尾的最好选法；best[word_count] 是空的结尾。
    let mut best = vec![empty; word_count + 1];
    for start in (0..word_count).rev() {
        let mut choice: Option<Best> = None;
        for take in [3, 2] {
            if start + take > word_count || !usable(start, take) {
                continue;
            }
            let rest = best[start + take];
            let option = Best {
                covered: rest.covered + take,
                names: rest.names + 1,
                take: Some(take),
            };
            if choice.is_none_or(|current| option.is_better_than(current)) {
                choice = Some(option);
            }
        }
        // 空着这个词：沿用下一个位置的选法，盖住的词数与名字个数不变。
        let skip = Best {
            take: None,
            ..best[start + 1]
        };
        best[start] = match choice {
            Some(current) if !skip.is_better_than(current) => current,
            _ => skip,
        };
    }
    // 从左往右走一遍，取出各起点的选择。
    let mut picks = vec![None; word_count];
    let mut index = 0;
    while index < word_count {
        if let Some(take) = best[index].take {
            picks[index] = Some(take);
            index += take;
        } else {
            index += 1;
        }
    }
    picks
}
