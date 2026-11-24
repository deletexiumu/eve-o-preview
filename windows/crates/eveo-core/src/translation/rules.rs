// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的判断与分批规则，对应 macOS 的 TranslationRules.swift（设计文档 7.6 节、7.8 节）：
// - already_in：按文字种类的占比判断消息是否已经是目标语言。
// - skip_reason：不用交给模型的原因。
// - cache_key：缓存比对用的原文。
// - next_batch：从待翻译的消息里取下一批。
// - result_phase：模型的结果换成这条消息的阶段（原样抄回的、拉丁字母目标语言下原文已是目标语言的不算译文）。
// - render_terms：只把术语换成目标语言的写法（「只有术语」的消息不用模型）。
// 全部是纯函数，术语匹配与情报分段由调用方算好传入。
//
// 与 macOS 的差别：
// - 「字符数」按字素簇计，与 Swift 的 String.count 相同（中文、表情各算一个）。
// - 字母用 char::is_alphabetic（Unicode 的 Alphabetic 属性）判断。它比 Swift 用的字母类别（L*）多出少量
//   组合记号与字母数字（如罗马数字），只影响分母的极少数情况；按码位区间统计的几种文字与 macOS 相同。
// - 术语匹配的范围是字节下标；越界或不在字符边界上的匹配当作无效，与 macOS 忽略越界的匹配一致。

//! 翻译的判断、缓存键、分批与术语替换。

use std::collections::BTreeSet;

use unicode_segmentation::UnicodeSegmentation;

use super::{Phase, SkipReason, TranslatedText, TranslationItem};
use crate::chat_log::ChatLine;
use crate::intel::IntelReport;
use crate::intel::parser::remainder;
use crate::model::AppLanguage;
use crate::static_data::matcher::{TermKind, TermMatch};
use crate::support::StringEnum;

/// 某种文字占字母的比例不小于它时，认为已经是这种语言。
pub const SCRIPT_SHARE_THRESHOLD: f64 = 0.5;
/// 一批至多几条消息。
pub const MAX_BATCH_MESSAGES: usize = 20;
/// 一批合计至多几个字符（每条按截断后的长度计）。
pub const MAX_BATCH_CHARACTERS: usize = 6_000;
/// 每条送去翻译的文字至多几个字符，超出的部分截掉。
pub const MAX_MESSAGE_CHARACTERS: usize = 500;
/// 补读的消息只排最近这么多秒内的。
pub const BACKFILL_QUEUE_SECONDS: f64 = 600.0;
/// 补读的消息至多排这么多条。
pub const BACKFILL_QUEUE_LIMIT: usize = 20;

/// 文字是否已经是目标语言（按文字种类的占比判断），或者没有字母（7.6 节）。
///
/// 1. 没有字母时为真。
/// 2. 中文：含假名时为假；否则汉字占字母的比例不小于 0.5 时为真。
/// 3. 日文：含假名，且假名加汉字的占比不小于 0.5 时为真。
/// 4. 韩文：谚文的占比不小于 0.5 时为真。
/// 5. 俄文：西里尔字母的占比不小于 0.5 时为真。
/// 6. 英、德、法、西文：为假，交给模型判断。
pub fn already_in(text: &str, target: AppLanguage) -> bool {
    let (mut letters, mut han, mut kana, mut hangul, mut cyrillic) = (0usize, 0usize, 0usize, 0usize, 0usize);
    for c in text.chars() {
        if c.is_alphabetic() {
            letters += 1;
        }
        // 与参考实现的正则一致：按码位区间计数，不看是不是字母。
        let value = u32::from(c);
        if (0x3400..=0x9FFF).contains(&value) || (0xF900..=0xFAFF).contains(&value) {
            han += 1;
        }
        if (0x3040..=0x30FF).contains(&value) {
            kana += 1;
        }
        if (0xAC00..=0xD7AF).contains(&value) || (0x1100..=0x11FF).contains(&value) {
            hangul += 1;
        }
        if (0x0400..=0x04FF).contains(&value) {
            cyrillic += 1;
        }
    }
    if letters == 0 {
        return true;
    }
    // 字母数远小于 2^52，换成 f64 不丢精度。
    let share = |count: usize| count as f64 / letters as f64 >= SCRIPT_SHARE_THRESHOLD;
    match target {
        AppLanguage::Zh => kana == 0 && share(han),
        AppLanguage::Ja => kana > 0 && share(kana + han),
        AppLanguage::Ko => share(hangul),
        AppLanguage::Ru => share(cyrillic),
        AppLanguage::En | AppLanguage::Fr | AppLanguage::De | AppLanguage::Es => false,
    }
}

