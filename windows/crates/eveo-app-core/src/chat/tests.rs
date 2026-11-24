// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警控制器的用例，对应 macOS 的 IntelFeedControllerTests：星图数据早到晚到、位置线索、跳数、状态行、
// 只显示活动角色、清空与手动位置、按时间的刷新。夹具是 Core 用例夹具的一小部分（吉他—皮尔米特—新加达里一条线，
// 外加一艘 Sabre），名称与 ID 取自 SDE。人名核对服务在 pilots 模块里另有用例，这里不接（传 None）。

use std::collections::BTreeMap;
use std::sync::Arc;

use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus, ChatMessage, LocationHint, LocationHintSource};
use eveo_core::model::{AppLanguage, ChannelRef, GeneralSettings, Profile};
use eveo_core::overlay::{OverlayEmphasis, OverlayStatusLevel};
use eveo_core::static_data::EveStaticData;

use super::intel::{IntelController, MAX_PENDING_HINTS};
use super::{ChatFeedContext, IntelFormatter, whole_seconds};
use eveo_core::intel::presenter::IntelLineFormatting;
use eveo_core::static_data::jumps::JumpDistance;

/// 星图数据：三个相连的星系与一艘船。
const JSON: &str = r#"{"format":1,"sdeBuild":3720952,"sdeReleaseDate":"2026-11-19T11:07:08Z",
"regions":[{"i":10000002,"n":"The Forge","l":{"zh":"伏尔戈"}}],
"systems":[
{"i":30000142,"n":"Jita","l":{"zh":"吉他"},"s":0.946,"r":10000002},
{"i":30000144,"n":"Perimeter","l":{"zh":"皮尔米特"},"s":0.949,"r":10000002},
{"i":30000145,"n":"New Caldari","l":{"zh":"新加达里"},"s":0.949,"r":10000002}],
"jumps":[[30000142,30000144],[30000144,30000145]],
"shipGroups":[{"i":541,"n":"Interdictor","l":{"zh":"拦截舰"}}],
"ships":[{"i":22456,"g":541,"n":"Sabre","l":{"zh":"剑齿虎级"}}]}"#;

/// 活动角色（虚构）。
pub(super) const ACTIVE: &str = "Kael Doran";
/// 另一个在线角色（虚构）。
pub(super) const OTHER: &str = "Mira Sol";
/// 现在（墙上时钟）。
pub(super) const NOW: f64 = 1_800_000_000.0;

/// 解码夹具。
pub(super) fn data() -> Arc<EveStaticData> {
    Arc::new(EveStaticData::decode(JSON).expect("夹具能解码"))
}

/// 预警开着、有一个频道的配置方案与上下文。
fn context(static_data: Option<Arc<EveStaticData>>) -> ChatFeedContext {
    let mut profile = Profile::make_new("p", "Default");
    profile.intel.enabled = true;
    profile.intel.channels = vec![ChannelRef::new("Intel.North", None)];
    profile.intel.alert_jumps = 1;
    ChatFeedContext {
        profile,
        general: GeneralSettings::default(),
        static_data,
        active_character: Some(ACTIVE.to_owned()),
        chat_log_status: ChatLogStatus::Watching {
            directory: "C:\\Chatlogs".to_owned(),
            followed_files: 2,
        },
        followed_channels: None,
        language: AppLanguage::En,
    }
}

/// 收听者 listener 在 time 收到的一条消息。
pub(super) fn message(listener: &str, text: &str, time: f64) -> ChatLogEvent {
    ChatLogEvent::Message(ChatMessage {
        listener: listener.to_owned(),
        channel_id: "player_1".to_owned(),
        channel_name: "Intel.North".to_owned(),
        time,
        speaker: "Scout".to_owned(),
        text: text.to_owned(),
        is_backfill: false,
    })
}

/// 角色在 time 进入 system 的 Local 频道。
pub(super) fn local(character: &str, system: &str, time: f64) -> ChatLogEvent {
    ChatLogEvent::LocationHint(LocationHint {
        character: character.to_owned(),
        time,
        source: LocationHintSource::LocalChannel,
        text: format!("Channel changed to Local : {system}"),
        is_backfill: false,
    })
}

/// 一行的纯文本。
fn text(line: &eveo_core::overlay::OverlayLine) -> String {
    line.primary.iter().map(|s| s.text.as_str()).collect()
}

