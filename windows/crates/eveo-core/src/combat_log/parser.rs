// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志单行的解析与归类（反馈文档 7.6 节），与 macOS 的 CombatLogParser.swift 相同。
// 行的形式是「[ yyyy.MM.dd HH:mm:ss ] (类别) 正文」。只有 combat 类别再细分：
// 1. 正文开头（跳过空白与 <…> 标记后）是数字时，按最后一个 <color=…> 的值判断方向：
//    ffcc0000 为受到伤害，ff00ffff 为造成伤害，8 种语言相同。
// 2. 有数字但没有颜色标记时，改用方向词（catalog）；方向词判断不了时，转按第 3 条判断。
//    武器名以数字开头的未命中行（如「125mm … misses you completely」）因此仍能识别为未命中。
// 3. 没有开头的数字时，按未命中的句尾与通用短语判断；判断不了的归为 OtherCombat。
// 判断不了的行一律不触发提醒：宁可漏报，不误报。解析不用正则表达式，只做前缀、后缀与子串比较。

//! 游戏日志单行的解析。

use super::catalog;
use super::{CombatLineKind, CombatLogLine};

/// 时间部分的字节数：`yyyy.MM.dd HH:mm:ss`。
const TIMESTAMP_LENGTH: usize = 19;

/// 伤害数字之间可以跳过的分隔符：千分位逗号、不换行空格、窄不换行空格。
const DIGIT_SEPARATORS: [char; 3] = [',', '\u{00A0}', '\u{202F}'];

/// 解析一行。不是「[ 时间 ] (类别) 正文」形式的行返回 `None`。
pub fn parse(line: &str) -> Option<CombatLogLine> {
    let parts = split(line)?;
    let kind = if parts.category == "combat" {
        classify_combat(&parts.body)
    } else {
        CombatLineKind::Other
    };
    Some(CombatLogLine {
        category: parts.category,
        kind,
    })
}

/// 取日志行里的时间，换算成 1970 年以来的秒数。日志时间是 UTC 的整秒。
///
/// 用于 [`super::replay`] 过滤晚跟踪文件的积压行。正常跟踪新增内容时，提醒不看日志时间。
/// 不是合法日志行或日期不合法时返回 `None`。
pub fn log_time(line: &str) -> Option<f64> {
    utc_seconds(&split(line)?.timestamp)
}

/// 19 字节的 `yyyy.MM.dd HH:mm:ss` 换算成 UTC 秒数；形式或数值不合法时返回 `None`。聊天日志的解析也用它。
pub(crate) fn utc_seconds(t: &[u8]) -> Option<f64> {
    if !is_timestamp(t) {
        return None;
    }
    // 各字段在时间串里的位置，形式已核对过，这里只取数值。
    let number = |start: usize, length: usize| {
        t[start..start + length]
            .iter()
            .fold(0i64, |acc, &b| acc * 10 + i64::from(b - b'0'))
    };
    let (year, month, day) = (number(0, 4), number(5, 2), number(8, 2));
    let (hour, minute, second) = (number(11, 2), number(14, 2), number(17, 2));
    let valid =
        (1..=12).contains(&month) && (1..=31).contains(&day) && hour < 24 && minute < 60 && second < 61;
    if !valid {
        return None;
    }
    let days = days_from_civil(year, month, day);
    Some((days * 86_400 + hour * 3_600 + minute * 60 + second) as f64)
}

/// 去掉标记，得到可见文字：删掉每一对 `<` 与 `>` 之间的内容（找不到 `>` 的 `<` 保留），
/// 连续的空白（含 U+00A0）合成一个空格，去掉首尾空白。不解码 `&amp;` 一类的实体。
pub fn plain_text(markup: &str) -> String {
    let chars: Vec<char> = markup.chars().collect();
    let mut out = String::with_capacity(markup.len());
    let mut pending_space = false;
    // 一旦某个 `<` 之后再也没有 `>`，后面的 `<` 也不会有，记下来免得重复查找。
    let mut no_more_close = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '<' && !no_more_close {
            if let Some(offset) = chars[i + 1..].iter().position(|&x| x == '>') {
                i += offset + 2;
                continue;
            }
            no_more_close = true;
        }
        if c.is_whitespace() {
            pending_space = !out.is_empty();
            i += 1;
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(c);
        i += 1;
    }
    out
}