/// 不用交给模型的原因；都不成立时为 None（7.6 节）。
///
/// 按顺序取第一个成立的：系统消息；正文去掉空白后为空；正文已是目标语言；
/// 是情报样的消息，且去掉术语、人数与人名后剩下的文字已是目标语言（或为空）。
pub fn skip_reason(line: &ChatLine, report: &IntelReport, target: AppLanguage) -> Option<SkipReason> {
    if line.is_system {
        return Some(SkipReason::SystemSpeaker);
    }
    if line.text.trim().is_empty() {
        return Some(SkipReason::Empty);
    }
    if already_in(&line.text, target) {
        return Some(SkipReason::SameLanguage);
    }
    if report.is_intel_like() && already_in(&remainder(report), target) {
        return Some(SkipReason::TermsOnly);
    }
    None
}

/// 缓存比对用的原文（7.8 节）：按行处理，去掉「后面是空白或行尾」的 `*`，连续空白并成一个空格，
/// 去掉首尾空白；空行去掉；各行用换行连接。
///
/// `*` 的判断看的是原文里它后面的字符（与参考实现的正则 `\*(?=\s|$)` 相同），所以 `a**` 只去掉最后一个。
/// 按 `\n` 切行，CRLF 切出的行里剩下的 `\r` 按空白处理。
pub fn cache_key(text: &str) -> String {
    let mut lines = Vec::new();
    for raw_line in text.split('\n') {
        let chars: Vec<char> = raw_line.chars().collect();
        let mut kept = String::new();
        let mut pending_space = false;
        for (index, &c) in chars.iter().enumerate() {
            if c == '*' && chars.get(index + 1).is_none_or(|next| next.is_whitespace()) {
                continue;
            }
            if c.is_whitespace() {
                pending_space = true;
                continue;
            }
            if pending_space && !kept.is_empty() {
                kept.push(' ');
            }
            pending_space = false;
            kept.push(c);
        }
        if !kept.is_empty() {
            lines.push(kept);
        }
    }
    lines.join("\n")
}

/// 一条消息送去翻译时计入的字符数：截断到 [`MAX_MESSAGE_CHARACTERS`] 后的长度。
pub fn sent_length(text: &str) -> usize {
    text.graphemes(true).take(MAX_MESSAGE_CHARACTERS).count()
}

/// 送去翻译的文字：至多前 [`MAX_MESSAGE_CHARACTERS`] 个字符。
pub fn sent_text(text: &str) -> &str {
    match text.grapheme_indices(true).nth(MAX_MESSAGE_CHARACTERS) {
        Some((end, _)) => &text[..end],
        None => text,
    }
}

/// 从待翻译的消息里取下一批（7.6 节）：按给出的顺序看 Pending 的消息，`cache_key` 相同的只取第一条；
/// 一批至多 max_messages 条（不超过 20，答复被截断后队列会调小）、合计至多 6,000 个字符
/// （每条按截断到 500 个字符后计），第一条总是能取。
pub fn next_batch(pending: &[TranslationItem], max_messages: usize) -> Vec<TranslationItem> {
    let limit = max_messages.clamp(1, MAX_BATCH_MESSAGES);
    let mut batch: Vec<TranslationItem> = Vec::new();
    let mut keys = BTreeSet::new();
    let mut size = 0;
    for item in pending.iter().filter(|item| item.phase == Phase::Pending) {
        let key = cache_key(&item.message.text);
        if keys.contains(&key) {
            continue;
        }
        let length = sent_length(&item.message.text);
        if !batch.is_empty() && size + length > MAX_BATCH_CHARACTERS {
            break;
        }
        keys.insert(key);
        batch.push(item.clone());
        size += length;
        if batch.len() >= limit {
            break;
        }
    }
    batch
}

