// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的汇总，对应 macOS 的 IntelParser+Counting.swift（设计文档 6.4 节「舰船的数量与敌对数量」）：
// 由分好的段算出星系、舰船与数量、人名、敌对数量与两个用语标志。
//
// 数量的归属：
// 1. 人数与它前面最近的非 Plain 段之间只有空白、且那一段是还没有数量的舰船或舰船分组时，归给那艘船。
//    「还没有数量」让 `2 Naga 3 Machariel` 里的 3 归给 Machariel。
// 2. 否则，写法是 `3`、`3x`、`3×`，且它后面最近的非 Plain 段是还没有数量的舰船或舰船分组、中间只有空白时，
//    归给后面那艘船。
// 3. 其余是独立人数。
// 敌对数量：甲是各船数量之和，乙是独立人数里最大的，丙是人名个数。is_clear、甲与丙都是 0、且消息里没有人数时是 0；
// 否则取三者最大，最大是 0 时为 None。取最大不相加：同一批敌对常常既写人名又写船型。
// is_clear：有「安全」用语，且这个用语不是否定或疑问时才为真：
// - 前面 3 个词里有 not、no、never 或以 n't 结尾的词时不算（`Jita not clear`、`not yet clr`、`never clr`）。
//   只往回看到前一个不是普通文字的段为止，遇到以 `.`、`;`、`!`、`。`、`；`、`！` 结尾的词（上一句）也停；
//   逗号不算句子结束。「no reds clr」里的 no 否定的是敌对，不算。
// - 用语后面紧跟 `?` 或 `？`（中间可有空白），或整条消息以 `?`、`？` 结尾（`Amarr clear?`）时不算。

use std::collections::HashMap;

use super::parser::CountForm;
use super::{IntelReport, IntelSegment, IntelSegmentKind, IntelShipMention};
use crate::static_data::matcher::{IntelWord, TermKind};

/// 往回看几个词找否定词。
const NEGATION_LOOK_BACK: usize = 3;

/// 跟在 no 后面时表示「没有敌对」的名词：这时 no 不否定后面的安全用语。
const HOSTILE_NOUNS: [&str; 11] = [
    "red", "reds", "hostile", "hostiles", "neut", "neuts", "enemy", "enemies", "one", "contacts", "spike",
];

/// 由分好的段算出解析结果。forms 与段里的人数一一对应，按出现顺序。
pub(super) fn summarize(segments: Vec<IntelSegment>, forms: &[CountForm]) -> IntelReport {
    let (ship_counts, independent) = attribute_counts(&segments, forms);

    // 一次遍历收集星系（去重、保留首次出现的顺序）、舰船、人名与两个用语标志。
    // 没有写数量的舰船算 1 艘：频道里只写船型时通常就是一艘。

    let mut system_ids = Vec::new();
    let mut ships = Vec::new();
    let mut pilots = Vec::new();
    let mut is_clear = false;
    let mut is_no_visual = false;
    for (index, segment) in segments.iter().enumerate() {
        let count = ship_counts.get(&index).copied().unwrap_or(1);
        match segment.kind {
            IntelSegmentKind::System(id) if !system_ids.contains(&id) => system_ids.push(id),
            IntelSegmentKind::Ship(id) => ships.push(IntelShipMention {
                kind: TermKind::Ship(id),
                count,
            }),
            IntelSegmentKind::ShipGroup(id) => ships.push(IntelShipMention {
                kind: TermKind::ShipGroup(id),
                count,
            }),
            IntelSegmentKind::Pilot => pilots.push(segment.text.clone()),
            IntelSegmentKind::Word(IntelWord::Clear) if !is_negated_or_question(&segments, index) => {
                is_clear = true;
            }
            IntelSegmentKind::Word(IntelWord::NoVisual) => is_no_visual = true,
            _ => {}
        }
    }

    // 甲、乙、丙三个数。
    let ship_total: i64 = ships.iter().map(|s| s.count).sum();
    let independent_max = independent.iter().copied().max().unwrap_or(0);
    let pilot_count = pilots.len() as i64;
    // 「Jita clear」这类只报安全的消息是 0；只要提到了船、人名或人数，就按三者最大算，
    // 避免「clear 但有 1 艘 Sabre 在门口」被当成 0。
    let (hostile_count, count_is_explicit) = if is_clear
        && ship_total == 0
        && pilot_count == 0
        && independent.is_empty()
        && ship_counts.is_empty()
    {
        (Some(0), false)
    } else {
        let best = ship_total.max(independent_max).max(pilot_count);
        // 最大的数来自写明的独立人数，或来自归给舰船的写明数量时，才算「写明」。
        let explicit = best > 0
            && ((best == independent_max && independent_max > 0)
                || (best == ship_total && !ship_counts.is_empty()));
        ((best > 0).then_some(best), explicit)
    };
    IntelReport {
        segments,
        system_ids,
        ships,
        pilots,
        hostile_count,
        count_is_explicit,
        is_clear,
        is_no_visual,
    }
}