/// 一行拆出的三部分。游戏日志的位置线索（聊天日志模块）也用它。
pub(crate) struct LineParts {
    /// 时间部分的 19 个 ASCII 字节。
    pub(crate) timestamp: Vec<u8>,
    /// 类别，小写。
    pub(crate) category: String,
    /// 正文（可能为空）。
    pub(crate) body: String,
}

/// 核对行的形式并拆成时间、类别与正文。行首的 U+FEFF 与行尾的回车、换行先去掉。
pub(crate) fn split(line: &str) -> Option<LineParts> {
    let mut bytes = line.as_bytes();
    // 行首可能有一个或多个 BOM（UTF-8 编码是 EF BB BF），上游记录聊天日志每行都带。
    while let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        bytes = rest;
    }
    while let Some((&last, rest)) = bytes.split_last() {
        if last != b'\r' && last != b'\n' {
            break;
        }
        bytes = rest;
    }
    // "[ " + 时间 + " ] (" 之后至少还要有类别的一个字节。
    let prefix_length = 2 + TIMESTAMP_LENGTH + 4;
    if bytes.len() < prefix_length + 1 || !bytes.starts_with(b"[ ") {
        return None;
    }
    let timestamp = &bytes[2..2 + TIMESTAMP_LENGTH];
    if !is_timestamp(timestamp) {
        return None;
    }
    let after_time = 2 + TIMESTAMP_LENGTH;
    if &bytes[after_time..after_time + 4] != b" ] (" {
        return None;
    }
    // 类别到第一个 `)` 为止；类别不长，限定在 32 字节内查找，避免把正文里的括号当成结尾。
    let category_start = after_time + 4;
    let search_end = bytes.len().min(category_start + 32);
    let close = category_start
        + bytes[category_start..search_end]
            .iter()
            .position(|&b| b == b')')?;
    if close == category_start {
        return None;
    }
    let category = String::from_utf8_lossy(&bytes[category_start..close]).to_lowercase();
    // `)` 之后应是一个空格再接正文；正文为空时行可能直接在 `)` 处结束。
    let body_start = if close + 1 == bytes.len() {
        bytes.len()
    } else if bytes[close + 1] == b' ' {
        close + 2
    } else {
        return None;
    };
    Some(LineParts {
        timestamp: timestamp.to_vec(),
        category,
        body: String::from_utf8_lossy(&bytes[body_start..]).into_owned(),
    })
}

/// 时间部分是否为 `dddd.dd.dd dd:dd:dd` 的形式。只核对形式，不换算。
fn is_timestamp(t: &[u8]) -> bool {
    t.len() == TIMESTAMP_LENGTH
        && t.iter().enumerate().all(|(index, &byte)| match index {
            4 | 7 => byte == b'.',
            10 => byte == b' ',
            13 | 16 => byte == b':',
            _ => byte.is_ascii_digit(),
        })
}

/// 公历日期到 1970-01-01 的天数（Howard Hinnant 的 days_from_civil 算法），不依赖时区。
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 正文开头的伤害数字与它之前最后一个颜色标记。
struct LeadingNumber {
    /// 数字的值；超出 i64 范围时取 i64::MAX。
    amount: i64,
    /// 最后一个 `<color=…>` 的值，小写，去掉 `0x` 或 `#` 前缀；没有颜色标记时为 `None`。
    color: Option<String>,
}

/// 归类 combat 类别的正文（7.6 节第 4～7 步）。
fn classify_combat(body: &str) -> CombatLineKind {
    let Some(lead) = leading_number(body) else {
        return miss_kind(&plain_text(body));
    };
    if let Some(color) = lead.color {
        return match color.as_str() {
            catalog::INCOMING_DAMAGE_COLOR => CombatLineKind::IncomingDamage(lead.amount),
            catalog::OUTGOING_DAMAGE_COLOR => CombatLineKind::OutgoingDamage(lead.amount),
            // 有颜色但不是两种伤害色：是远程维修、能量传输一类的行（句中也可能有「来自」）。
            // 方向词只在颜色缺失时用，这里不猜。
            _ => CombatLineKind::OtherCombat,
        };
    }
    let text = plain_text(body);
    // 没有颜色也没有方向词的行，可能是武器名以数字开头的未命中行，转按未命中的句尾判断。
    direction_by_words(&text, lead.amount).unwrap_or_else(|| miss_kind(&text))
}