/// 有星图数据与位置：情报行有星系、跳数与数量；1 跳以内的敌对是红色强调；状态行写位置与来源。
#[test]
fn content_with_location() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(Some(data())), NOW);
    // 先进 Local 定位在吉他，再收到一条「皮尔米特 2 艘 Sabre」：皮尔米特离吉他 1 跳。
    let changed = intel.ingest(
        vec![
            local(ACTIVE, "Jita", NOW - 90.0),
            message(ACTIVE, "Perimeter 2x sabre", NOW - 30.0),
        ],
        NOW,
    );
    assert!(changed);
    let content = intel.content(NOW);
    assert_eq!(content.context_key, format!("intel:{ACTIVE}"));
    assert_eq!(
        content.title,
        eveo_l10n::intel(AppLanguage::En).overlay_title(ACTIVE)
    );
    // 位置线索不出现在浮窗里，只有一条情报行；行里有星系名与船型名（船名按 SDE 的写法大写）。
    assert_eq!(content.lines.len(), 1);
    let line = text(&content.lines[0]);
    assert!(line.contains("Perimeter"), "{line}");
    assert!(line.contains("Sabre"), "{line}");
    assert_eq!(content.lines[0].emphasis, OverlayEmphasis::Alert);
    // 状态行：位置来自 Local 频道，是说明级别（不是提醒），文字里有星系名。
    let status = content.status.expect("状态行");
    assert_eq!(status.level, OverlayStatusLevel::Info);
    assert!(status.text.contains("Jita"), "{}", status.text);
    // 显示位置的「多久以前」时至少每分钟刷新一次。
    assert!(intel.next_refresh(NOW).is_some_and(|t| t <= NOW + 60.0));
}

/// 星图数据晚到：之前的消息先按纯文本显示，位置线索先存着；数据到了之后重新解析并补上位置。
#[test]
fn static_data_arrives_late() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(None), NOW);
    intel.ingest(
        vec![
            local(ACTIVE, "Jita", NOW - 90.0),
            message(ACTIVE, "Perimeter sabre", NOW - 30.0),
        ],
        NOW,
    );
    // 数据没到：状态行提醒缺星图数据，位置表还是空的（线索没有丢，只是先存着）。
    let before = intel.content(NOW);
    let status = before.status.expect("状态行");
    assert_eq!(status.level, OverlayStatusLevel::Warning);
    assert_eq!(
        status.text,
        eveo_l10n::intel(AppLanguage::En).status_no_static_data()
    );
    assert!(intel.locations().is_empty(), "没有星图数据时位置线索先存着");

    // 数据到了：update 发现 SDE 版本从无到有，重新解析缓冲并补上存着的线索。
    intel.update(context(Some(data())), NOW);
    assert_eq!(intel.static_data_build(), Some(3_720_952));
    assert_eq!(intel.locations()[ACTIVE].system_id, 30_000_142);
    let after = intel.content(NOW);
    // 1 跳：重新解析后有了跳数，按 alert_jumps = 1 是红色强调。
    assert_eq!(after.lines[0].emphasis, OverlayEmphasis::Alert);
}

/// 星图数据到达之前至多存 200 条位置线索，多出的丢掉最旧的。
#[test]
fn pending_hints_are_capped() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(None), NOW);
    // 205 个不同角色各一条线索，时间递增：最旧的 5 条（Pilot 0～4）应被丢掉。
    let hints = (0..MAX_PENDING_HINTS + 5)
        .map(|i| local(&format!("Pilot {i}"), "Jita", NOW - 1_000.0 + i as f64))
        .collect();
    intel.ingest(hints, NOW);
    intel.update(context(Some(data())), NOW);
    assert_eq!(intel.locations().len(), MAX_PENDING_HINTS);
    assert!(!intel.locations().contains_key("Pilot 0"));
}

/// 只显示活动角色收到的消息；换活动角色后换成另一个角色的。清空一个角色只清它的。
#[test]
fn active_character_and_clear() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(Some(data())), NOW);
    intel.ingest(
        vec![
            message(ACTIVE, "Jita clear", NOW - 10.0),
            message(OTHER, "Perimeter red", NOW - 5.0),
        ],
        NOW,
    );
    // 两个角色各收到一条：活动角色只看到自己的那条。
    assert_eq!(intel.content(NOW).lines.len(), 1);
    // 切到另一个角色：context_key 跟着换，浮窗据此重置滚动位置。
    let mut other = context(Some(data()));
    other.active_character = Some(OTHER.to_owned());
    intel.update(other, NOW);
    let content = intel.content(NOW);
    assert_eq!(content.context_key, format!("intel:{OTHER}"));
    assert!(text(&content.lines[0]).contains("Perimeter"));
    // 清空另一个角色的缓冲后它的浮窗为空；活动角色的消息不受影响（这里不再断言，见 clear 的说明）。
    intel.clear(Some(OTHER));
    assert!(intel.content(NOW).lines.is_empty());
    // 没有活动角色：标题是页名，context_key 以冒号结尾（浮窗显示「没有角色」）。
    let mut nobody = context(Some(data()));
    nobody.active_character = None;
    intel.update(nobody, NOW);
    let content = intel.content(NOW);
    assert_eq!(content.context_key, "intel:");
    assert_eq!(intel.next_refresh(NOW), None);
}

