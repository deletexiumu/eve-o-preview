// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的分段、人数与人名，对应 macOS 的 IntelParser.swift（设计文档 6.4 节）。
//
// parse 的步骤：
// 1. 每个术语匹配成为一段；匹配之间的文字是「空隙」。
// 2. 空隙按空白切成词，记下每个词前面的空白。
// 3. 人数：去掉末尾的 , ， . ; : 后是 +3、x3、3、3x、3+、3人 等 13 种形式之一，数字 1～3 位、数值 1～500。
// 4. 紧跟在舰船或舰船分组之后、以 1～3 位数字开头且数字后直接是汉字的词：数字是人数，其余是普通文字。
// 5. 人名：消息里至少认出一个星系、舰船或舰船分组时，去掉两端标点后不含汉字假名谚文、不是常见情报词、
//    至少含一个字母、含大写字母或数字的词是候选（`15:30` 这类没有字母的词不是）。
// 6. 相邻候选之间正好隔一个空格时并成一个人名，从左起每 3 个词一个人名，人名之间的一个空格单独成一段 Plain。
// 7. 其余是 Plain，相邻的 Plain 并成一段。各段拼起来与原文逐字符相同。
// 数量的归属与敌对数量见 counting.rs。

//! 预警消息的分段、人数与人名。

use super::counting::summarize;
use super::{IntelReport, IntelSegment, IntelSegmentKind};
use crate::static_data::EveStaticData;
use crate::static_data::lexicon::{is_cjk, is_non_pilot_word};
use crate::static_data::matcher::{TermKind, TermMatch};

/// 一个人名至多几个词；人名的总词数超过它时，remainder 把人名也算进剩下的文字。
pub const MAX_PILOT_WORDS: usize = 3;

/// 人数的写法。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CountForm {
    /// `3`、`3x`、`3×`：可以归给后面的舰船。
    Leading,
    /// 其他写法：只能归给前面的舰船，或作独立人数。
    Other,
}

/// 一小段的用途。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    /// 术语。
    Term(IntelSegmentKind),
    /// 空白。
    Space,
    /// 人数与它的写法。
    Count(i64, CountForm),
    /// 人名的候选词（已去掉两端标点）。
    Candidate,
    /// 普通文字。
    Plain,
}

/// 解析过程中的一小段。
#[derive(Debug, Clone)]
struct Piece {
    /// 原文。
    text: String,
    /// 用途。
    role: Role,
}

impl Piece {
    /// 用文字与用途建一小段。
    fn new(text: &str, role: Role) -> Self {
        Self {
            text: text.to_owned(),
            role,
        }
    }
}

/// 用算好的术语匹配解析一条消息。matches 应按位置排序、互不重叠，范围是 text 的字节下标。
pub fn parse(text: &str, matches: &[TermMatch]) -> IntelReport {
    let mut pieces = Vec::new();
    let mut cursor = 0;
    for m in matches {
        // 与前一处重叠或超出原文的匹配跳过（调用方给的匹配本应有序、互不重叠）。
        if m.range.start < cursor || m.range.end > text.len() {
            continue;
        }
        append_gap(&text[cursor..m.range.start], &mut pieces);
        pieces.push(Piece::new(
            &text[m.range.clone()],
            Role::Term(segment_kind(m.kind)),
        ));
        cursor = m.range.end;
    }
    // 最后一处匹配之后的文字也是空隙。
    append_gap(&text[cursor..], &mut pieces);
    // 第 4 条要看前面是不是舰船，所以在全部小段切好之后再做。
    attach_leading_digits(&mut pieces);
    // 第 5 条的前提：至少认出一个星系、舰船或舰船分组。只有星域或情报用语时不推断人名，
    // 否则「Delve clear」之外的普通英文句子里大写开头的词都会被当成人名。
    let has_terms = pieces
        .iter()
        .any(|p| matches!(p.role, Role::Term(kind) if kind.is_system_or_ship()));
    // 人数的写法按出现顺序记下来，summarize 按同样的顺序取用（段里只留数值，不留写法）。
    let forms: Vec<CountForm> = pieces
        .iter()
        .filter_map(|p| match p.role {
            Role::Count(_, form) => Some(form),
            _ => None,
        })
        .collect();
    summarize(build_segments(&pieces, has_terms), &forms)
}

/// 用星图数据的匹配器解析一条消息。
pub fn parse_with(text: &str, data: &EveStaticData) -> IntelReport {
    parse(text, &data.matcher.matches(text))
}

