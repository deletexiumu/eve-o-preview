// SPDX-License-Identifier: GPL-3.0-or-later
//
// 候选目录（Windows 路径）、文件名、跟踪文件的取舍与 UTF-16 的偶数偏移量。

use crate::chat_log::directory::*;
use crate::combat_log::directory as combat;

/// 自动查找的 logs 目录。
const AUTO: &str = r"C:\Users\Pilot\Documents\EVE\logs";

/// 4 种设置：没有（及空白）、logs、Gamelogs、Chatlogs；盘符根。
#[test]
fn chat_candidates() {
    let auto = [r"C:\Users\Pilot\Documents\EVE\logs\Chatlogs"];
    assert_eq!(candidates(None, AUTO), auto);
    assert_eq!(candidates(Some("  "), &format!("{AUTO}\\")), auto);
    assert_eq!(
        candidates(Some(r"D:\EVE\logs\"), AUTO),
        [r"D:\EVE\logs\Chatlogs", r"D:\EVE\logs"]
    );
    assert_eq!(
        candidates(Some(r"D:\EVE\logs\Gamelogs"), AUTO),
        [r"D:\EVE\logs\Chatlogs"]
    );
    assert_eq!(
        candidates(Some("D:/EVE/logs/CHATLOGS/"), AUTO),
        ["D:/EVE/logs/CHATLOGS"]
    );
    assert_eq!(candidates(Some(r"E:\Gamelogs"), AUTO), [r"E:\Chatlogs"]);
}

/// 游戏日志的候选：设置指向 Chatlogs 时找同级的 Gamelogs，其余同 combat_log。
#[test]
fn game_candidates() {
    assert_eq!(
        game_log_candidates(Some(r"D:\EVE\logs\Chatlogs"), AUTO),
        [r"D:\EVE\logs\Gamelogs", r"D:\EVE\logs"]
    );
    assert_eq!(
        game_log_candidates(Some(r"D:\EVE\logs"), AUTO),
        combat::candidates(Some(r"D:\EVE\logs"), AUTO)
    );
    assert_eq!(
        game_log_candidates(None, AUTO),
        [r"C:\Users\Pilot\Documents\EVE\logs\Gamelogs"]
    );
}

/// 频道名里有 `.`、`+`、`_` 与汉字时，从右边解析。
#[test]
fn file_names() {
    assert_eq!(
        parse_file_name("intel.Demo_20261120_113340_1234567890.txt"),
        Some(FileName {
            channel: "intel.Demo".into(),
            stamp: "20261120_113340".into(),
            suffix: "1234567890".into()
        })
    );
    assert_eq!(
        parse_file_name("a+b_c_20261120_113340_7.TXT").map(|f| f.channel),
        Some("a+b_c".into())
    );
    assert_eq!(
        parse_file_name("预警_频道_20261120_000001_42.txt").map(|f| f.channel),
        Some("预警_频道".into())
    );
    assert_eq!(
        parse_file_name("Local_20261119_235959_1.txt").map(|f| f.stamp),
        Some("20261119_235959".into())
    );
}

/// 不合法的文件名返回 None。
#[test]
fn invalid_file_names() {
    for name in [
        "Local_20261119_235959.txt",
        "_20261119_235959_1.txt",
        "Local_2026111_235959_1.txt",
        "Local_20261119_23595_1.txt",
        "Local_20261119_235959_x.txt",
        "Local_20261119_235959_1.log",
        "Local_20261119_235959_.txt",
        ".txt",
        "20261119_235959_1.txt",
        "预.txt",
    ] {
        assert_eq!(parse_file_name(name), None, "{name}");
    }
}

/// 同一个（收听者，频道）取时间戳最大的；超过上限时留最新的；不同收听者各留一个。
#[test]
fn select_newest() {
    let c = |name: &str, stamp: &str, listener: &str, channel_id: &str| Candidate {
        name: name.into(),
        stamp: stamp.into(),
        listener: listener.into(),
        channel_id: channel_id.into(),
    };
    let candidates = [
        c("old", "20261119_100000", "Kael Doran", "player_a"),
        c("new", "20261120_100000", "Kael Doran", "player_a"),
        c("other-listener", "20261118_100000", "Mira Voss", "player_a"),
        c("local", "20261120_090000", "Kael Doran", "local"),
    ];
    assert_eq!(
        select_followed(&candidates, MAX_FOLLOWED_FILES),
        ["new", "local", "other-listener"]
    );
    assert_eq!(select_followed(&candidates, 2), ["new", "local"]);
    assert!(select_followed(&candidates, 0).is_empty());
    assert_eq!((MAX_FOLLOWED_FILES, RECENT_SECONDS), (48, 172_800.0));
}

/// 偏移量向下取成偶数；补读的起点不小于 0、总是偶数。
#[test]
fn offsets() {
    assert_eq!(
        [aligned_offset(0), aligned_offset(7), aligned_offset(8)],
        [0, 6, 8]
    );
    assert_eq!(backfill_start(1_000, 524_288), 0);
    assert_eq!(backfill_start(600_000, 524_288), 75_712);
    assert_eq!(backfill_start(600_001, 524_288), 75_712);
    assert_eq!(backfill_start(524_289, 524_287) % 2, 0);
}
