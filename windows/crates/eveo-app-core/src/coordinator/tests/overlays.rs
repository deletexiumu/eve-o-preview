// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗部分的事件序列用例：打开预警后规划出浮窗与活动角色，结果没变时不再发；翻译浮窗暂不规划；
// 拖动上下文的吸附目标与尺寸上下限；拖动结束与右键菜单改配置。

use eveo_core::geometry::ScreenRect;
use eveo_core::model::AppConfig;
use eveo_core::overlay::OverlayKind;
use eveo_core::overlay::planner::{MAXIMUM_SIZE, MINIMUM_SIZE, OverlayPresentation};

use super::{changed_config, config, mixed_dpi_screens, started, three_characters};
use crate::coordinator::Coordinator;
use crate::event::{Effect, Event, ForegroundOwner, OverlayMenuAction, SettingsPage};

/// 打开预警（可选同时打开翻译）的默认配置。
fn intel_on(translation: bool) -> AppConfig {
    let mut config = config();
    if let Some(profile) = config.active_profile_mut() {
        profile.intel.enabled = true;
        profile.translation.enabled = translation;
    }
    config
}

/// 效果里最后一次浮窗规划：呈现与活动角色。
fn overlays_in(effects: &[Effect]) -> Option<(Vec<OverlayPresentation>, Option<String>)> {
    effects.iter().rev().find_map(|e| match e {
        Effect::ApplyOverlays {
            presentations,
            active_character,
        } => Some((presentations.clone(), active_character.clone())),
        _ => None,
    })
}

/// 打开预警与翻译后第一次规划就有两个浮窗与活动角色；同样的状态再算一次不重复发。
#[test]
fn intel_overlay_is_planned_once() {
    // 启动时还没有客户端：浮窗不可见，活动角色为空，与初始的「上一次」相同，不发效果。
    let mut coordinator = started(intel_on(true), Vec::new());
    // 三个客户端出现：浮窗变成可见，活动角色有了。
    let effects = coordinator.handle(Event::WindowsPolled(three_characters()), 2.0);
    let (presentations, active) = overlays_in(&effects).expect("有客户端后规划浮窗");
    let kinds: Vec<OverlayKind> = presentations.iter().map(|p| p.kind).collect();
    assert_eq!(kinds, vec![OverlayKind::Intel, OverlayKind::Translation]);
    assert!(presentations.iter().all(|p| p.is_visible));
    // 两个浮窗的默认位置不重叠（翻译浮窗排在预警浮窗下面）。
    assert!(!presentations[0].frame.intersects(&presentations[1].frame));
    // 没有前台客户端、也没有最后活动的客户端时，取第一个有角色名的客户端。
    assert_eq!(active.as_deref(), Some("Alpha"));
    let again = coordinator.handle(Event::WindowsPolled(three_characters()), 3.0);
    assert!(overlays_in(&again).is_none(), "结果没变时不再发");
    // 切到 Bravo：活动角色变了，浮窗的内容要跟着换，所以再发一次。
    let effects = coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(102)), 4.0);
    assert_eq!(overlays_in(&effects).unwrap().1.as_deref(), Some("Bravo"));
}

/// 预警关着时没有浮窗；在右键菜单里「隐藏此浮窗」就是关掉预警，浮窗随之去掉。
#[test]
fn hide_turns_the_feature_off() {
    // 应用层收到这个配置变化后会停掉聊天日志的跟踪（总控的请求变成 None）。
    let mut coordinator = started(intel_on(false), three_characters());
    let effects = coordinator.handle(
        Event::OverlayMenu {
            kind: OverlayKind::Intel,
            action: OverlayMenuAction::Hide,
        },
        2.0,
    );
    let config = changed_config(&effects).expect("配置变了");
    assert!(!config.profiles[0].intel.enabled);
    let (presentations, _) = overlays_in(&effects).expect("重新规划");
    assert!(presentations.is_empty());
}

