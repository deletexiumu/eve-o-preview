// SPDX-License-Identifier: GPL-3.0-or-later
//
// 位置线索的句式：Local 的系统消息与游戏日志的 (None) 行。

use super::SAMPLE_TIME;
use crate::chat_log::location::*;

/// Local 的系统消息：最后一个冒号后的部分，去掉 `*` 与句号。
#[test]
fn local_system_lines() {
    let name = |text: &str| system_name_from_local(text);
    assert_eq!(name("Channel changed to Local : Jita").as_deref(), Some("Jita"));
    assert_eq!(name("频道更换为本地：吉他*").as_deref(), Some("吉他"));
    assert_eq!(
        name("Channel changed to Local : New Caldari.").as_deref(),
        Some("New Caldari")
    );
    assert_eq!(name("Local: HED-GP* 。").as_deref(), Some("HED-GP"));
    assert_eq!(name("Channel changed to Local"), None);
    assert_eq!(name("Channel changed to Local : "), None);
}

/// 游戏日志的 4 种句式。
#[test]
fn game_note_patterns() {
    let name = |text: &str| system_name_from_game_note(text);
    assert_eq!(name("从吉他*跳到皮尔米特*").as_deref(), Some("皮尔米特"));
    assert_eq!(name("从1DQ1-A跳到T5ZI-S").as_deref(), Some("T5ZI-S"));
    assert_eq!(
        name("正在从 吉他 IV - 卫星 4 - 加达里海军组装工厂* 离站进入 吉他* 恒星系。").as_deref(),
        Some("吉他")
    );
    assert_eq!(
        name("Jumping from Jita to Perimeter").as_deref(),
        Some("Perimeter")
    );
    assert_eq!(
        name("jumping from New Caldari to Urlen.").as_deref(),
        Some("Urlen")
    );
    assert_eq!(
        name("Undocking from Jita IV - Moon 4 - Caldari Navy Assembly Plant to Jita solar system.")
            .as_deref(),
        Some("Jita")
    );
    for unknown in [
        "Вы прыгнули из Jita в Perimeter",
        "Jita",
        "",
        "Undocking from somewhere",
    ] {
        assert_eq!(name(unknown), None, "{unknown}");
    }
}

/// (None) 行的时间与正文；类别不区分大小写，其他类别与非日志行返回 None。
#[test]
fn game_notes() {
    let note = game_note("[ 2026.11.20 11:33:46 ] (None) 从<b>吉他*</b>跳到<color=0xffffffff>皮尔米特*")
        .expect("行");
    assert_eq!(note, (SAMPLE_TIME, "从吉他*跳到皮尔米特*".to_owned()));
    let english = game_note("[ 2026.11.20 11:33:46 ] (NONE) Jumping from Jita to Perimeter").map(|n| n.1);
    assert_eq!(english.as_deref(), Some("Jumping from Jita to Perimeter"));
    assert_eq!(game_note("[ 2026.11.20 11:33:46 ] (combat) 100 from Sabre"), None);
    assert_eq!(
        game_note("[ 2026.11.20 11:33:46 ] (notify) 从吉他跳到皮尔米特"),
        None
    );
    assert_eq!(game_note("not a log line"), None);
    assert_eq!(
        game_note("\u{FEFF}[ 2026.11.20 11:33:46 ] (None) x")
            .map(|n| n.1)
            .as_deref(),
        Some("x")
    );
}
