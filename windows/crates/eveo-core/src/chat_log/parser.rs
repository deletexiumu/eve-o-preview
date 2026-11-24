// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的文件头与消息行的解析，对应 macOS 的 ChatLogParser.swift（设计文档 5.2 节）。
// - 文件是带 BOM 的 UTF-16 小端，由调用方用分行器（combat_log::framer）切成行后交给这里。
// - 文件头：两条全是 `-` 的分隔线之间是 Channel ID、Channel Name、Listener、Session started 4 个字段。
//   标签在 8 种语言的客户端里都是英文；标签一个都不认识而正好 4 行时按位置取。
// - 消息行是 U+FEFF 加「[ yyyy.MM.dd HH:mm:ss ] 说话人 > 正文」，时间是 UTC。
// - 正文里连续的空格保留：它是预警条目之间的分隔。
// 不用正则表达式，只做前缀与子串比较。

//! 聊天日志的文件头与消息行的解析。

use super::{ChatChannelKind, ChatLine, ChatLogHeader};
use crate::combat_log::header::{is_separator, trim};
use crate::combat_log::parser::utc_seconds;

/// 至多看文件开头的这么多行。读满仍没有第二条分隔线时，视为字段都没有的完整文件头。
pub const MAX_HEADER_LINES: usize = 16;

/// EVE 系统消息的说话人：英文客户端与中文客户端各一个，其余语言待补。
pub const SYSTEM_SPEAKERS: [&str; 2] = ["EVE System", "EVE系统"];

/// 时间部分的字节数：`yyyy.MM.dd HH:mm:ss`。
const TIMESTAMP_LENGTH: usize = 19;

/// 解析文件开头的各行（不含换行符）。
///
/// 1. 每行先去掉 U+FEFF 与首尾空白，至多看 [`MAX_HEADER_LINES`] 行。
/// 2. 第一条全是 `-` 的行是文件头的开始，第二条是结束；读到第二条时 `is_complete` 为真。
/// 3. 两条分隔线之间的非空行按第一个半角或全角冒号分成标签与值，标签不区分大小写。
/// 4. 标签一个都不认识、而非空行正好 4 行时，按顺序取第 1、2、3 行的值（标签被翻译的客户端）。
/// 5. 读满还没有第二条分隔线时视为完整、各字段为 `None`；行数不够时为不完整。
pub fn parse_header<S: AsRef<str>>(lines: &[S]) -> ChatLogHeader {
    let mut inside: Option<Vec<&str>> = None;
    for raw in lines.iter().take(MAX_HEADER_LINES) {
        let line = trim(raw.as_ref());
        if is_separator(line) {
            if let Some(between) = inside {
                return header_from(&between);
            }
            inside = Some(Vec::new());
            continue;
        }
        if let Some(between) = inside.as_mut()
            && !line.is_empty()
        {
            between.push(line);
        }
    }
    // 没读到第二条分隔线：行数已满说明文件头不是预期的形式，否则是文件还没写完。
    ChatLogHeader {
        channel_id: None,
        channel_name: None,
        listener: None,
        is_complete: lines.len() >= MAX_HEADER_LINES,
    }
}

/// 从两条分隔线之间的非空行取 3 个字段。
fn header_from(lines: &[&str]) -> ChatLogHeader {
    let (mut id, mut name, mut listener) = (None, None, None);
    let mut recognized = false;
    for line in lines {
        let Some((label, value)) = split_field(line) else {
            continue;
        };
        match label.to_lowercase().as_str() {
            "channel id" => id = value,
            "channel name" => name = value,
            "listener" => listener = value,
            _ => continue,
        }
        recognized = true;
    }
    if !recognized && lines.len() == 4 {
        // 标签被翻译的客户端：按位置取第 1、2、3 行的值。
        id = split_field(lines[0]).and_then(|f| f.1);
        name = split_field(lines[1]).and_then(|f| f.1);
        listener = split_field(lines[2]).and_then(|f| f.1);
    }
    ChatLogHeader {
        channel_id: id,
        channel_name: name,
        listener,
        is_complete: true,
    }
}

/// 按第一个半角或全角冒号把一行分成标签与值，两边去掉首尾空白；值为空时为 `None`。没有冒号时返回 `None`。
fn split_field(line: &str) -> Option<(&str, Option<String>)> {
    let colon = line.find([':', '：'])?;
    let colon_len = line[colon..].chars().next().map_or(1, char::len_utf8);
    let label = line[..colon].trim();
    let value = trim(&line[colon + colon_len..]);
    Some((label, (!value.is_empty()).then(|| value.to_owned())))
}