/// 拖动上下文：起点是规划的 frame；吸附目标含三个缩略图与各屏幕；尺寸上下限按 100% 缩放（夹具的屏幕是 100%）。
#[test]
fn drag_context_snaps_to_thumbnails() {
    // 没保存过 frame：规划给的是主屏右上角的默认位置。
    let coordinator = started(intel_on(false), three_characters());
    let planned = coordinator.overlay_presentations()[0].frame;
    let context = coordinator
        .overlay_drag_context(OverlayKind::Intel)
        .expect("预警浮窗在规划里");
    assert_eq!(context.start_frame, planned);
    assert_eq!(context.targets.neighbors.len(), 3);
    assert_eq!(context.minimum_size, MINIMUM_SIZE);
    assert_eq!(context.maximum_size, MAXIMUM_SIZE);
    assert!(context.allows_resize && !context.lock_aspect_ratio);
    assert!(
        coordinator
            .overlay_drag_context(OverlayKind::Translation)
            .is_none()
    );
}

/// 拖动结束写 frame；「恢复默认位置」清掉它；「锁定布局」切换共用的开关；「打开设置…」打开预警页。
#[test]
fn drag_end_and_menu_actions_edit_config() {
    let mut coordinator = started(intel_on(false), three_characters());
    // 一个完全在屏幕内、尺寸在上下限之间的 frame：规划时收进屏幕后不变，能直接比较。
    let frame = ScreenRect::new(100.0, 120.0, 400.0, 300.0);
    let effects = coordinator.handle(
        Event::OverlayDragEnded {
            kind: OverlayKind::Intel,
            frame,
        },
        2.0,
    );
    assert_eq!(
        changed_config(&effects).unwrap().profiles[0].intel.overlay.frame,
        Some(frame)
    );
    assert_eq!(overlays_in(&effects).unwrap().0[0].frame, frame);

    let menu = |action| Event::OverlayMenu {
        kind: OverlayKind::Intel,
        action,
    };
    let effects = coordinator.handle(menu(OverlayMenuAction::ResetFrame), 3.0);
    assert_eq!(
        changed_config(&effects).unwrap().profiles[0].intel.overlay.frame,
        None
    );
    let effects = coordinator.handle(menu(OverlayMenuAction::ToggleLock), 4.0);
    assert!(changed_config(&effects).unwrap().profiles[0].behavior.lock_layout);
    assert!(overlays_in(&effects).unwrap().0[0].is_locked);
    // 「打开设置…」不改配置，只有打开设置窗口这一个效果。
    let effects = coordinator.handle(menu(OverlayMenuAction::OpenSettings), 5.0);
    assert_eq!(effects, vec![Effect::OpenSettings(SettingsPage::Intel)]);
}

/// 只移动到缩放比例不同的屏幕上：宽高按比例换算，看起来与拖动前一样大；在新屏幕上改了尺寸则按像素保存。
#[test]
fn moving_to_a_scaled_screen_keeps_apparent_size() {
    let mut coordinator = Coordinator::new(intel_on(false), mixed_dpi_screens());
    coordinator.handle(Event::Started, 1.0);
    coordinator.handle(Event::WindowsPolled(three_characters()), 1.1);
    // 默认位置在 100% 的主屏右上角，380×260。
    let start = overlays_in_plan(&coordinator);
    assert_eq!((start.width, start.height), (380.0, 260.0));
    // 原样拖到 150% 的副屏：存成 570×390，左上角不动。
    let moved = ScreenRect::new(2200.0, 200.0, start.width, start.height);
    let effects = coordinator.handle(
        Event::OverlayDragEnded {
            kind: OverlayKind::Intel,
            frame: moved,
        },
        2.0,
    );
    let saved = changed_config(&effects).unwrap().profiles[0].intel.overlay.frame;
    assert_eq!(saved, Some(ScreenRect::new(2200.0, 200.0, 570.0, 390.0)));
    // 在副屏上改尺寸：不再换算。
    let resized = ScreenRect::new(2200.0, 200.0, 700.0, 500.0);
    let effects = coordinator.handle(
        Event::OverlayDragEnded {
            kind: OverlayKind::Intel,
            frame: resized,
        },
        3.0,
    );
    assert_eq!(
        changed_config(&effects).unwrap().profiles[0].intel.overlay.frame,
        Some(resized)
    );
}

/// 规划结果里预警浮窗的 frame。
fn overlays_in_plan(coordinator: &Coordinator) -> ScreenRect {
    coordinator
        .overlay_presentations()
        .iter()
        .find(|p| p.kind == OverlayKind::Intel)
        .expect("预警浮窗在规划里")
        .frame
}
