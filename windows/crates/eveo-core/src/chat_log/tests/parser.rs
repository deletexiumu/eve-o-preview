// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件头、消息行、频道种类与正文清理；最后一条走一遍真实的读取路径：UTF-16 小端字节 → 分行器 → 解析。

use super::*;
use crate::chat_log::ChatChannelKind::*;
use crate::chat_log::parser::*;
use crate::chat_log::{ChatChannelKind, ChatLogHeader};
use crate::combat_log::framer::{LogLineFramer, LogTextEncoding};

/// 完整的文件头结果。
fn complete(id: Option<&str>, name: Option<&str>, listener: Option<&str>) -> ChatLogHeader {
    ChatLogHeader {
        channel_id: id.map(str::to_owned),
        channel_name: name.map(str::to_owned),
        listener: listener.map(str::to_owned),
        is_complete: true,
    }
}

/// 3 份文件头：玩家频道、Local、军团。
#[test]
fn headers() {
    let player = parse_header(&header_lines(PLAYER_CHANNEL_ID, PLAYER_CHANNEL_NAME));
    assert_eq!(
        player,
        complete(Some(PLAYER_CHANNEL_ID), Some(PLAYER_CHANNEL_NAME), Some(LISTENER))
    );
    assert_eq!(player.kind(), Player);
    let local = parse_header(&header_lines("local", "Local"));
    assert_eq!(
        (local.channel_name.as_deref(), local.kind()),
        (Some("Local"), Local)
    );
    assert_eq!(parse_header(&header_lines("corp", "Corp")).kind(), Corp);
}

/// 标签被翻译而正好 4 行时按位置取；不是 4 行时不猜。
#[test]
fn unknown_labels() {
    let lines = [
        "\u{FEFF}",
        SEPARATOR,
        "  频道 ID：player_abc",
        "  频道名称： intel.Demo",
        "  收听者：Kael Doran",
        "  开始：2026.11.20 11:33:40",
        SEPARATOR,
    ];
    assert_eq!(
        parse_header(&lines),
        complete(Some("player_abc"), Some("intel.Demo"), Some("Kael Doran"))
    );
    let three = [SEPARATOR, "A: 1", "B: 2", "C: 3", SEPARATOR];
    assert_eq!(parse_header(&three), complete(None, None, None));
}

/// 标签不区分大小写；值为空时为 None；值里的冒号保留。
#[test]
fn labels_and_values() {
    let lines = [
        SEPARATOR,
        "channel id: corp",
        "CHANNEL NAME:",
        "Listener: Kael: Doran",
        SEPARATOR,
    ];
    assert_eq!(
        parse_header(&lines),
        complete(Some("corp"), None, Some("Kael: Doran"))
    );
}

/// 还没有第二条分隔线：不完整；读满上限仍没有：完整、字段为 None。
#[test]
fn incomplete_and_overlong() {
    let partial = parse_header(&header_lines(PLAYER_CHANNEL_ID, PLAYER_CHANNEL_NAME)[..8]);
    assert!(!partial.is_complete && partial.channel_id.is_none());
    let mut lines = vec![SEPARATOR.to_owned()];
    lines.extend(std::iter::repeat_n("Channel ID: corp".to_owned(), 20));
    assert_eq!(parse_header(&lines), complete(None, None, None));
}

/// 带 U+FEFF 与回车的消息行，时间按 UTC；正文里的 ` > ` 保留在正文里。
#[test]
fn message_lines() {
    let line = parse_line(&(intel_message() + "\r")).expect("消息行");
    assert_eq!((line.time, line.speaker.as_str()), (SAMPLE_TIME, SPEAKER));
    assert_eq!(line.text, "1DQ1-A  Tarn Vex  Sabre nv");
    assert!(!line.is_system);
    let arrows = parse_line(&message_line("Ilya>Morrow", "Jita > Perimeter > Urlen")).expect("消息行");
    assert_eq!(
        (arrows.speaker.as_str(), arrows.text.as_str()),
        ("Ilya>Morrow", "Jita > Perimeter > Urlen")
    );
}