/// 模型的结果（或缓存里的译文）换成这条消息的阶段：
/// 1. 译文与原文的 `cache_key` 相同：模型原样抄回，是 Skipped(SameLanguage)，浮窗不把同一句显示两遍。
/// 2. 目标语言是英、德、法、西文，且模型给的原文语言（去掉 `-`、`_` 后的地区部分）就是目标语言：
///    是 Skipped(SameLanguage)。「只显示翻译过的消息」打开时这类消息不显示。
/// 3. 其余是 Done。结果照常进译文缓存，下次不再付费。
pub fn result_phase(result: &TranslatedText, original: &str, target: AppLanguage) -> Phase {
    if cache_key(&result.text) == cache_key(original) {
        return Phase::Skipped(SkipReason::SameLanguage, None);
    }
    // 用拉丁字母书写的目标语言按文字种类判断不出是否已是目标语言，要看模型的结果。
    let latin = matches!(
        target,
        AppLanguage::En | AppLanguage::Fr | AppLanguage::De | AppLanguage::Es
    );
    if latin
        && let Some(code) = &result.source_language
        && code.split(['-', '_']).next() == Some(target.raw())
    {
        return Phase::Skipped(SkipReason::SameLanguage, None);
    }
    Phase::Done {
        text: result.text.clone(),
        source_language: result.source_language.clone(),
    }
}

/// 把术语换成目标语言的写法；写法相同（不区分大小写）的不动（7.6 节）。
///
/// 星系、星域、舰船与舰船分组换成 `name_in(target)`；名称后面的 `*`（中文客户端的翻译标记）随之去掉。
/// 情报用语只在有目标语言的译名时才换，不换成英文的规范写法（`clr` 不会变成 `clear`）。
/// 范围不在这段文字里、或与前一处重叠的匹配忽略。
pub fn render_terms(text: &str, matches: &[TermMatch], target: AppLanguage) -> String {
    let mut result = String::with_capacity(text.len());
    let mut cursor = 0;
    for term in valid_matches(matches, text) {
        let Some(replacement) = replacement(term, text, target) else {
            continue;
        };
        result.push_str(&text[cursor..term.range.start]);
        result.push_str(replacement);
        cursor = term.range.end;
    }
    result.push_str(&text[cursor..]);
    result
}

/// 一处匹配在原文里的写法：去掉末尾的 `*` 与空白。调用方保证范围有效（来自 [`valid_matches`]）。
pub fn source_spelling<'a>(term: &TermMatch, text: &'a str) -> &'a str {
    text[term.range.clone()].trim_end_matches(|c: char| c == '*' || c.is_whitespace())
}

/// 范围在文字里、按位置排序且互不重叠的匹配。起点相同时长的优先（`Naga Navy Issue` 胜过 `Naga`）。
pub fn valid_matches<'m>(matches: &'m [TermMatch], text: &str) -> Vec<&'m TermMatch> {
    let mut sorted: Vec<&TermMatch> = matches
        .iter()
        .filter(|m| {
            m.range.start < m.range.end
                && m.range.end <= text.len()
                && text.is_char_boundary(m.range.start)
                && text.is_char_boundary(m.range.end)
        })
        .collect();
    sorted.sort_by(|a, b| {
        a.range
            .start
            .cmp(&b.range.start)
            .then(b.range.end.cmp(&a.range.end))
    });
    let mut result = Vec::new();
    let mut last_end = 0;
    for term in sorted {
        if term.range.start >= last_end {
            last_end = term.range.end;
            result.push(term);
        }
    }
    result
}

/// 一处匹配的替换文字；不用替换时为 None。
fn replacement<'m>(term: &'m TermMatch, text: &str, target: AppLanguage) -> Option<&'m str> {
    let name = match term.kind {
        TermKind::IntelWord(_) => term.localized.get(target.raw())?.as_str(),
        _ => term.name_in(target),
    };
    let source = source_spelling(term, text);
    (!name.is_empty() && !equal_ignoring_case(name, source)).then_some(name)
}

/// 两种写法是否只差大小写（与 Swift 的 caseInsensitiveCompare 的常见情况相同）。
pub(super) fn equal_ignoring_case(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}