/// 取正文开头的数字：跳过空白与 `<…>` 标记直到第一个可见字符，记下跳过的最后一个颜色值。
/// 可见文字不以 ASCII 数字开头时返回 `None`。
fn leading_number(body: &str) -> Option<LeadingNumber> {
    let chars: Vec<char> = body.chars().collect();
    let mut color = None;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        // 找不到 `>` 的 `<` 是普通字符，到这里就是第一个可见字符。
        if c == '<'
            && let Some(offset) = chars[i + 1..].iter().position(|&x| x == '>')
        {
            let tag: String = chars[i + 1..i + 1 + offset].iter().collect();
            if let Some(value) = color_value(&tag) {
                color = Some(value);
            }
            i += offset + 2;
            continue;
        }
        break;
    }
    if !chars.get(i).is_some_and(char::is_ascii_digit) {
        return None;
    }
    let mut amount: i64 = 0;
    while i < chars.len() {
        let c = chars[i];
        if let Some(digit) = c.to_digit(10).filter(|_| c.is_ascii_digit()) {
            amount = amount.saturating_mul(10).saturating_add(i64::from(digit));
            i += 1;
        } else if DIGIT_SEPARATORS.contains(&c) && chars.get(i + 1).is_some_and(char::is_ascii_digit) {
            // 单个分隔符夹在两个数字之间时跳过，如 `1,265`；其他情况数字到此结束。
            i += 1;
        } else {
            break;
        }
    }
    Some(LeadingNumber { amount, color })
}

/// 标记是 `color=…` 时返回颜色值（小写，去掉引号与 `0x`、`#` 前缀），否则返回 `None`。
fn color_value(tag: &str) -> Option<String> {
    let text = tag.trim().to_lowercase();
    let value = text.strip_prefix("color=")?.trim_matches(['"', '\'', ' ']);
    let value = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix('#'))
        .unwrap_or(value);
    Some(value.to_owned())
}

/// 没有颜色标记的伤害行：去掉开头的数字后按方向词判断（7.6 节第 6 步）。
/// 方向词都不匹配时返回 `None`，由调用方继续按未命中判断。
fn direction_by_words(text: &str, amount: i64) -> Option<CombatLineKind> {
    let lower = text.to_lowercase();
    // plain_text 已把空白合成普通空格；数字里可能还有逗号与不换行空格。
    let rest =
        lower.trim_start_matches(|c: char| c.is_ascii_digit() || DIGIT_SEPARATORS.contains(&c) || c == ' ');
    // 方向词后面要跟一个空格，才不会把以它开头的词当成方向词。
    let starts_with_word = |words: &[&str]| {
        words.iter().any(|word| {
            rest.strip_prefix(word.to_lowercase().as_str())
                .is_some_and(|r| r.starts_with(' '))
        })
    };
    let contains_any = |phrases: &[&str]| phrases.iter().any(|p| rest.contains(p.to_lowercase().as_str()));
    if contains_any(&catalog::INCOMING_PHRASES) {
        Some(CombatLineKind::IncomingDamage(amount))
    } else if contains_any(&catalog::OUTGOING_PHRASES) {
        Some(CombatLineKind::OutgoingDamage(amount))
    } else if starts_with_word(&catalog::INCOMING_WORDS) {
        Some(CombatLineKind::IncomingDamage(amount))
    } else if starts_with_word(&catalog::OUTGOING_WORDS) {
        Some(CombatLineKind::OutgoingDamage(amount))
    } else {
        None
    }
}

/// 没有开头数字的行：按未命中的句尾与通用短语判断（7.6 节第 7 步）。
fn miss_kind(text: &str) -> CombatLineKind {
    let lower = text.to_lowercase();
    let mut t = lower.trim_end();
    // 去掉一个句号（法文、西班牙文的模板以句号结尾），再去掉句号前的空白。
    if let Some(stripped) = t.strip_suffix('.').or_else(|| t.strip_suffix('。')) {
        t = stripped.trim_end();
    }
    let ends_incoming = catalog::INCOMING_MISS_MARKERS
        .iter()
        .any(|m| t.ends_with(m.to_lowercase().as_str()));
    let excluded = catalog::INCOMING_MISS_EXCLUSIONS
        .iter()
        .any(|m| t.contains(m.to_lowercase().as_str()));
    if ends_incoming && !excluded {
        CombatLineKind::IncomingMiss
    } else if catalog::MISS_MARKERS
        .iter()
        .any(|m| t.contains(m.to_lowercase().as_str()))
    {
        CombatLineKind::OutgoingMiss
    } else {
        CombatLineKind::OtherCombat
    }
}
