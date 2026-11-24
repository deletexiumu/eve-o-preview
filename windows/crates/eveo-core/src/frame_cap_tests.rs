// SPDX-License-Identifier: GPL-3.0-or-later
//
// 驱动限帧规则的用例：打开、改帧数、关闭的计划，以及用户在 NVIDIA 控制面板里自己改过之后的处理。

use super::*;

/// 驱动的现状：exefile.exe 在 `profile` 里，用户值是 `fps`。
fn state(profile: &str, fps: Option<u32>) -> DriverState {
    DriverState {
        profile: Some(profile.to_owned()),
        user_fps: fps,
    }
}

/// 一条接手预置配置文件的记录。
fn record(profile: &str, original: Option<u32>, applied: u32) -> OwnershipRecord {
    OwnershipRecord {
        profile: profile.to_owned(),
        created_profile: false,
        original_fps: original,
        applied_fps: applied,
    }
}

/// 驱动里没有 exefile.exe：新建自己的配置文件再设值；关闭时整个删掉。
#[test]
fn creates_and_deletes_own_profile() {
    let plan = plan_enable(&DriverState::default(), None, 60);
    assert_eq!(plan.steps, vec![Step::CreateOwnProfile, Step::SetFps(60)]);
    let saved = plan.record.expect("记录");
    assert!(saved.created_profile);
    assert_eq!(saved.profile, OWN_PROFILE_NAME);

    let off = plan_disable(&state(OWN_PROFILE_NAME, Some(60)), Some(&saved));
    assert_eq!(off.steps, vec![Step::DeleteOwnProfile]);
    assert_eq!(off.record, None);
}

/// 预置配置文件上原来没有用户值：接手时记下 None，关闭时删掉我们的值。
#[test]
fn takes_over_predefined_profile_without_value() {
    let plan = plan_enable(&state("EVE Online", None), None, 60);
    assert_eq!(plan.steps, vec![Step::SetFps(60)]);
    let saved = plan.record.expect("记录");
    assert_eq!(saved, record("EVE Online", None, 60));

    let off = plan_disable(&state("EVE Online", Some(60)), Some(&saved));
    assert_eq!(off.steps, vec![Step::DeleteFps]);
}

/// 用户原来自己设过 144：关闭时还原成 144。
#[test]
fn restores_users_own_value() {
    let plan = plan_enable(&state("EVE Online", Some(144)), None, 60);
    let saved = plan.record.expect("记录");
    assert_eq!(saved.original_fps, Some(144));
    let off = plan_disable(&state("EVE Online", Some(60)), Some(&saved));
    assert_eq!(off.steps, vec![Step::SetFps(144)]);
}

/// 改帧数：沿用记录里接手前的值，不把自己上次写的 60 当成原值。
#[test]
fn changing_fps_keeps_original() {
    let first = record("EVE Online", Some(144), 60);
    let plan = plan_enable(&state("EVE Online", Some(60)), Some(&first), 45);
    assert_eq!(plan.steps, vec![Step::SetFps(45)]);
    assert_eq!(plan.record, Some(record("EVE Online", Some(144), 45)));
}

/// 启动时核对：驱动里已经是想要的值，不写驱动。
#[test]
fn startup_check_skips_write_when_already_set() {
    let first = record("EVE Online", None, 60);
    let plan = plan_enable(&state("EVE Online", Some(60)), Some(&first), 60);
    assert!(plan.steps.is_empty());
    assert_eq!(plan.record, Some(first));
}

/// 用户之后在 NVIDIA 控制面板里改成了 90：关闭时不动驱动，只丢掉记录。
#[test]
fn disable_respects_later_user_change() {
    let saved = record("EVE Online", None, 60);
    let off = plan_disable(&state("EVE Online", Some(90)), Some(&saved));
    assert!(off.steps.is_empty());
    assert_eq!(off.record, None);
}

/// exefile.exe 换了配置文件（驱动更新）：关闭时不动驱动；再打开时按新配置文件重新接手。
#[test]
fn profile_moved_by_driver_update() {
    let saved = record("Old", None, 60);
    let moved = state("New", Some(30));
    assert!(plan_disable(&moved, Some(&saved)).steps.is_empty());
    let plan = plan_enable(&moved, Some(&saved), 60);
    assert_eq!(plan.record, Some(record("New", Some(30), 60)));
}

