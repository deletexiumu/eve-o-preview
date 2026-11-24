// SPDX-License-Identifier: GPL-3.0-or-later
//
// 总控的用例，对应 macOS 的 ChatFeatureControllerTests：请求怎么由配置算出、什么时候要重建跟踪服务、
// 事件按频道分发、星图数据只要求读一次、按时间刷新只看可见的浮窗。夹具与 tests.rs 共用。

use std::collections::{BTreeMap, BTreeSet};

use eveo_core::chat_log::coverage::FollowedChatChannel;
use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus, ChatMessage};
use eveo_core::model::{AppConfig, AppLanguage, ChannelRef};
use eveo_core::overlay::OverlayKind;

use super::features::{ChatFeatures, StaticDataLoad, TailerCommand};
use super::intel::IntelController;
use super::tests::{ACTIVE, NOW, data, local, message};
use crate::config_store::default_config;

/// 预警开着、选了 Intel.North 的默认配置。
fn config() -> AppConfig {
    let mut config = default_config();
    let profile = config.active_profile_mut().expect("默认配置有一个方案");
    profile.intel.enabled = true;
    profile.intel.channels = vec![ChannelRef::new("Intel.North", None)];
    config
}

/// 改当前方案的预警设置后的配置。
fn with_intel(config: &AppConfig, edit: impl FnOnce(&mut eveo_core::model::IntelSettings)) -> AppConfig {
    let mut config = config.clone();
    edit(&mut config.active_profile_mut().expect("有方案").intel);
    config
}

/// 新的总控（不接人名核对）。
fn features() -> ChatFeatures {
    ChatFeatures::new(IntelController::new(BTreeMap::new(), None), AppLanguage::En)
}

/// 请求：频道去重、跟踪位置、补读「保留最近」的分钟数；预警关着时没有请求。
#[test]
fn request_follows_intel_settings() {
    let config = with_intel(&config(), |intel| {
        intel.channels.push(ChannelRef::new("Intel.North", None));
        intel.window_minutes = 15;
    });
    // 同一个频道加了两次、「保留最近」改成 15 分钟。
    let request = ChatFeatures::request_for(&config).expect("预警开着");
    assert_eq!(request.channels.len(), 1, "重复的频道只跟踪一次");
    assert!(request.follows_location);
    assert_eq!(request.backfill_seconds, 900.0);
    assert_eq!(request.enabled_features, BTreeSet::from([OverlayKind::Intel]));
    let off = with_intel(&config, |intel| intel.enabled = false);
    assert!(ChatFeatures::request_for(&off).is_none());
}

/// 重建：第一次打开要开始；只改「保留最近」不重建；换频道要重建并清空缓冲；关掉要停止。
#[test]
fn restart_rules() {
    let mut features = features();
    let first = config();
    assert!(matches!(
        features.apply(&first, NOW),
        Some(TailerCommand::Start(_))
    ));
    // 同一份配置再交一次（例如别的设置变了）：什么也不用做。
    assert_eq!(features.apply(&first, NOW), None);
    let longer = with_intel(&first, |intel| intel.window_minutes = 60);
    assert_eq!(features.apply(&longer, NOW), None, "只改补读秒数不重建");

    // 先收一条消息，确认缓冲里有东西，后面才能看出重建时清空了它。
    features.set_active_character(Some(ACTIVE.to_owned()), NOW);
    features.events(vec![message(ACTIVE, "Jita clear", NOW)], NOW);
    assert_eq!(features.content(OverlayKind::Intel, NOW).lines.len(), 1);
    let other_channel = with_intel(&longer, |intel| {
        intel.channels = vec![ChannelRef::new("Intel.South", None)];
    });
    assert!(matches!(
        features.apply(&other_channel, NOW),
        Some(TailerCommand::Start(_))
    ));
    // 重建前清空缓冲：跟踪服务重建后补读会把消息填回来，不清空就会重复。
    assert!(features.content(OverlayKind::Intel, NOW).lines.is_empty());

    let off = with_intel(&other_channel, |intel| intel.enabled = false);
    assert_eq!(features.apply(&off, NOW), Some(TailerCommand::Stop));
}