/// 按文件头的 3 条规则分配人数：返回「舰船段的下标 → 数量」与独立人数。
fn attribute_counts(segments: &[IntelSegment], forms: &[CountForm]) -> (HashMap<usize, i64>, Vec<i64>) {
    // 非 Plain 段的下标。
    let marked: Vec<usize> = (0..segments.len())
        .filter(|&i| segments[i].kind != IntelSegmentKind::Plain)
        .collect();
    // 两段之间是否只有空白（中间的段都是只含空白的 Plain）。
    let only_space_between = |left: usize, right: usize| {
        left < right
            && segments[left + 1..right]
                .iter()
                .all(|s| s.kind == IntelSegmentKind::Plain && s.text.chars().all(char::is_whitespace))
    };
    let mut ship_counts: HashMap<usize, i64> = HashMap::new();
    let mut independent = Vec::new();
    // forms 只对应人数段，所以单独计数，不能用段的下标去取。
    let mut form_index = 0;
    for (position, &index) in marked.iter().enumerate() {
        let IntelSegmentKind::Count(value) = segments[index].kind else {
            continue;
        };
        let form = forms.get(form_index).copied().unwrap_or(CountForm::Other);
        form_index += 1;
        // 规则 1：归给前面紧挨着、还没有数量的舰船。
        if let Some(&previous) = position.checked_sub(1).and_then(|p| marked.get(p))
            && segments[previous].kind.is_ship()
            && !ship_counts.contains_key(&previous)
            && only_space_between(previous, index)
        {
            ship_counts.insert(previous, value);
            continue;
        }
        // 规则 2：前置写法归给后面紧挨着、还没有数量的舰船。
        if form == CountForm::Leading
            && let Some(&next) = marked.get(position + 1)
            && segments[next].kind.is_ship()
            && !ship_counts.contains_key(&next)
            && only_space_between(index, next)
        {
            ship_counts.insert(next, value);
            continue;
        }
        // 规则 3：独立人数。
        independent.push(value);
    }
    (ship_counts, independent)
}

/// 第 index 段的「安全」用语是否被否定或是疑问：前面至多 3 个普通词里有否定词（见文件头）；
/// 用语后面（跳过空白）紧跟 `?`、`？`；或整条消息去掉末尾空白后以 `?`、`？` 结尾。
fn is_negated_or_question(segments: &[IntelSegment], index: usize) -> bool {
    let is_question_mark = |c: char| c == '?' || c == '？';
    let after: String = segments[index + 1..].iter().map(|s| s.text.as_str()).collect();
    if after
        .chars()
        .find(|c| !c.is_whitespace())
        .is_some_and(is_question_mark)
    {
        return true;
    }
    let whole: String = segments.iter().map(|s| s.text.as_str()).collect();
    if whole
        .chars()
        .rev()
        .find(|c| !c.is_whitespace())
        .is_some_and(is_question_mark)
    {
        return true;
    }
    // 紧挨在前面的普通文字（相邻的 Plain 已并成一段，所以至多一段）。
    let Some(previous) = index.checked_sub(1).map(|i| &segments[i]) else {
        return false;
    };
    if previous.kind != IntelSegmentKind::Plain {
        return false;
    }
    let mut words: Vec<&str> = previous.text.split_whitespace().collect();
    // 上一句结束的词及它前面的词不看。
    if let Some(end) = words
        .iter()
        .rposition(|w| w.ends_with(['.', ';', '!', '。', '；', '！']))
    {
        words.drain(..=end);
    }
    // 只看最后 3 个词；去掉两端不是字母的字符（保留中间的撇号），转成小写。
    let skip = words.len().saturating_sub(NEGATION_LOOK_BACK);
    let lowered: Vec<String> = words[skip..]
        .iter()
        .map(|w| w.trim_matches(|c: char| !c.is_alphabetic()).to_lowercase())
        .collect();
    lowered.iter().enumerate().any(|(i, lower)| {
        // 「no reds clr」「no hostiles clr」里的 no 否定的是敌对，整句仍是安全，不算否定。
        if lower == "no"
            && lowered
                .get(i + 1)
                .is_some_and(|n| HOSTILE_NOUNS.contains(&n.as_str()))
        {
            return false;
        }
        matches!(lower.as_str(), "not" | "no" | "never") || lower.ends_with("n't") || lower.ends_with("n’t")
    })
}