/// 记录丢了但驱动里有我们的配置文件：仍按新建处理，关闭时删掉。
#[test]
fn own_profile_without_record_is_still_ours() {
    let plan = plan_enable(&state(OWN_PROFILE_NAME, Some(60)), None, 60);
    assert!(plan.steps.is_empty());
    assert!(plan.record.expect("记录").created_profile);
}

/// 没有记录时关闭什么都不做。
#[test]
fn disable_without_record_does_nothing() {
    let off = plan_disable(&state("EVE Online", Some(60)), None);
    assert!(off.steps.is_empty());
    assert_eq!(off.record, None);
}

/// 设置：关闭时不写驱动；帧数夹到范围内；键缺失时取默认值。
#[test]
fn settings_desired_fps_and_defaults() {
    let mut settings = FrameCapSettings::default();
    assert_eq!(settings.desired_fps(), None);
    settings.enabled = true;
    assert_eq!(settings.desired_fps(), Some(60));
    settings.fps = 5_000;
    assert_eq!(settings.desired_fps(), Some(1000));
    settings.fps = 0;
    assert_eq!(settings.desired_fps(), Some(10));
    let decoded: FrameCapSettings = serde_json::from_str(r#"{"enabled": true, "fps": null}"#).expect("解码");
    assert_eq!(decoded.fps, DEFAULT_FPS);
}

/// 记录文件：编码再解码不变；内容不对时当作没有记录。
#[test]
fn record_round_trip() {
    let saved = record("EVE Online", Some(144), 60);
    assert_eq!(OwnershipRecord::decode(&saved.encode()), Some(saved));
    assert_eq!(OwnershipRecord::decode(b"not json"), None);
    let text = String::from_utf8(record("P", None, 60).encode()).expect("UTF-8");
    assert!(text.contains("\"appliedFps\": 60"));
}

/// 状态：检测中与不是 NVIDIA 时开关不能拨。
#[test]
fn status_availability() {
    assert!(!FrameCapStatus::Checking.is_available());
    assert!(!FrameCapStatus::NotNvidia.is_available());
    assert!(FrameCapStatus::Ready.is_available());
    assert!(FrameCapStatus::NeedsAdmin.is_available());
}

/// 配置校验：越界的帧数夹到范围并记下路径；没有这个键时不出现在编码结果里（两端共用的用例不受影响）。
#[test]
fn validator_clamps_fps_and_omits_missing_key() {
    let mut config = crate::model::AppConfig::make_default("p1");
    let normalized = crate::config::normalized(config.clone());
    assert!(!normalized.clamped.iter().any(|p| p.contains("frameCap")));
    let encoded = serde_json::to_string(&normalized.config).expect("编码");
    assert!(!encoded.contains("frameCap"));

    config.general.frame_cap = Some(FrameCapSettings {
        enabled: true,
        fps: 2_000,
    });
    let normalized = crate::config::normalized(config);
    assert_eq!(normalized.config.general.frame_cap.expect("设置").fps, 1000);
    assert!(normalized.clamped.contains(&"general.frameCap.fps".to_owned()));
}

/// 状态码与成功后的状态。
#[test]
fn status_from_results() {
    assert_eq!(FrameCapStatus::from_error(-2), FrameCapStatus::NotNvidia);
    assert_eq!(FrameCapStatus::from_error(-6), FrameCapStatus::NotNvidia);
    assert_eq!(FrameCapStatus::from_error(-137), FrameCapStatus::NeedsAdmin);
    assert_eq!(FrameCapStatus::from_error(-1), FrameCapStatus::Failed(-1));
    let set = state("EVE Online", Some(60));
    assert_eq!(
        FrameCapStatus::after_success(Some(60), &set),
        FrameCapStatus::Applied(60)
    );
    assert_eq!(
        FrameCapStatus::after_success(Some(30), &set),
        FrameCapStatus::Failed(-1)
    );
    assert_eq!(FrameCapStatus::after_success(None, &set), FrameCapStatus::Ready);
}