/// 星图数据：第一次有功能打开后要求读一次，之后不再要求；读完后状态写成 build-<版本号>。
#[test]
fn static_data_requested_once() {
    let mut features = features();
    // 启动时预警关着：不读星图数据，省下解码几 MB 文件的时间与内存。
    let off = with_intel(&config(), |intel| intel.enabled = false);
    features.apply(&off, NOW);
    assert!(!features.take_static_data_request(), "功能都关着时不读");
    features.apply(&config(), NOW);
    assert!(features.take_static_data_request());
    assert!(!features.take_static_data_request(), "只要求一次");
    assert_eq!(features.static_data_state(), "notLoaded");
    let line = features.static_data_loaded(StaticDataLoad::Loaded(data(), "bundle"), NOW);
    assert_eq!(features.static_data_state(), "build-3720952");
    assert!(line.contains("3720952"), "{line}");
    assert!(features.intel().static_data_build().is_some());
    // 结果只决定状态文字；真实应用只读一次，这里再交一次只为看状态文字的写法。
    features.static_data_loaded(StaticDataLoad::Missing, NOW);
    assert_eq!(features.static_data_state(), "missing");
}

/// 分发：频道不匹配的消息不给预警；位置线索在预警开着时给预警。
#[test]
fn events_are_routed_by_channel() {
    let mut features = features();
    features.apply(&config(), NOW);
    features.static_data_loaded(StaticDataLoad::Loaded(data(), "bundle"), NOW);
    features.set_active_character(Some(ACTIVE.to_owned()), NOW);
    // 军团频道的消息：跟踪服务不会读到它（请求里没有），但总控也要挡住，翻译移植后两个功能的频道不同。
    let elsewhere = ChatLogEvent::Message(ChatMessage {
        listener: ACTIVE.to_owned(),
        channel_id: "player_9".to_owned(),
        channel_name: "Corp".to_owned(),
        time: NOW,
        speaker: "Someone".to_owned(),
        text: "Jita clear".to_owned(),
        is_backfill: false,
    });
    assert!(features.events(vec![elsewhere], NOW).is_empty());
    // 位置线索与预警频道的消息：都给预警，返回预警浮窗要刷新。
    let changed = features.events(
        vec![local(ACTIVE, "Jita", NOW), message(ACTIVE, "Perimeter red", NOW)],
        NOW,
    );
    assert_eq!(changed, BTreeSet::from([OverlayKind::Intel]));
    assert_eq!(features.intel().locations()[ACTIVE].system_id, 30_000_142);
}

/// 活动角色、跟踪状态没变时不报告变化；变了时报告，并更新预警的上下文。
#[test]
fn active_character_and_status_changes() {
    let mut features = features();
    features.apply(&config(), NOW);
    assert!(features.set_active_character(Some(ACTIVE.to_owned()), NOW));
    assert!(!features.set_active_character(Some(ACTIVE.to_owned()), NOW));
    // 跟踪服务每次轮询都可能报同样的状态，没变时不该让浮窗与设置窗口重画。
    let status = ChatLogStatus::DirectoryNotFound("C:\\Chatlogs".to_owned());
    assert!(features.status_changed(status.clone(), NOW));
    assert!(!features.status_changed(status, NOW));
    // 跟踪的日志文件同理：同样的列表再报一次不算变化。
    let followed = vec![FollowedChatChannel {
        listener: ACTIVE.to_owned(),
        channel_id: "local".to_owned(),
        channel_name: Some("Local".to_owned()),
    }];
    assert!(features.followed_changed(followed.clone(), NOW));
    assert!(!features.followed_changed(followed, NOW));
    assert!(features.followed_changed(Vec::new(), NOW));
    assert_eq!(
        features.content(OverlayKind::Intel, NOW).context_key,
        format!("intel:{ACTIVE}")
    );
    // 清空：有活动角色时清它的缓冲。翻译没有移植，清空翻译浮窗什么也不做。
    assert!(features.clear(OverlayKind::Intel));
    assert!(!features.clear(OverlayKind::Translation));
}

/// 按时间的刷新只看可见的浮窗；停止后不再安排。
#[test]
fn next_refresh_only_for_visible_overlays() {
    let mut features = features();
    features.apply(&config(), NOW);
    features.set_active_character(Some(ACTIVE.to_owned()), NOW);
    features.events(vec![message(ACTIVE, "Jita clear", NOW - 5.0)], NOW);
    assert_eq!(features.next_refresh(NOW), None, "浮窗不可见时不刷新");
    // 浮窗显示出来后才安排：年龄文字（「5 秒前」）在下一个整档到来时要换。
    features.set_visible(BTreeSet::from([OverlayKind::Intel]));
    let next = features.next_refresh(NOW).expect("年龄文字会变");
    assert!(next > NOW && next <= NOW + 60.0, "{next}");
    features.stop(NOW);
    assert_eq!(features.next_refresh(NOW), None);
    assert_eq!(features.apply(&config(), NOW), None, "停止后不再要求跟踪");
}
