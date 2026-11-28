// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗快速切换频道（switcher）的纯逻辑用例，对应 macOS 的 TranslationChannelSwitcherTests：
// 频道同一性、单选状态（含无 ID 引用补全 ID）、近期频道按活动角色优先排序、菜单分组与按钮文字。

use crate::chat_log::{ChatChannelKind, DiscoveredChannel};
use crate::model::ChannelRef;
use crate::translation::switcher;

/// 建一个发现的频道样例，把收听者转成小写并排序，保持与真实扫描结果一致。
fn discovered(
    id: &str,
    name: &str,
    kind: ChatChannelKind,
    last_modified: f64,
    listeners: &[&str],
) -> DiscoveredChannel {
    // 与 discovery::scan 一致：收听者按小写去重后排序，方便按当前角色优先匹配。
    let mut lower: Vec<String> = listeners.iter().map(|s| s.to_lowercase()).collect();
    lower.sort();
    DiscoveredChannel {
        id: id.to_owned(),
        name: name.to_owned(),
        kind,
        listeners: lower.len(),
        last_modified,
        listener_names: lower,
    }
}

/// 频道同一性：两边都有非空 ID 时按 ID，否则按去空白后的名字，不区分大小写。
#[test]
fn same_channel_matching() {
    // 频道改名后只要 ID 相同仍视为同一个频道。
    let by_id1 = ChannelRef::new("Old Name", Some("Player_42"));
    let by_id2 = ChannelRef::new("Renamed", Some("player_42"));
    assert!(switcher::is_same_channel(&by_id1, &by_id2));

    // 一边没有 ID 时退回名字匹配，忽略首尾空白与大小写。
    let by_name = ChannelRef::new("  intel.north  ", None);
    let with_id = ChannelRef::new("INTEL.NORTH", Some("player_99"));
    assert!(switcher::is_same_channel(&by_name, &with_id));

    // 空白 ID 按没有 ID 处理，与缺 ID 的引用一样走名字比较。
    let blank_id = ChannelRef::new("Fleet Chat", Some("   "));
    let no_id = ChannelRef::new("fleet chat", None);
    assert!(switcher::is_same_channel(&blank_id, &no_id));

    // 两边都有不同 ID 时即便名字相同也算不同频道。
    let different_id = ChannelRef::new("Same", Some("player_1"));
    let other_id = ChannelRef::new("Same", Some("player_2"));
    assert!(!switcher::is_same_channel(&different_id, &other_id));
}

/// 单选状态：只有唯一选中该频道时 is_only_selected 为真，多选与无 ID 升级时为假。
#[test]
fn single_and_multi_selection_state() {
    let built_ins = ChannelRef::built_ins();
    let local = &built_ins[0];
    let corp = &built_ins[1];
    // 唯一选中内置 Local 时视为无需重建。
    assert!(switcher::is_selected(local, std::slice::from_ref(local)));
    assert!(switcher::is_only_selected(local, std::slice::from_ref(local)));
    // 多选时菜单里仍打勾，但单选点击应切回只看这一个频道。
    assert!(switcher::is_selected(local, &[local.clone(), corp.clone()]));
    assert!(!switcher::is_only_selected(local, &[local.clone(), corp.clone()]));
    // 未选任何频道时两者都为假。
    assert!(!switcher::is_selected(local, &[]));
    assert!(!switcher::is_only_selected(local, &[]));
    // 之前按名字手动添加了 Local（无 ID），点内置 Local（带 ID）时应允许替换以补全 ID。
    let name_only_local = ChannelRef::new("Local", None);
    assert!(switcher::is_selected(
        local,
        std::slice::from_ref(&name_only_local)
    ));
    assert!(!switcher::is_only_selected(
        local,
        std::slice::from_ref(&name_only_local)
    ));
}

