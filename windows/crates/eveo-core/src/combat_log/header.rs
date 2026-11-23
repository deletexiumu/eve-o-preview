// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志文件头的解析（反馈文档 7.5 节），与 macOS 的 CombatLogHeaderParser.swift 相同。
// 文件头是 5 行：分隔线、标题、收听者、进程开始时间、分隔线。
// 登录界面阶段建的文件没有收听者一行，这类文件不跟踪。
// 文件与角色只按收听者对应；文件名里的数字后缀不用来识别角色。

//! 游戏日志文件头的解析。

use super::catalog::LISTENER_LABELS;

/// 至多看文件开头的这么多行。读满仍没有第二条分隔线时，视为没有收听者的完整文件头。
pub const MAX_HEADER_LINES: usize = 12;

/// 文件头的解析结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CombatLogHeader {
    /// 收听者（角色名）；`None` 表示文件头里没有收听者，或文件头还不完整。
    pub listener: Option<String>,
    /// 是否已读完文件头。`false` 表示还没读到第二条分隔线（文件刚建出来）。
    pub is_complete: bool,
}

/// 解析文件开头的各行（不含换行符）。规则：
/// 1. 第一条全是 `-` 的行是文件头的开始，第二条是结束。
/// 2. 两条分隔线之间的行以某个收听者标签开头、后接半角或全角冒号时，冒号后的部分是收听者。
/// 3. 没有匹配的标签，但两条分隔线之间正好有 3 行时，取第 2 行冒号后的部分（应对标签表以外的语言）。
/// 4. 读了 [`MAX_HEADER_LINES`] 行还没有第二条分隔线时，`is_complete` 为真，`listener` 为 `None`。
pub fn parse<S: AsRef<str>>(lines: &[S]) -> CombatLogHeader {
    let mut inside: Option<Vec<&str>> = None;
    for raw in lines.iter().take(MAX_HEADER_LINES) {
        let line = trim(raw.as_ref());
        if is_separator(line) {
            if let Some(between) = &inside {
                return CombatLogHeader {
                    listener: listener(between),
                    is_complete: true,
                };
            }
            inside = Some(Vec::new());
            continue;
        }
        if let Some(between) = &mut inside {
            between.push(line);
        }
    }
    // 没读到第二条分隔线：行数已满说明文件头不是预期的形式，否则是文件还没写完。
    CombatLogHeader {
        listener: None,
        is_complete: lines.len() >= MAX_HEADER_LINES,
    }
}

/// 去掉首尾空白，含行首可能残留的 BOM（U+FEFF）。
pub(crate) fn trim(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_whitespace() || c == '\u{FEFF}')
}

/// 是否为分隔线：非空且全是 `-`。
pub(crate) fn is_separator(line: &str) -> bool {
    !line.is_empty() && line.chars().all(|c| c == '-')
}

/// 是否为半角或全角冒号。
fn is_colon(c: char) -> bool {
    c == ':' || c == '：'
}

/// 从两条分隔线之间的行里取收听者。
fn listener(lines: &[&str]) -> Option<String> {
    for line in lines {
        for label in LISTENER_LABELS {
            let Some(rest) = line.strip_prefix(label) else {
                continue;
            };
            // 标签后接冒号；法文排版习惯在冒号前加空格（含不换行空格），这里允许冒号前有这两种空白。
            let rest = rest.trim_start_matches([' ', '\u{00A0}']);
            let mut chars = rest.chars();
            if chars.next().is_some_and(is_colon) {
                return non_empty(chars.as_str());
            }
        }
    }
    // 标签表以外的语言：文件头正好 3 行（标题、收听者、开始时间）时，第 2 行就是收听者。
    if lines.len() != 3 {
        return None;
    }
    let second = lines[1];
    let colon = second.find(is_colon)?;
    let after = &second[colon..];
    // 跳过冒号本身（半角 1 字节，全角 3 字节）。
    let skip = after.chars().next().map_or(0, char::len_utf8);
    non_empty(&after[skip..])
}

/// 去掉首尾空白，空串返回 `None`。
fn non_empty(text: &str) -> Option<String> {
    let value = trim(text);
    (!value.is_empty()).then(|| value.to_owned())
}
