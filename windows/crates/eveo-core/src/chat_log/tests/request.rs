// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跟踪请求：频道匹配与什么时候重建跟踪服务。

use std::collections::BTreeSet;

use super::{PLAYER_CHANNEL_ID, PLAYER_CHANNEL_NAME};
use crate::chat_log::request::ChatLogRequest;
use crate::model::ChannelRef;
use crate::overlay::OverlayKind;

/// 预警打开、跟踪本地与一个玩家频道的请求。
fn request() -> ChatLogRequest {
    ChatLogRequest {
        log_directory: None,
        channels: vec![
            ChannelRef::new("Local", Some("local")),
            ChannelRef::new(PLAYER_CHANNEL_NAME, None),
        ],
        follows_location: true,
        backfill_seconds: 1_800.0,
        enabled_features: BTreeSet::from([OverlayKind::Intel]),
    }
}

/// 按 ChannelRef 的规则匹配：内置频道看 ID，其余看名字；私聊一律不匹配。
#[test]
fn requested_channels() {
    let request = request();
    assert!(request.is_requested(Some("local"), Some("本地")));
    assert!(request.is_requested(Some(PLAYER_CHANNEL_ID), Some(" INTEL.demo ")));
    assert!(!request.is_requested(Some("corp"), Some("Corp")));
    assert!(!request.is_requested(Some("private_1"), Some(PLAYER_CHANNEL_NAME)));
}

/// 一边没有、目录、频道、位置、功能变了要重建；只有补读的秒数变了不重建。
#[test]
fn restart_rules() {
    let old = request();
    assert!(!ChatLogRequest::requires_restart(None, None));
    assert!(ChatLogRequest::requires_restart(None, Some(&old)));
    assert!(ChatLogRequest::requires_restart(Some(&old), None));
    assert!(!ChatLogRequest::requires_restart(Some(&old), Some(&old.clone())));

    let changes: [fn(&mut ChatLogRequest); 4] = [
        |r| r.log_directory = Some(r"D:\EVE\logs".into()),
        |r| r.channels.pop().map_or((), drop),
        |r| r.follows_location = false,
        |r| {
            r.enabled_features.insert(OverlayKind::Translation);
        },
    ];
    for change in changes {
        let mut new = old.clone();
        change(&mut new);
        assert!(ChatLogRequest::requires_restart(Some(&old), Some(&new)));
    }
    let mut longer = old.clone();
    longer.backfill_seconds = 7_200.0;
    assert!(!ChatLogRequest::requires_restart(Some(&old), Some(&longer)));
}