/// 近期频道排序：过滤内置与私聊，活动角色优先，再按活跃时间倒序并截断上限。
#[test]
fn ordered_recent_prioritizes_active_character() {
    // 混入内置频道、私聊、其他角色更新的频道与当前角色的旧频道，核对过滤与排序优先级。
    let input = [
        discovered("local", "Local", ChatChannelKind::Local, 900.0, &["Alpha"]),
        discovered("fleet_1", "Fleet", ChatChannelKind::Fleet, 900.0, &["Alpha"]),
        discovered("private_1", "DM", ChatChannelKind::PrivateChat, 900.0, &["Alpha"]),
        discovered(
            "player_other_new",
            "OtherNewest",
            ChatChannelKind::Player,
            500.0,
            &["Beta"],
        ),
        discovered(
            "player_alpha_old",
            "AlphaOlder",
            ChatChannelKind::Player,
            100.0,
            &["Alpha"],
        ),
        discovered(
            "player_alpha_new",
            "AlphaNewer",
            ChatChannelKind::Player,
            200.0,
            &["Alpha", "Beta"],
        ),
        discovered("other_1", "Help", ChatChannelKind::Other, 300.0, &["Beta"]),
    ];
    // 活动角色 Alpha 听过的两个频道排最前，再补其他角色最新的一个，总共截断为 3 项。
    let ordered = switcher::ordered_recent_channels(&input, Some("  alpha "), 3);
    let ids: Vec<&str> = ordered.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids, ["player_alpha_new", "player_alpha_old", "player_other_new"]);

    // 没有活动角色时不再区分角色，全部非内置非私聊频道按最后活跃时间倒序。
    let without_active = switcher::ordered_recent_channels(&input, None, 10);
    let ids: Vec<&str> = without_active.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(
        ids,
        [
            "player_other_new",
            "other_1",
            "player_alpha_new",
            "player_alpha_old"
        ]
    );
}

/// 菜单分组：保留不在内置与近期列表里的已选自定义频道，避免菜单里消失。
#[test]
fn sections_include_custom_selected() {
    // 近期日志里只有 Fleet Ops；已选里另有内置 Local 与一个超过 24 小时未发言的自定义频道。
    let recent = [discovered(
        "player_1",
        "Fleet Ops",
        ChatChannelKind::Player,
        300.0,
        &["Alpha"],
    )];
    let custom = ChannelRef::new("Old Quiet Channel", Some("player_quiet"));
    let selected = [
        ChannelRef::built_ins()[0].clone(),
        ChannelRef::new("Fleet Ops", Some("player_1")),
        custom.clone(),
    ];
    let sections = switcher::sections(&selected, &recent, Some("Alpha"), switcher::MAX_RECENT_CHANNELS);
    // 内置与近期频道不会重复进 custom_selected，只留下自定义静默频道。
    assert_eq!(sections.built_ins, ChannelRef::built_ins());
    assert_eq!(sections.recent.len(), 1);
    assert_eq!(sections.recent[0].id, "player_1");
    assert_eq!(sections.custom_selected, vec![custom]);
}

/// 按钮文字：未选、单选与多选三种格式。
#[test]
fn button_label_formats() {
    // 模拟本地化显示名：内置频道显示中文「本地」，自定义频道显示原名。
    let display = |c: &ChannelRef| {
        if c.is_built_in() {
            "本地".to_owned()
        } else {
            c.name.clone()
        }
    };
    let local = ChannelRef::built_ins()[0].clone();
    // 未选时显示占位词，单选时直接显示频道名，多选时拼出「+其余个数」。
    assert_eq!(switcher::button_label(&[], "选择频道", display), "选择频道");
    assert_eq!(
        switcher::button_label(std::slice::from_ref(&local), "选择频道", display),
        "本地"
    );
    assert_eq!(
        switcher::button_label(
            &[local, ChannelRef::new("A", None), ChannelRef::new("B", None)],
            "选择频道",
            display
        ),
        "本地 +2"
    );
}

/// DiscoveredChannel::has_listener 不区分大小写与首尾空白。
#[test]
fn discovered_channel_has_listener() {
    // 核对小写、带首尾空格、空串与其他角色名的匹配结果。
    let channel = discovered(
        "player_1",
        "Ops",
        ChatChannelKind::Player,
        100.0,
        &["Longge Jiang"],
    );
    assert!(channel.has_listener("longge jiang"));
    assert!(channel.has_listener("  LONGGE JIANG  "));
    assert!(!channel.has_listener(""));
    assert!(!channel.has_listener("Other Pilot"));
}