/// 去掉认出的术语、人数与推断的人名后，剩下的文字（翻译用它判断「只有术语」的消息）。
///
/// 做法：按顺序取全部 Plain 段，各段去掉首尾空白，空段丢掉，其余用一个空格连起来。
/// 人名的总词数超过 [`MAX_PILOT_WORDS`] 时，Pilot 段也按原来的位置算进去：这时消息多半是一句话，应交给模型翻译。
/// 只看 segments，不看 pilots，手工构造的结果不会两处不一致。
pub fn remainder(report: &IntelReport) -> String {
    let pilot_words: usize = report
        .segments
        .iter()
        .filter(|s| s.kind == IntelSegmentKind::Pilot)
        .map(|s| s.text.split_whitespace().count())
        .sum();
    // 只有一个人名、或几个短人名时，人名本身不用翻译；词数多了才可能是被误认成人名的一句话。
    let includes_pilots = pilot_words > MAX_PILOT_WORDS;
    report
        .segments
        .iter()
        .filter(|s| match s.kind {
            IntelSegmentKind::Plain => true,
            IntelSegmentKind::Pilot => includes_pilots,
            _ => false,
        })
        .map(|s| s.text.trim())
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// 术语种类到段种类的对应。
fn segment_kind(kind: TermKind) -> IntelSegmentKind {
    match kind {
        TermKind::System(id) => IntelSegmentKind::System(id),
        TermKind::Region(id) => IntelSegmentKind::Region(id),
        TermKind::Ship(id) => IntelSegmentKind::Ship(id),
        TermKind::ShipGroup(id) => IntelSegmentKind::ShipGroup(id),
        TermKind::IntelWord(word) => IntelSegmentKind::Word(word),
    }
}

/// 把一段空隙按空白切成词，每个词再分出人数、人名候选与两端的标点。
fn append_gap(gap: &str, pieces: &mut Vec<Piece>) {
    let mut rest = gap;
    while let Some(first) = rest.chars().next() {
        let is_space = first.is_whitespace();
        // 同一类（空白或非空白）的一串连续字符。
        let end = rest
            .char_indices()
            .find(|&(_, c)| c.is_whitespace() != is_space)
            .map_or(rest.len(), |(i, _)| i);
        let (chunk, tail) = rest.split_at(end);
        // 空白原样保留成单独的小段：第 6 条要区分「正好一个空格」与其他空白，拼回原文时也不能丢。
        if is_space {
            pieces.push(Piece::new(chunk, Role::Space));
        } else {
            append_token(chunk, pieces);
        }
        rest = tail;
    }
}

/// 一个不含空白的词：先认人数，再认人名候选（两端的标点单独成为普通文字），其余是普通文字。
fn append_token(token: &str, pieces: &mut Vec<Piece>) {
    // 人数后常跟标点（`3, Naga`、`+5.`）：先去掉末尾标点再认，标点另成一段普通文字。
    let core = token.trim_end_matches([',', '，', '.', ';', ':']);
    let trailing = &token[core.len()..];
    if let Some((value, form)) = count_value(core) {
        pieces.push(Piece::new(core, Role::Count(value, form)));
        if !trailing.is_empty() {
            pieces.push(Piece::new(trailing, Role::Plain));
        }
        return;
    }
    // 人名候选：去掉两端不是字母或数字的字符。候选的条件要看整条消息有没有术语，在 build_segments 里判断。
    let name = token.trim_matches(|c: char| !c.is_alphanumeric());
    if name.is_empty() || !is_pilot_candidate(name) {
        pieces.push(Piece::new(token, Role::Plain));
        return;
    }
    // 去掉的前缀与后缀（如 `(Kael`、`Doran),` 两端的括号与逗号）仍要留在段里，各段拼起来才与原文相同。
    let start = token.len() - token.trim_start_matches(|c: char| !c.is_alphanumeric()).len();
    let end = start + name.len();
    if start > 0 {
        pieces.push(Piece::new(&token[..start], Role::Plain));
    }
    pieces.push(Piece::new(name, Role::Candidate));
    if end < token.len() {
        pieces.push(Piece::new(&token[end..], Role::Plain));
    }
}

/// 人数的 13 种写法：`+3`、`＋3`、`x3`、`×3`、`3`、`3x`、`3×`、`3+`、`3人`、`3个`、`3只`、`3艘`、`3名`。
/// 数字 1～3 位，数值 1～500；不符合时返回 `None`。`x` 不区分大小写。
pub(super) fn count_value(core: &str) -> Option<(i64, CountForm)> {
    // 先按前缀、再按后缀判断写法；`x3`、`+3` 是「另有 3 个」的口语写法，只归给前面的舰船。
    // 没有前缀后缀的纯数字与 `3x` 才可能是「3 艘某船」的前置数量。
    let mut form = CountForm::Other;
    let body = if let Some(rest) = core.strip_prefix(['+', '＋', 'x', 'X', '×']) {
        rest
    } else if let Some(rest) = core.strip_suffix(['x', 'X', '×']) {
        form = CountForm::Leading;
        rest
    } else if let Some(rest) = core.strip_suffix(['+', '人', '个', '只', '艘', '名']) {
        rest
    } else {
        form = CountForm::Leading;
        core
    };
    // 只认 ASCII 数字：全角数字与其他文字的数字在频道里极少用作人数，认了反而容易把编号误认成人数。
    // 4 位以上多半是时间（`1530`）或星系名的一部分，所以限定 1～3 位。
    if !(1..=3).contains(&body.len()) || !body.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let value: i64 = body.parse().ok()?;
    (1..=500).contains(&value).then_some((value, form))
}

/// 人名候选的条件（6.4 节第 5 条）：不为空；不含汉字、假名、谚文；小写不是常见情报词；至少含一个字母；
/// 含大写字母或数字。「至少含一个字母」也排除了全是数字的词。
pub fn is_pilot_candidate(word: &str) -> bool {
    if word.is_empty()
        || word.chars().any(is_cjk)
        || is_non_pilot_word(&word.to_lowercase())
        || !word.chars().any(char::is_alphabetic)
    {
        return false;
    }
    // 全小写的词多半是普通英文（`gate`、`camp`）；角色名常有大写字母或数字（`Kael Doran`、`xX1Xx`）。
    word.chars().any(|c| c.is_uppercase() || c.is_numeric())
}

/// 6.4 节第 4 条：紧跟在舰船或舰船分组之后（中间只有空白）的普通词，以 1～3 位数字开头、数字后直接是汉字时，
/// 数字成为人数，其余是普通文字。例：`剑齿虎级 1门口有泡泡` 里的 `1`。
fn attach_leading_digits(pieces: &mut Vec<Piece>) {
    let mut index = 0;
    // 前一个非空白小段是不是舰船或舰船分组；遇到别的小段就清掉，所以只看紧跟的那一个词。
    let mut after_ship = false;
    while index < pieces.len() {
        match pieces[index].role {
            Role::Term(kind) => after_ship = kind.is_ship(),
            Role::Space => {}
            Role::Plain if after_ship => {
                after_ship = false;
                let text = pieces[index].text.clone();
                let digits = text.len() - text.trim_start_matches(|c: char| c.is_ascii_digit()).len();
                let next = text[digits..].chars().next();
                let value: Option<i64> = text[..digits].parse().ok();
                if let (true, Some(next), Some(value)) = ((1..=3).contains(&digits), next, value)
                    && is_cjk(next)
                    && (1..=500).contains(&value)
                {
                    pieces[index] = Piece::new(&text[..digits], Role::Count(value, CountForm::Other));
                    pieces.insert(index + 1, Piece::new(&text[digits..], Role::Plain));
                    // 跳过刚插入的普通文字，它不会再是人数。
                    index += 1;
                }
            }
            _ => after_ship = false,
        }
        index += 1;
    }
}

/// 按第 5～7 条组段：没有术语时候选词都是普通文字；相邻候选只隔一个空格时并成一串，每 3 个词一个人名；
/// 其余并成 Plain。
fn build_segments(pieces: &[Piece], infers_pilots: bool) -> Vec<IntelSegment> {
    let mut segments: Vec<IntelSegment> = Vec::new();
    let mut index = 0;
    while index < pieces.len() {
        let piece = &pieces[index];
        match piece.role {
            Role::Term(kind) => segments.push(IntelSegment::new(&piece.text, kind)),
            Role::Count(value, _) => {
                segments.push(IntelSegment::new(&piece.text, IntelSegmentKind::Count(value)))
            }
            Role::Space | Role::Plain => append_plain(&mut segments, &piece.text),
            Role::Candidate if !infers_pilots => append_plain(&mut segments, &piece.text),
            Role::Candidate => {
                // 收一串：候选、正好一个空格、候选……
                let mut words = vec![piece.text.as_str()];
                let mut next = index + 1;
                while next + 1 < pieces.len()
                    && pieces[next].role == Role::Space
                    && pieces[next].text == " "
                    && pieces[next + 1].role == Role::Candidate
                {
                    words.push(&pieces[next + 1].text);
                    next += 2;
                }
                // 角色名至多 3 个词：超过时多半是几个人名连写（`Kael Doran Mira Voss`），按 3 个一组切开。
                // 这只是估计，切错时人名个数仍大致正确，敌对数量取最大值也不会因此偏大太多。
                for (chunk_index, chunk) in words.chunks(MAX_PILOT_WORDS).enumerate() {
                    if chunk_index > 0 {
                        append_plain(&mut segments, " ");
                    }
                    segments.push(IntelSegment::new(&chunk.join(" "), IntelSegmentKind::Pilot));
                }
                index = next;
                continue;
            }
        }
        index += 1;
    }
    segments
}

/// 追加一段普通文字；前一段也是 Plain 时并进去。
fn append_plain(segments: &mut Vec<IntelSegment>, text: &str) {
    if text.is_empty() {
        return;
    }
    match segments.last_mut() {
        Some(last) if last.kind == IntelSegmentKind::Plain => last.text.push_str(text),
        _ => segments.push(IntelSegment::new(text, IntelSegmentKind::Plain)),
    }
}