/// 解析一行消息。不是「[ 时间 ] 说话人 > 正文」形式的行返回 `None`。
///
/// 1. 去掉行首的 U+FEFF（可能有多个）与行尾的回车、换行。
/// 2. 行以 `[ ` 开头，时间是 19 个字节，后面是 ` ] `；时间按 UTC 换算，换算不了时返回 `None`。
/// 3. 剩下的部分按第一个 ` > ` 分成说话人与正文；没有 ` > ` 或说话人为空时返回 `None`。
/// 4. 正文经 [`plain_text`] 清理；`is_system` 是「说话人在 [`SYSTEM_SPEAKERS`] 里」。
pub fn parse_line(line: &str) -> Option<ChatLine> {
    let text = line.trim_start_matches('\u{FEFF}').trim_end_matches(['\r', '\n']);
    let bytes = text.as_bytes();
    let prefix_length = 2 + TIMESTAMP_LENGTH + 3;
    if bytes.len() < prefix_length
        || !bytes.starts_with(b"[ ")
        || &bytes[2 + TIMESTAMP_LENGTH..prefix_length] != b" ] "
    {
        return None;
    }
    let time = utc_seconds(&bytes[2..2 + TIMESTAMP_LENGTH])?;
    // 前缀全是 ASCII，切在这里一定落在字符边界上。
    let rest = &text[prefix_length..];
    let arrow = rest.find(" > ")?;
    let speaker = rest[..arrow].trim();
    if speaker.is_empty() {
        return None;
    }
    Some(ChatLine {
        time,
        speaker: speaker.to_owned(),
        text: plain_text(&rest[arrow + 3..]),
        is_system: SYSTEM_SPEAKERS.contains(&speaker),
    })
}

/// 按 Channel ID 判断频道种类，比较不区分大小写：`local`、`corp`、`alliance` 各对应同名的种类；
/// 以 `fleet_`、`player_`、`private_` 开头的分别是舰队、玩家频道、私聊；其余与 `None` 是其他。
pub fn channel_kind(id: Option<&str>) -> ChatChannelKind {
    let Some(id) = id.map(|id| id.trim().to_lowercase()) else {
        return ChatChannelKind::Other;
    };
    match id.as_str() {
        "local" => ChatChannelKind::Local,
        "corp" => ChatChannelKind::Corp,
        "alliance" => ChatChannelKind::Alliance,
        _ if id.starts_with("fleet_") => ChatChannelKind::Fleet,
        _ if id.starts_with("player_") => ChatChannelKind::Player,
        _ if id.starts_with("private_") => ChatChannelKind::PrivateChat,
        _ => ChatChannelKind::Other,
    }
}

/// 支持的 5 种实体与解码后的字符。
const ENTITIES: [(&str, char); 5] = [
    ("&lt;", '<'),
    ("&gt;", '>'),
    ("&amp;", '&'),
    ("&quot;", '"'),
    ("&#39;", '\''),
];

/// 清理正文：`<br>`（含 `<br/>`、`<br />`，不区分大小写）换成换行；删掉其余每一对 `<` 与 `>` 之间的内容，
/// 找不到 `>` 的 `<` 保留；解码 5 种实体（一次扫描，不重复解码）；行内连续的空格与制表符保留；去掉首尾空白。
pub fn plain_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    // 一旦某个 `<` 之后再也没有 `>`，后面的 `<` 也不会有，记下来免得重复查找。
    let mut no_more_close = false;
    let mut i = 0;
    while i < raw.len() {
        let rest = &raw[i..];
        if rest.starts_with('<') && !no_more_close {
            if let Some(close) = rest.find('>') {
                if is_line_break_tag(&rest[1..close]) {
                    out.push('\n');
                }
                i += close + 1;
                continue;
            }
            no_more_close = true;
        }
        if let Some((name, value)) = ENTITIES.iter().find(|(name, _)| rest.starts_with(name)) {
            out.push(*value);
            i += name.len();
            continue;
        }
        let c = rest.chars().next().unwrap_or_default();
        out.push(c);
        i += c.len_utf8();
    }
    out.trim().to_owned()
}

/// 标记的内容（`<` 与 `>` 之间）是不是换行标记 `br`、`br/`、`br /`。
fn is_line_break_tag(content: &str) -> bool {
    let name = content.trim().to_lowercase();
    name.strip_suffix('/').unwrap_or(&name).trim() == "br"
}
