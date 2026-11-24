// SPDX-License-Identifier: GPL-3.0-or-later
//
// 位置线索的句式，对应 macOS 的 LocationLineParser.swift（设计文档 5.6 节）：从一行日志里取出星系名的原文，不查星图数据。
// - Local 聊天日志的系统消息：取最后一个半角或全角冒号后面的部分。英文是「Channel changed to Local : <星系>」，
//   中文记为「频道更换为本地：<星系>*」。规则只看冒号，不依赖措辞。
// - 游戏日志的 (None) 行：按下表的句式取目的星系。
//   | 中文跳跃 | 从<甲>跳到<乙>                                 | 「跳到」之后到行尾               |
//   | 中文离站 | 正在从 <空间站> 离站进入 <星系> 恒星系。        | 「离站进入」与「恒星系」之间     |
//   | 英文跳跃 | Jumping from <甲> to <乙>                      | 最后一个 ` to ` 之后到行尾       |
//   | 英文离站 | Undocking from <空间站> to <星系> solar system. | 最后一个 ` to ` 与 ` solar system` 之间 |
//   句式不认识时返回 None，由位置记录的规则按正文里星系的个数兜底。
// 取出的名称都去掉首尾空白、末尾的句号与 `*`（中文客户端在译名后加 `*`）。

//! 位置线索的句式：从 Local 的系统消息与游戏日志的 (None) 行里取星系名。

use crate::combat_log::parser::{plain_text, split, utc_seconds};

/// Local 的系统消息里的星系名：最后一个冒号后面的部分，去掉 `*` 与句号。没有冒号或名称为空时返回 `None`。
pub fn system_name_from_local(text: &str) -> Option<String> {
    let colon = text.rfind([':', '：'])?;
    let width = text[colon..].chars().next().map_or(1, char::len_utf8);
    cleaned(&text[colon + width..])
}

/// 游戏日志 (None) 行里按已知句式取出的目的星系名；句式不认识或名称为空时返回 `None`。
/// `text` 是 [`game_note`] 取出的正文。英文句式的比较不区分大小写。
pub fn system_name_from_game_note(text: &str) -> Option<String> {
    let body = text.trim();
    // 中文离站：「离站进入」与「恒星系」之间。先判断离站，因为离站句里没有「跳到」。
    if let Some(start) = body.find("离站进入") {
        let tail = &body[start + "离站进入".len()..];
        let end = tail.find("恒星系").unwrap_or(tail.len());
        return cleaned(&tail[..end]);
    }
    // 中文跳跃：最后一个「跳到」之后到行尾。
    if let Some(jump) = body.rfind("跳到") {
        return cleaned(&body[jump + "跳到".len()..]);
    }
    // 英文句式不区分大小写：ASCII 小写不改变字节位置，可以用小写串里的位置切原文。
    let lower = body.to_ascii_lowercase();
    if lower.starts_with("undocking from ") {
        let end = lower.rfind(" solar system")?;
        let to = lower[..end].rfind(" to ")?;
        return cleaned(&body[to + 4..end]);
    }
    if lower.starts_with("jumping from ") {
        let to = lower.rfind(" to ")?;
        return cleaned(&body[to + 4..]);
    }
    None
}

/// 取游戏日志一行的时间与正文：行的形式是「[ 时间 ] (None) 正文」，类别不区分大小写。
/// 正文去掉标记。类别不是 None 或不是日志行时返回 `None`。
pub fn game_note(line: &str) -> Option<(f64, String)> {
    let parts = split(line)?;
    if parts.category != "none" {
        return None;
    }
    Some((utc_seconds(&parts.timestamp)?, plain_text(&parts.body)))
}

/// 去掉首尾空白、末尾的句号（半角与全角）与 `*`、开头的 `*`；空串返回 `None`。
fn cleaned(text: &str) -> Option<String> {
    let mut value = text.trim();
    while let Some(rest) = value.strip_suffix(['*', '.', '。']) {
        value = rest.trim();
    }
    let value = value.trim_start_matches('*').trim();
    (!value.is_empty()).then(|| value.to_owned())
}
