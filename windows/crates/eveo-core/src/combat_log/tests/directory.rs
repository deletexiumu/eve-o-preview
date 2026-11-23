// SPDX-License-Identifier: GPL-3.0-or-later
//
// 目录与文件取舍的用例，对应 macOS 的 CombatLogDirectoryTests.swift。路径换成 Windows 的写法：
// 自动查找的 logs 目录、设置的 logs 或 Gamelogs 目录、误选 Chatlogs、末尾的分隔符与盘符根。

use crate::combat_log::directory::*;

/// 自动查找的 logs 目录。
const AUTO: &str = r"C:\Users\Pilot\Documents\EVE\logs";

/// 没有设置（或设置是空白）时取自动查找的位置下的 Gamelogs。
#[test]
fn default_path() {
    let expected = [r"C:\Users\Pilot\Documents\EVE\logs\Gamelogs"];
    assert_eq!(candidates(None, AUTO), expected);
    assert_eq!(candidates(Some("  "), AUTO), expected);
    assert_eq!(candidates(None, &format!("{AUTO}\\")), expected);
}

/// 设置的是 logs 目录：先找它下面的 Gamelogs，再找它自己；末尾的分隔符去掉，正斜杠也认。
#[test]
fn logs_directory() {
    assert_eq!(
        candidates(Some(r"D:\EVE\logs\"), AUTO),
        [r"D:\EVE\logs\Gamelogs", r"D:\EVE\logs"]
    );
    assert_eq!(
        candidates(Some("D:/EVE/logs"), AUTO),
        [r"D:/EVE/logs\Gamelogs", "D:/EVE/logs"]
    );
}

/// 设置的就是 Gamelogs 目录（不区分大小写）：只返回它自己。误选了 Chatlogs：按它的上一级处理。
#[test]
fn gamelogs_and_chatlogs_directory() {
    assert_eq!(
        candidates(Some(r"D:\EVE\logs\Gamelogs"), AUTO),
        [r"D:\EVE\logs\Gamelogs"]
    );
    assert_eq!(
        candidates(Some(r"D:\Temp\GAMELOGS\"), AUTO),
        [r"D:\Temp\GAMELOGS"]
    );
    assert_eq!(
        candidates(Some(r"D:\EVE\logs\Chatlogs"), AUTO),
        [r"D:\EVE\logs\Gamelogs", r"D:\EVE\logs"]
    );
}

/// 盘符根：保留分隔符，拼接时不重复。
#[test]
fn drive_root() {
    assert_eq!(candidates(Some(r"E:\"), AUTO), [r"E:\Gamelogs", r"E:\"]);
}

/// 日志目录：设置的优先，空白算没设置；填成子文件夹时取上一级；名字只是以 Gamelogs 结尾的别的文件夹不算。
#[test]
fn log_root_choice() {
    assert_eq!(log_root(None, AUTO), AUTO);
    assert_eq!(log_root(Some("   "), AUTO), AUTO);
    assert_eq!(log_root(Some(r"D:\EVE\logs\"), AUTO), r"D:\EVE\logs");
    assert_eq!(log_root(Some(r"D:\EVE\logs\gamelogs"), AUTO), r"D:\EVE\logs");
    assert_eq!(log_root(Some("D:/EVE/logs/Chatlogs/"), AUTO), "D:/EVE/logs");
    assert_eq!(log_root(Some(r"D:\MyGamelogs"), AUTO), r"D:\MyGamelogs");
}

/// 只认 `.txt` 文件，隐藏文件不算。
#[test]
fn log_file_names() {
    assert!(is_log_file_name("20261120_113346_1234567890.txt"));
    assert!(is_log_file_name("20261120_113329.TXT"));
    assert!(!is_log_file_name(".DS_Store"));
    assert!(!is_log_file_name("._20261120_113329.txt"));
    assert!(!is_log_file_name("notes.log"));
}

/// 修改时间在 48 小时内的文件才看（边界算在内，时钟稍有偏差的未来时间也算）。
#[test]
fn recent_window() {
    let now = 1_000_000.0;
    assert!(is_recent(now - RECENT_WINDOW, now));
    assert!(!is_recent(now - RECENT_WINDOW - 1.0, now));
    assert!(is_recent(now + 5.0, now));
}

/// 同一个收听者只取文件名最大的；结果按文件名从大到小排列；超过上限时保留文件名最大的那些。
#[test]
fn select_newest_per_listener() {
    let candidate = |name: &str, listener: &str| Candidate {
        name: name.into(),
        listener: listener.into(),
    };
    let list = [
        candidate("20261120_095137_1.txt", "Aurora Vale"),
        candidate("20261120_113331_1.txt", "Aurora Vale"),
        candidate("20261120_113346_2.txt", "Borealis Kade"),
        candidate("20261119_080000_3.txt", "Cygnus Ward"),
    ];
    assert_eq!(
        select_followed(&list, MAX_FOLLOWED_FILES),
        [
            "20261120_113346_2.txt",
            "20261120_113331_1.txt",
            "20261119_080000_3.txt"
        ]
    );
    let many: Vec<Candidate> = (0..20)
        .map(|i| candidate(&format!("20261120_{i:06}.txt"), &format!("Pilot {i}")))
        .collect();
    let selected = select_followed(&many, MAX_FOLLOWED_FILES);
    assert_eq!(selected.len(), MAX_FOLLOWED_FILES);
    assert_eq!(selected.first().map(String::as_str), Some("20261120_000019.txt"));
    assert_eq!(selected.last().map(String::as_str), Some("20261120_000004.txt"));
}

/// 启动前已有的文件（创建时间早于启动时刻减 2 秒）从末尾读起，之后建的从头读起；读不到创建时间按已有处理。
#[test]
fn start_offset() {
    let start = 5_000.0;
    assert!(starts_at_end(Some(start - 10.0), start));
    assert!(!starts_at_end(Some(start - 2.0), start));
    assert!(!starts_at_end(Some(start + 30.0), start));
    assert!(starts_at_end(None, start));
}

/// 文件变短时视为被截断，从 0 开始读。
#[test]
fn truncation() {
    assert_eq!(read_start(100, 150), (100, false));
    assert_eq!(read_start(100, 100), (100, false));
    assert_eq!(read_start(100, 40), (0, true));
}