/// 超过保留时长的消息在生成内容时清掉。
#[test]
fn old_messages_are_pruned() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(Some(data())), NOW);
    // 默认保留 30 分钟：31 分钟前的一条过期，1 分钟前的一条留下。
    intel.ingest(
        vec![
            message(ACTIVE, "Jita clear", NOW - 31.0 * 60.0),
            message(ACTIVE, "Jita clear", NOW - 60.0),
        ],
        NOW,
    );
    assert_eq!(intel.content(NOW).lines.len(), 1);
}

/// 状态行的顺序：聊天日志目录不在 → 错误；没有频道 → 说明；没有位置也没有参考星系 → 提醒；有参考星系 → 说明。
#[test]
fn status_line_order() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    // 第一档：聊天日志目录不存在时，其余条件都满足也显示错误。
    let mut missing = context(Some(data()));
    missing.chat_log_status = ChatLogStatus::DirectoryNotFound("C:\\Chatlogs".to_owned());
    intel.update(missing, NOW);
    assert_eq!(
        intel.content(NOW).status.unwrap().level,
        OverlayStatusLevel::Error
    );

    // 第二档：目录正常、没有选频道。
    let mut no_channels = context(Some(data()));
    no_channels.profile.intel.channels.clear();
    intel.update(no_channels, NOW);
    let status = intel.content(NOW).status.unwrap();
    assert_eq!(
        status.text,
        eveo_l10n::intel(AppLanguage::En).status_no_channels()
    );

    // 第三档：有频道，但活动角色没有位置记录、也没有设参考星系。
    intel.update(context(Some(data())), NOW);
    let status = intel.content(NOW).status.unwrap();
    assert_eq!(status.level, OverlayStatusLevel::Warning);

    // 第四档：设了参考星系，状态行说明正在用它算跳数。
    let mut reference = context(Some(data()));
    reference.profile.intel.reference_system = Some("New Caldari".to_owned());
    intel.update(reference, NOW);
    let status = intel.content(NOW).status.unwrap();
    assert_eq!(status.level, OverlayStatusLevel::Info);
    assert!(status.text.contains("New Caldari"), "{}", status.text);
}

/// 手动位置：查得到的星系才写；变了时应用层能取走一次要写盘的内容；清除后再取一次是空表。
#[test]
fn manual_location() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(Some(data())), NOW);
    // 查不到的星系名不写；星系名不区分大小写。
    assert!(!intel.set_manual_location(ACTIVE, "Nowhere", NOW));
    assert!(intel.set_manual_location(ACTIVE, "perimeter", NOW));
    let saved = intel.take_manual_locations().expect("手动位置变了");
    assert_eq!(saved[ACTIVE].system_id, 30_000_144);
    assert!(intel.take_manual_locations().is_none(), "只取一次");
    // 清除后要写盘的是空表（不是 None）：state.json 里的旧记录要被覆盖掉。
    assert!(intel.clear_manual_location(ACTIVE, NOW));
    assert_eq!(intel.take_manual_locations(), Some(BTreeMap::new()));
}

/// 停止后不再收事件。
#[test]
fn stopped_controller_ignores_events() {
    let mut intel = IntelController::new(BTreeMap::new(), None);
    intel.update(context(Some(data())), NOW);
    // 退出流程里 stop 之后，尾随的日志事件可能还在路上；它们不能再改缓冲。
    intel.stop(NOW);
    assert!(!intel.ingest(vec![message(ACTIVE, "Jita clear", NOW)], NOW));
}

/// 行里的文字：秒数与分钟数、跳数的几种写法、数量；秒数取整的边界。
#[test]
fn formatter_and_whole_seconds() {
    let formatter = IntelFormatter {
        language: AppLanguage::En,
    };
    let text = eveo_l10n::intel(AppLanguage::En);
    assert_eq!(formatter.age(59), text.age_seconds(59));
    assert_eq!(formatter.age(125), text.age_minutes(2));
    assert_eq!(formatter.jumps(JumpDistance::Jumps(0)), text.jumps_here());
    assert_eq!(formatter.jumps(JumpDistance::Jumps(3)), text.jumps(3));
    assert_eq!(formatter.jumps(JumpDistance::Beyond(15)), text.jumps_beyond(15));
    assert_eq!(formatter.count(4, false), text.count_inferred(4));
    // 时钟回拨得到的负数、NaN 都按 0 秒；极大值截到十亿秒，避免转换溢出。
    assert_eq!(whole_seconds(-3.0), 0);
    assert_eq!(whole_seconds(f64::NAN), 0);
    assert_eq!(whole_seconds(12.9), 12);
    assert_eq!(whole_seconds(1e12), 1_000_000_000);
}
