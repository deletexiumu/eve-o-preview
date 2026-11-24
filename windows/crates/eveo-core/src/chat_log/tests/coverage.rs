// SPDX-License-Identifier: GPL-3.0-or-later
//
// 覆盖情况：活动角色在所选频道里有没有被跟踪的日志文件。

use crate::chat_log::coverage::*;
use crate::model::ChannelRef;

/// 虚构的玩家频道。
fn intel() -> ChannelRef {
    ChannelRef::new("intel.Demo", Some("player_00000000000000000000000000de0001"))
}

/// Local 内置频道。
fn local() -> ChannelRef {
    ChannelRef::new("Local", Some("local"))
}

/// 一个被跟踪的文件。
fn followed(listener: &str, id: &str, name: &str) -> FollowedChatChannel {
    FollowedChatChannel {
        listener: listener.into(),
        channel_id: id.into(),
        channel_name: Some(name.into()),
    }
}

/// 只有玩家频道的文件：Local 算缺失；有一个频道有文件就不算「全部缺失」，缺的那个仍列出来。
#[test]
fn missing_and_partial() {
    let list = [followed(
        "Demo Pilot",
        "player_00000000000000000000000000de0001",
        "intel.Demo",
    )];
    assert_eq!(missing_channels("Demo Pilot", &[local()], Some(&list)), [local()]);
    assert!(lacks_all_logs("Demo Pilot", &[local()], Some(&list)));
    let both = [local(), intel()];
    assert_eq!(missing_channels("Demo Pilot", &both, Some(&list)), [local()]);
    assert!(!lacks_all_logs("Demo Pilot", &both, Some(&list)));
}

/// 内置频道按 ID 匹配；别的角色的文件不算；收听者只差大小写时认作同一个，原样相等的优先。
#[test]
fn listener_and_id_matching() {
    assert!(!lacks_all_logs(
        "Demo Pilot",
        &[local()],
        Some(&[followed("Demo Pilot", "local", "本地")])
    ));
    assert!(lacks_all_logs(
        "Demo Pilot",
        &[local()],
        Some(&[followed("Demo Other", "local", "Local")])
    ));
    assert!(!lacks_all_logs(
        "Demo Pilot",
        &[local()],
        Some(&[followed("demo pilot", "local", "Local")])
    ));
    let two = [
        followed("demo pilot", "local", "Local"),
        followed("Demo Pilot", "corp", "Corp"),
    ];
    assert!(lacks_all_logs("Demo Pilot", &[local()], Some(&two)));
}

/// 还没扫描完或没有选频道时不提示；跟踪列表为空时全部缺失。
#[test]
fn unknown_or_empty() {
    assert!(missing_channels("Demo Pilot", &[local()], None).is_empty());
    assert!(!lacks_all_logs("Demo Pilot", &[local()], None));
    assert!(!lacks_all_logs("Demo Pilot", &[], Some(&[])));
    let corp = ChannelRef::new("Corp", Some("corp"));
    assert!(lacks_all_logs("Demo Pilot", &[local(), corp], Some(&[])));
}

/// 名字匹配：先原样，再不区分大小写，取靠前的。
#[test]
fn name_matching() {
    assert_eq!(
        match_name("Demo Pilot", ["demo pilot", "Demo Pilot"]),
        Some("Demo Pilot")
    );
    assert_eq!(
        match_name("Demo Pilot", ["DEMO PILOT", "demo pilot"]),
        Some("DEMO PILOT")
    );
    assert_eq!(match_name("Demo Pilot", ["Other"]), None);
}
