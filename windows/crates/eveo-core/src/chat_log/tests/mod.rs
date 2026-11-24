// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的用例，对应 macOS 的 ChatLogParserTests、ChatLogDirectoryTests、ChatLogCoverageTests、
// LocationLineParserTests 与 ChatLogFixtures。说话人、收听者与频道名都是虚构的；星系名是游戏的公开数据。
//
// 文件头 12 行：第 1 行只有 U+FEFF，第 2～4 行为空，第 5 行与第 11 行是分隔线，第 6 行为空，
// 第 7～10 行是 4 个字段，第 12 行为空。文件头的各行以 LF 结尾，消息行以 U+FEFF 开头、CRLF 结尾。

mod coverage;
mod directory;
mod location;
mod parser;

/// 虚构的收听者。
pub(super) const LISTENER: &str = "Kael Doran";
/// 虚构的玩家频道名。
pub(super) const PLAYER_CHANNEL_NAME: &str = "intel.Demo";
/// 虚构的玩家频道 ID。
pub(super) const PLAYER_CHANNEL_ID: &str = "player_0123456789abcdef0123456789abcdef";
/// 虚构的说话人。
pub(super) const SPEAKER: &str = "Mira Voss";
/// 2026-11-20 11:33:46 UTC 的秒数，与样例消息行的时间相同。
pub(super) const SAMPLE_TIME: f64 = 1_795_174_426.0;
/// 分隔线（前面有缩进，与客户端写的一样）。
pub(super) const SEPARATOR: &str = "        ---------------------------------------------------------------";

/// 一份文件头的 12 行（不含换行符）。
pub(super) fn header_lines(channel_id: &str, channel_name: &str) -> Vec<String> {
    vec![
        "\u{FEFF}".into(),
        String::new(),
        String::new(),
        String::new(),
        SEPARATOR.into(),
        String::new(),
        format!("          Channel ID:      {channel_id}"),
        format!("          Channel Name:    {channel_name}"),
        format!("          Listener:        {LISTENER}"),
        "          Session started: 2026.11.20 11:33:40".into(),
        SEPARATOR.into(),
        String::new(),
    ]
}

/// 一行消息（不含换行符），以 U+FEFF 开头。
pub(super) fn message_line(speaker: &str, text: &str) -> String {
    format!("\u{FEFF}[ 2026.11.20 11:33:46 ] {speaker} > {text}")
}

/// 一条预警消息，条目之间隔两个空格。
pub(super) fn intel_message() -> String {
    message_line(SPEAKER, "1DQ1-A  Tarn Vex  Sabre nv")
}