/// 不合法的行返回 None。
#[test]
fn invalid_lines() {
    for line in [
        "\u{FEFF}[ 2026.13.20 11:33:46 ] Mira Voss > hi",
        "\u{FEFF}[ 2026.11.20 25:33:46 ] Mira Voss > hi",
        "\u{FEFF}[ 2026.11.20 11:33 ] Mira Voss > hi",
        "\u{FEFF}[ 2026.11.20 11:33:46 ] Mira Voss: hi",
        "\u{FEFF}[ 2026.11.20 11:33:46 ]  > hi",
        "\u{FEFF}2026.11.20 11:33:46 ] Mira Voss > hi",
        "",
        "\u{FEFF}",
    ] {
        assert!(parse_line(line).is_none(), "{line:?}");
    }
}

/// EVE System 与 EVE系统 是系统消息。
#[test]
fn system_speakers() {
    let english = parse_line(&message_line("EVE System", "Channel changed to Local : Jita")).expect("行");
    assert!(english.is_system);
    let chinese = parse_line(&message_line("EVE系统", "频道更换为本地：吉他*")).expect("行");
    assert!(chinese.is_system && chinese.text == "频道更换为本地：吉他*");
}

/// 保留连续空格，去掉标记，<br> 换成换行，解码 5 种实体，去首尾空白。
#[test]
fn plain_text_rules() {
    assert_eq!(plain_text("  HED-GP*  Tarn Vex  "), "HED-GP*  Tarn Vex");
    assert_eq!(plain_text("<b>Jita</b>\tclr"), "Jita\tclr");
    assert_eq!(plain_text("a<br>b<BR/>c<br />d"), "a\nb\nc\nd");
    assert_eq!(
        plain_text("&lt;3 &amp;&amp; &quot;x&quot; it&#39;s &gt;"),
        "<3 && \"x\" it's >"
    );
    assert_eq!(plain_text("&amp;lt;"), "&lt;");
    assert_eq!(plain_text("1 < 2 and 3"), "1 < 2 and 3");
    assert_eq!(plain_text("&nbsp;x"), "&nbsp;x");
}

/// 7 种频道种类，比较不区分大小写。
#[test]
fn channel_kinds() {
    let cases: [(Option<&str>, ChatChannelKind); 8] = [
        (Some("local"), Local),
        (Some("Corp"), Corp),
        (Some("alliance"), Alliance),
        (Some("fleet_123"), Fleet),
        (Some("player_abc"), Player),
        (Some("PRIVATE_1"), PrivateChat),
        (Some("something"), Other),
        (None, Other),
    ];
    for (id, kind) in cases {
        assert_eq!(channel_kind(id), kind, "{id:?}");
    }
}

/// UTF-16 小端字节经分行器切行后解析；字节分成奇数大小的两段追加，切点落在码元中间也不错位。
#[test]
fn end_to_end_through_framer() {
    let header = header_lines(PLAYER_CHANNEL_ID, PLAYER_CHANNEL_NAME);
    let messages = [
        intel_message(),
        message_line("EVE System", "Channel changed to Local : Jita"),
    ];
    let text: String = header
        .iter()
        .map(|l| format!("{l}\n"))
        .chain(messages.iter().map(|m| format!("{m}\r\n")))
        .collect();
    // 文本以 U+FEFF 开头，编码后就是 BOM（FF FE）。
    let bytes: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
    assert_eq!(&bytes[..2], [0xFF, 0xFE]);
    let mut framer = LogLineFramer::default();
    let mut lines = framer.append(&bytes[..301]);
    lines.extend(framer.append(&bytes[301..]));
    assert_eq!(framer.encoding(), Some(LogTextEncoding::Utf16LittleEndian));
    let parsed_header = parse_header(&lines[..MAX_HEADER_LINES.min(lines.len())]);
    assert_eq!(parsed_header.channel_id.as_deref(), Some(PLAYER_CHANNEL_ID));
    let parsed: Vec<_> = lines.iter().filter_map(|l| parse_line(l)).collect();
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].text, "1DQ1-A  Tarn Vex  Sabre nv");
    assert!(parsed[1].is_system);
}
