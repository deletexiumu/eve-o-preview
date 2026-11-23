// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件头解析的用例，对应 macOS 的 CombatLogHeaderParserTests.swift 与 CombatLogEdgeCaseTests.swift 里文件头的部分：
// 8 种语言的标签、全角冒号与冒号前的空格、没有收听者、3 行的兜底、不完整、超长、BOM，以及与分行器串起来。

use super::*;
use crate::combat_log::framer::LogLineFramer;
use crate::combat_log::header::{CombatLogHeader, MAX_HEADER_LINES, parse};

/// 有收听者的完整结果。
fn found(name: &str) -> CombatLogHeader {
    CombatLogHeader {
        listener: Some(name.to_owned()),
        is_complete: true,
    }
}

/// 完整但没有收听者的结果。
const NO_LISTENER: CombatLogHeader = CombatLogHeader {
    listener: None,
    is_complete: true,
};

/// 中文与英文的真实文件头；8 种语言的收听者标签都能识别，名字里的空格保留。
#[test]
fn real_headers_and_eight_labels() {
    assert_eq!(parse(&ZH_HEADER), found("Aurora Vale"));
    assert_eq!(parse(&EN_HEADER), found("Aurora Vale"));
    for (title, label, session) in HEADER_LABELS {
        let lines = header(title, label, session, "Sample Observer", ": ");
        assert_eq!(parse(&lines), found("Sample Observer"), "{label}");
    }
}

/// 全角冒号，以及法文排版习惯的「冒号前有空格」（普通空格与不换行空格）。
#[test]
fn colon_variants() {
    let full_width = header("游戏记录", "收听者", "进程开始", "Aurora Vale", "：");
    assert_eq!(parse(&full_width).listener.as_deref(), Some("Aurora Vale"));
    for colon in [" : ", "\u{00A0}: "] {
        let french = header("Journal", "Auditeur", "Session commencée", "Aurora Vale", colon);
        assert_eq!(
            parse(&french).listener.as_deref(),
            Some("Aurora Vale"),
            "{colon:?}"
        );
        // 标签识别不依赖兜底：分隔线之间多一行（不是 3 行）也能取到。
        let mut extra = french.clone();
        extra.insert(1, "  extra".to_owned());
        assert_eq!(
            parse(&extra).listener.as_deref(),
            Some("Aurora Vale"),
            "{colon:?}"
        );
    }
    // 窄不换行空格（U+202F）不在标签后允许的空白里：3 行的文件头靠兜底取到收听者。
    let narrow = header(
        "Journal",
        "Auditeur",
        "Session commencée",
        "Aurora Vale",
        "\u{202F}: ",
    );
    assert_eq!(parse(&narrow).listener.as_deref(), Some("Aurora Vale"));
}

/// 登录界面阶段的文件：文件头完整，没有收听者。分隔线之间只有 2 行，不触发兜底。
#[test]
fn header_without_listener() {
    assert_eq!(parse(&ZH_HEADER_WITHOUT_LISTENER), NO_LISTENER);
}

/// 标签不认识、但分隔线之间正好 3 行时，取第 2 行冒号后的部分；不是 3 行时没有收听者。
#[test]
fn unknown_label_fallback() {
    let lines = header("Pelilokit", "Kuuntelija", "Aloitettu", "Sample Observer", ": ");
    assert_eq!(parse(&lines), found("Sample Observer"));
    let mut four = lines;
    four.insert(2, "  extra".to_owned());
    assert_eq!(parse(&four), NO_LISTENER);
}

/// 还没读到第二条分隔线：不完整；读满上限仍没有第二条分隔线：视为完整、没有收听者。
#[test]
fn incomplete_and_too_many_lines() {
    let partial = CombatLogHeader {
        listener: None,
        is_complete: false,
    };
    assert_eq!(parse(&ZH_HEADER[..3]), partial);
    assert_eq!(parse::<&str>(&[]), partial);
    let mut lines = vec![SEPARATOR.to_owned()];
    lines.extend(std::iter::repeat_n("  noise".to_owned(), MAX_HEADER_LINES));
    lines.push(SEPARATOR.to_owned());
    assert_eq!(parse(&lines), NO_LISTENER);
}

/// 第二条分隔线恰在第 12 行：仍在读取范围内；在第 13 行时超出范围，没有收听者。
#[test]
fn second_separator_at_line_limit() {
    let lines = |padding: usize| {
        let mut v = vec![
            SEPARATOR.to_owned(),
            "  Game Log".into(),
            "  Listener: Aurora Vale".into(),
        ];
        v.extend(std::iter::repeat_n("  padding".to_owned(), padding));
        v.push(SEPARATOR.to_owned());
        v
    };
    let at_limit = lines(MAX_HEADER_LINES - 4);
    assert_eq!(at_limit.len(), MAX_HEADER_LINES);
    assert_eq!(parse(&at_limit), found("Aurora Vale"));
    assert_eq!(parse(&lines(MAX_HEADER_LINES - 3)), NO_LISTENER);
}

/// 空的收听者按没有收听者处理；第一条分隔线前有 BOM、各行带回车时照常识别。
#[test]
fn empty_listener_and_bom() {
    let empty = header("Game Log", "Listener", "Session Started", "   ", ": ");
    assert_eq!(parse(&empty).listener, None);
    let mut lines: Vec<String> = ZH_HEADER.iter().map(|l| format!("{l}\r")).collect();
    lines[0] = format!("\u{FEFF}{}", lines[0]);
    assert_eq!(parse(&lines), found("Aurora Vale"));
}

/// 分行器与文件头解析串起来：UTF-16 小端带 BOM 的文件头也能取到收听者。
#[test]
fn utf16_header_through_framer() {
    let text = EN_HEADER.join("\r\n") + "\r\n";
    let mut data = vec![0xFF, 0xFE];
    for unit in text.encode_utf16() {
        data.extend_from_slice(&unit.to_le_bytes());
    }
    let lines = LogLineFramer::default().append(&data);
    assert_eq!(parse(&lines), found("Aurora Vale"));
}
