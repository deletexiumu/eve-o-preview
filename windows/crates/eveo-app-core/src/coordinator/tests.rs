// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的事件序列测试：每个用例按真实顺序送事件，只核对效果与可查询的状态，不碰任何系统接口。

use eveo_core::geometry::{ScreenInfo, ScreenRect};
use eveo_core::hotkeys::HotkeyAction;
use eveo_core::model::{AppConfig, CycleGroup, Pid, WindowId, WindowInfo};
use eveo_core::planning::{FrontmostContext, ThumbnailStatus};
use eveo_core::switching::CycleDirection;

use super::Coordinator;

// 战斗提醒（游戏日志的启停与受击事件）的用例放在子模块里，共用这里的夹具。
mod combat;
// 预警与翻译浮窗的规划、拖动与右键菜单。
mod overlays;
use crate::event::{ContextMenuAction, Effect, Event, ForegroundOwner, SettingsPage, TrayAction};

// MARK: 夹具

/// 一个客户端主窗口。标题为 `EVE` 时是登录界面。
fn window(id: u64, pid: Pid, title: &str) -> WindowInfo {
    WindowInfo {
        window_id: WindowId(id),
        pid,
        title: Some(title.to_owned()),
        frame: ScreenRect::new(0.0, 0.0, 1280.0, 720.0),
        is_on_screen: true,
        is_minimized: Some(false),
        is_full_screen: Some(false),
    }
}

/// 一块 1920×1080 的主屏，底部 40 点是任务栏。
fn screens() -> Vec<ScreenInfo> {
    vec![ScreenInfo {
        frame: ScreenRect::new(0.0, 0.0, 1920.0, 1080.0),
        visible_frame: ScreenRect::new(0.0, 0.0, 1920.0, 1040.0),
        scale: 1.0,
        size_scale: 1.0,
        is_main: true,
    }]
}

/// 默认配置，配置方案 id 固定为 `P1`。
fn config() -> AppConfig {
    AppConfig::make_default("P1")
}

/// 三个角色客户端 Alpha、Bravo、Charlie（窗口 1～3，PID 101～103）。
fn three_characters() -> Vec<WindowInfo> {
    vec![
        window(1, 101, "EVE - Alpha"),
        window(2, 102, "EVE - Bravo"),
        window(3, 103, "EVE - Charlie"),
    ]
}

/// 建协调器、启动、轮询一次，返回协调器。
fn started(config: AppConfig, windows: Vec<WindowInfo>) -> Coordinator {
    let mut coordinator = Coordinator::new(config, screens());
    coordinator.handle(Event::Started, 1.0);
    coordinator.handle(Event::WindowsPolled(windows), 1.1);
    coordinator
}

/// 效果里激活的窗口。
fn activated(effects: &[Effect]) -> Vec<WindowId> {
    effects
        .iter()
        .filter_map(|e| match e {
            Effect::Activate(id) => Some(*id),
            _ => None,
        })
        .collect()
}

/// 效果里最后一次呈现中某窗口是否可见；没有呈现效果时返回 `None`。
fn visible_in(effects: &[Effect], id: u64) -> Option<bool> {
    effects.iter().rev().find_map(|e| match e {
        Effect::ApplyPresentations { presentations, .. } => presentations
            .iter()
            .find(|p| p.id == WindowId(id))
            .map(|p| p.is_visible),
        _ => None,
    })
}

/// 效果里最后一份配置。
fn changed_config(effects: &[Effect]) -> Option<&AppConfig> {
    effects.iter().rev().find_map(|e| match e {
        Effect::ConfigChanged(config) => Some(config),
        _ => None,
    })
}

/// 带一个循环组的配置：成员 Alpha、Bravo、Charlie，前进 ctrl+F13，后退 ctrl+shift+F13。
fn config_with_cycle_group() -> AppConfig {
    let mut config = config();
    config.profiles[0].cycle_groups.push(CycleGroup {
        id: "G1".to_owned(),
        name: "舰队".to_owned(),
        forward_hotkeys: vec!["ctrl+F13".to_owned()],
        backward_hotkeys: vec!["ctrl+shift+F13".to_owned()],
        members: vec!["Alpha".to_owned(), "Bravo".to_owned(), "Charlie".to_owned()],
    });
    config
}

/// 当前规划里某个循环动作的绑定 id。
fn cycle_binding(coordinator: &Coordinator, direction: CycleDirection) -> u32 {
    coordinator
        .hotkey_plan()
        .bindings
        .iter()
        .find(|b| {
            b.action
                == HotkeyAction::Cycle {
                    group_id: "G1".to_owned(),
                    direction,
                }
        })
        .map(|b| b.id)
        .expect("循环组的热键已规划")
}

// MARK: 启动与轮询

#[test]
/// 启动：先注册热键，再告诉热键服务前台不是游戏，然后要求立即枚举一次窗口，最后做第一次规划。
/// 这个顺序保证第一轮枚举回来前热键已经可用。
fn start_registers_hotkeys_tells_foreground_and_polls() {
    let mut coordinator = Coordinator::new(config(), screens());
    let effects = coordinator.handle(Event::Started, 0.0);
    assert!(matches!(effects[0], Effect::RegisterHotkeys(_)));
    assert_eq!(effects[1], Effect::SetGameForeground(false));
    assert_eq!(effects[2], Effect::PollNow);
    // 还没有客户端，第一次规划给出空的呈现。
    assert!(
        matches!(&effects[3], Effect::ApplyPresentations { presentations, .. } if presentations.is_empty())
    );
}

#[test]
/// 第一次轮询发现客户端：缩略图全部可见，自动排位的结果只写一次配置。
/// 第二次相同的轮询不应产生任何效果，否则每秒的兜底轮询都会刷新缩略图窗口与写盘。
fn first_poll_shows_clients_and_persists_auto_layouts_once() {
    let mut coordinator = Coordinator::new(config(), screens());
    coordinator.handle(Event::Started, 0.0);
    let effects = coordinator.handle(Event::WindowsPolled(three_characters()), 0.1);
    assert_eq!(visible_in(&effects, 1), Some(true));
    assert_eq!(visible_in(&effects, 3), Some(true));
    let saved = changed_config(&effects).expect("自动排位写进配置");
    assert_eq!(saved.profiles[0].layouts.len(), 3);
    // 同样的窗口再轮询一次：什么都没变，不发任何效果。
    let again = coordinator.handle(Event::WindowsPolled(three_characters()), 1.1);
    assert!(again.is_empty(), "{again:?}");
}

#[test]
/// 客户端消失时，它的悬停、缩略图状态等会话状态一并清掉，不留下永远不清的条目。
fn removed_client_clears_its_session_state() {
    let mut coordinator = started(config(), three_characters());
    coordinator.handle(
        Event::HoverChanged {
            id: WindowId(2),
            hovering: true,
        },
        2.0,
    );
    coordinator.handle(
        Event::ThumbnailStatusChanged {
            id: WindowId(2),
            status: ThumbnailStatus::Shown,
        },
        2.1,
    );
    assert_eq!(coordinator.session().hovered_window, Some(WindowId(2)));
    let remaining = vec![window(1, 101, "EVE - Alpha"), window(3, 103, "EVE - Charlie")];
    coordinator.handle(Event::WindowsPolled(remaining), 3.0);
    assert_eq!(coordinator.session().hovered_window, None);
    assert_eq!(coordinator.registry().clients().len(), 2);
}

#[test]
/// 已消失或从未登记的窗口报来的缩略图状态直接忽略，不触发重算。
fn status_of_unknown_window_is_ignored() {
    let mut coordinator = started(config(), three_characters());
    let effects = coordinator.handle(
        Event::ThumbnailStatusChanged {
            id: WindowId(99),
            status: ThumbnailStatus::Failed,
        },
        2.0,
    );
    assert!(effects.is_empty());
}

// MARK: 前台

#[test]
/// 客户端到前台时启用 game 热键并记为最近活动的客户端；设置窗口到前台时停用 game 热键，
/// 但仍算在 EVE 环境内（更新 last_eve_context_at），最近活动的客户端保留，循环起点不丢。
fn foreground_client_enables_game_hotkeys_and_becomes_active() {
    let mut coordinator = started(config(), three_characters());
    let effects = coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(102)), 2.0);
    assert!(effects.contains(&Effect::SetGameForeground(true)));
    assert_eq!(coordinator.frontmost(), FrontmostContext::Client(102));
    assert_eq!(coordinator.session().last_active_pid, Some(102));
    // 设置窗口到前台：仍在 EVE 环境内，但 game 热键停用；最近活动的客户端保留。
    let effects = coordinator.handle(Event::ForegroundChanged(ForegroundOwner::SelfApp), 3.0);
    assert!(effects.contains(&Effect::SetGameForeground(false)));
    assert_eq!(coordinator.session().last_active_pid, Some(102));
    assert!((coordinator.session().last_eve_context_at - 3.0).abs() < f64::EPSILON);
}

#[test]
/// 活动角色（「统一尺寸」的「按活动客户端」用）：前台客户端的角色；切到设置窗口后仍是它；
/// 活动的是登录界面时为 None。
fn active_character_follows_highlight_rule() {
    let mut windows = three_characters();
    windows.push(window(4, 104, "EVE"));
    let mut coordinator = started(config(), windows);
    // 启动后还没有客户端到过前台。
    assert_eq!(coordinator.active_character(), None);
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(102)), 2.0);
    assert_eq!(coordinator.active_character(), Some("Bravo"));
    // 用户切到设置窗口去按按钮：仍是刚才的 Bravo。
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::SelfApp), 3.0);
    assert_eq!(coordinator.active_character(), Some("Bravo"));
    // 登录界面没有角色名。
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(104)), 4.0);
    assert_eq!(coordinator.active_character(), None);
}

#[test]
/// 前台是不认识的进程（例如浏览器）时按「其他应用」处理。
fn unknown_process_in_foreground_is_other() {
    let mut coordinator = started(config(), three_characters());
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(555)), 2.0);
    assert_eq!(coordinator.frontmost(), FrontmostContext::Other);
}

#[test]
/// WinEvent 的前台事件可能比轮询先到：此时进程还不是已知客户端，按其他应用处理；
/// 下一轮轮询登记了它之后，按保存的前台归属重新换算成该客户端。
fn foreground_reported_before_client_is_known_resolves_after_poll() {
    let mut coordinator = Coordinator::new(config(), screens());
    coordinator.handle(Event::Started, 0.0);
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(101)), 0.1);
    assert_eq!(coordinator.frontmost(), FrontmostContext::Other);
    coordinator.handle(Event::WindowsPolled(three_characters()), 0.2);
    assert_eq!(coordinator.frontmost(), FrontmostContext::Client(101));
}

#[test]
/// 「离开 EVE 时隐藏」：延迟从离开的那一刻算起（11 秒离开、延迟 1 秒，12 秒唤醒），
/// 唤醒后缩略图隐藏，且不再安排新的唤醒。
fn hide_when_eve_not_frontmost_schedules_wake_from_the_moment_of_leaving() {
    let mut config = config();
    config.profiles[0].behavior.hide_when_eve_not_frontmost = true;
    config.profiles[0].behavior.hide_delay_seconds = 1.0;
    let mut coordinator = started(config, three_characters());
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(101)), 10.0);
    let effects = coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(555)), 11.0);
    assert!(effects.contains(&Effect::ScheduleWake(Some(12.0))), "{effects:?}");
    // 延迟期间仍可见（呈现没变，所以不发 ApplyPresentations，只看最近一次规划）。
    assert!(coordinator.last_plan().presentations.iter().all(|p| p.is_visible));
    let effects = coordinator.handle(Event::Wake, 12.0);
    assert_eq!(visible_in(&effects, 2), Some(false));
    // 唤醒已经发生，不再安排新的。
    assert!(!effects.iter().any(|e| matches!(e, Effect::ScheduleWake(Some(_)))));
}

// MARK: 热键

#[test]
/// 循环组从当前前台的角色出发：前进到下一个成员，后退时绕回到最后一个成员。
fn cycle_forward_and_backward_from_the_active_character() {
    let mut coordinator = started(config_with_cycle_group(), three_characters());
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(101)), 2.0);
    let forward = cycle_binding(&coordinator, CycleDirection::Forward);
    let backward = cycle_binding(&coordinator, CycleDirection::Backward);
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(forward), 2.1)),
        vec![WindowId(2)]
    );
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(backward), 2.2)),
        vec![WindowId(3)]
    );
}

#[test]
/// 循环只在在线且未被跳过的成员之间进行；只剩活动角色自己时激活它自己（与上游一致）。
fn cycle_skips_offline_and_skipped_members() {
    let windows = vec![window(1, 101, "EVE - Alpha"), window(3, 103, "EVE - Charlie")];
    let mut coordinator = started(config_with_cycle_group(), windows);
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(101)), 2.0);
    let forward = cycle_binding(&coordinator, CycleDirection::Forward);
    // Bravo 离线，直接到 Charlie。
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(forward), 2.1)),
        vec![WindowId(3)]
    );
    // 跳过 Charlie 后只剩活动的 Alpha 自己。
    coordinator.handle(
        Event::ContextMenu {
            id: WindowId(3),
            action: ContextMenuAction::ToggleSkip,
        },
        2.2,
    );
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(forward), 2.3)),
        vec![WindowId(1)]
    );
}

#[test]
/// 没有活动客户端时从组的第一个成员开始；前台离开 EVE 后，以最近一次在前台的客户端为起点。
fn cycle_starts_from_first_member_after_leaving_eve_uses_last_active() {
    let mut coordinator = started(config_with_cycle_group(), three_characters());
    let forward = cycle_binding(&coordinator, CycleDirection::Forward);
    // 从没有活动客户端：从第一个成员开始。
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(forward), 2.0)),
        vec![WindowId(1)]
    );
    // 前台离开 EVE 后，起点是最近一次处于前台的客户端。
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(102)), 3.0);
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Nobody), 4.0);
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(forward), 4.1)),
        vec![WindowId(3)]
    );
}

#[test]
/// 登录客户端按 PID 升序循环，与缩略图的层叠顺序一致；角色客户端不参与。
fn login_clients_cycle_by_pid() {
    let windows = vec![
        window(7, 300, "EVE"),
        window(8, 200, "EVE"),
        window(1, 101, "EVE - Alpha"),
    ];
    let mut config = config();
    config.profiles[0].hotkeys.cycle_login_clients = vec!["ctrl+F14".to_owned()];
    let mut coordinator = started(config, windows);
    let id = coordinator
        .hotkey_plan()
        .bindings
        .iter()
        .find(|b| b.action == HotkeyAction::CycleLoginClients)
        .map(|b| b.id)
        .unwrap();
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(id), 2.0)),
        vec![WindowId(8)]
    );
    coordinator.handle(Event::ForegroundChanged(ForegroundOwner::Process(200)), 2.1);
    assert_eq!(
        activated(&coordinator.handle(Event::HotkeyFired(id), 2.2)),
        vec![WindowId(7)]
    );
}

#[test]
/// 不在当前规划里的绑定 id（例如上一代残留的消息）不执行任何动作。
fn unknown_hotkey_id_does_nothing() {
    let mut coordinator = started(config(), three_characters());
    assert!(coordinator.handle(Event::HotkeyFired(999), 2.0).is_empty());
}

#[test]
/// 与热键无关的配置修改不重新注册热键；加了循环组、规划变了才重新注册。
fn unchanged_hotkey_plan_is_not_reregistered_on_config_change() {
    let mut coordinator = started(config(), three_characters());
    let mut edited = coordinator.config().clone();
    edited.profiles[0].thumbnail.opacity = 0.9;
    let effects = coordinator.handle(Event::ConfigEdited(edited), 2.0);
    assert!(!effects.iter().any(|e| matches!(e, Effect::RegisterHotkeys(_))));
    assert!(changed_config(&effects).is_some());
    // 加一个循环组：规划变了，重新注册。
    let mut edited = coordinator.config().clone();
    edited.profiles[0].cycle_groups = config_with_cycle_group().profiles[0].cycle_groups.clone();
    let effects = coordinator.handle(Event::ConfigEdited(edited), 3.0);
    assert!(
        effects
            .iter()
            .any(|e| matches!(e, Effect::RegisterHotkeys(b) if b.len() >= 2))
    );
}

#[test]
/// 设置窗口送来与当前相同的配置时什么也不做，不写盘也不重算。
fn identical_config_edit_is_ignored() {
    let mut coordinator = started(config(), three_characters());
    let same = coordinator.config().clone();
    assert!(coordinator.handle(Event::ConfigEdited(same), 2.0).is_empty());
}

// MARK: 缩略图动作

#[test]
/// 左键点缩略图激活、Ctrl+左键最小化；点到已消失的客户端时忽略。
fn click_activates_and_ctrl_click_minimizes_known_clients_only() {
    let mut coordinator = started(config(), three_characters());
    assert_eq!(
        coordinator.handle(Event::ThumbnailClicked(WindowId(2)), 2.0),
        vec![Effect::Activate(WindowId(2))]
    );
    assert_eq!(
        coordinator.handle(Event::ThumbnailMinimizeRequested(WindowId(3)), 2.1),
        vec![Effect::Minimize(WindowId(3))]
    );
    assert!(
        coordinator
            .handle(Event::ThumbnailClicked(WindowId(42)), 2.2)
            .is_empty()
    );
}

#[test]
/// 相邻缩略图之间移动时，新缩略图的进入事件可能先于旧缩略图的离开事件到达；
/// 离开只清掉自己的悬停，不覆盖新的悬停。
fn hover_leave_only_clears_own_hover() {
    let mut coordinator = started(config(), three_characters());
    coordinator.handle(
        Event::HoverChanged {
            id: WindowId(1),
            hovering: true,
        },
        2.0,
    );
    coordinator.handle(
        Event::HoverChanged {
            id: WindowId(2),
            hovering: true,
        },
        2.1,
    );
    coordinator.handle(
        Event::HoverChanged {
            id: WindowId(1),
            hovering: false,
        },
        2.2,
    );
    assert_eq!(coordinator.session().hovered_window, Some(WindowId(2)));
}

#[test]
/// 拖动角色缩略图：松开时保存位置；尺寸与默认尺寸相差不到半点时宽高存 None，
/// 以后改默认尺寸时这个缩略图跟着变；改过尺寸的存下宽高。
fn drag_saves_character_layout_with_default_size_as_none() {
    let mut coordinator = started(config(), three_characters());
    coordinator.handle(Event::DragBegan(WindowId(1)), 2.0);
    assert!(coordinator.session().interacting_windows.contains(&WindowId(1)));
    let effects = coordinator.handle(
        Event::DragEnded {
            id: WindowId(1),
            frame: ScreenRect::new(500.0, 300.0, 384.2, 216.0),
        },
        2.5,
    );
    let layout = &changed_config(&effects).unwrap().profiles[0].layouts["Alpha"];
    assert_eq!(
        (layout.x, layout.y, layout.width, layout.height),
        (500.0, 300.0, None, None)
    );
    assert!(coordinator.session().interacting_windows.is_empty());
    // 改了尺寸的存下宽高。
    let effects = coordinator.handle(
        Event::DragEnded {
            id: WindowId(2),
            frame: ScreenRect::new(10.0, 20.0, 480.0, 270.0),
        },
        3.0,
    );
    let layout = &changed_config(&effects).unwrap().profiles[0].layouts["Bravo"];
    assert_eq!((layout.width, layout.height), (Some(480.0), Some(270.0)));
}

#[test]
/// 拖动登录客户端：保存的是层叠起点 loginPosition，要扣掉这个客户端的层叠偏移。
fn drag_of_login_client_saves_login_position_minus_cascade() {
    let windows = vec![window(7, 300, "EVE"), window(8, 200, "EVE")];
    let mut coordinator = started(config(), windows);
    // PID 300 是第二个登录客户端，层叠偏移 1 × 24。
    let effects = coordinator.handle(
        Event::DragEnded {
            id: WindowId(7),
            frame: ScreenRect::new(124.0, 224.0, 384.0, 216.0),
        },
        2.0,
    );
    let position = changed_config(&effects).unwrap().profiles[0].login_position;
    assert_eq!((position.x, position.y), (100.0, 200.0));
}

#[test]
/// 悬停放大时开始拖动：起点是未放大的基准 frame，边缘判断用放大后的 frame；
/// 吸附目标是其他可见缩略图与屏幕（每块屏幕贡献整屏与可用范围两个矩形）。
fn drag_context_uses_unzoomed_frame_and_other_visible_thumbnails() {
    let mut config = config();
    config.profiles[0].thumbnail.zoom_enabled = true;
    config.profiles[0].thumbnail.zoom_factor = 2;
    let mut coordinator = started(config, three_characters());
    coordinator.handle(
        Event::HoverChanged {
            id: WindowId(1),
            hovering: true,
        },
        2.0,
    );
    let context = coordinator.drag_context(WindowId(1)).unwrap();
    assert!((context.edge_frame.width - context.start_frame.width * 2.0).abs() < 1e-9);
    assert_eq!(context.targets.neighbors.len(), 2);
    assert_eq!(context.targets.screens.len(), 2);
    assert!(context.allows_resize);
    assert!(coordinator.drag_context(WindowId(42)).is_none());
}

#[test]
/// 拖动中缩略图被隐藏（例如按了全部隐藏）：清掉交互状态，否则以后规划给的 frame 永远不会应用。
fn hidden_thumbnail_drops_drag_state() {
    let mut coordinator = started(config(), three_characters());
    coordinator.handle(Event::DragBegan(WindowId(1)), 2.0);
    coordinator.handle(Event::Tray(TrayAction::ToggleHideAll), 2.1);
    assert!(coordinator.session().interacting_windows.is_empty());
}

// MARK: 右键菜单

#[test]
/// 右键菜单：登录客户端没有角色名，按角色的动作无效；角色客户端可恢复默认尺寸、隐藏，
/// 隐藏会写进配置并让缩略图消失；「设置」打开预览与布局页。
fn context_menu_model_and_character_actions() {
    let windows = vec![window(1, 101, "EVE - Alpha"), window(7, 300, "EVE")];
    let mut coordinator = started(config(), windows);
    let login = coordinator.context_menu(WindowId(7)).unwrap();
    assert_eq!(login.character_name, None);
    // 按角色的动作对登录客户端无效。
    assert!(
        coordinator
            .handle(
                Event::ContextMenu {
                    id: WindowId(7),
                    action: ContextMenuAction::Hide
                },
                2.0
            )
            .is_empty()
    );

    coordinator.handle(
        Event::DragEnded {
            id: WindowId(1),
            frame: ScreenRect::new(0.0, 0.0, 600.0, 400.0),
        },
        2.1,
    );
    assert!(coordinator.context_menu(WindowId(1)).unwrap().has_custom_size);
    coordinator.handle(
        Event::ContextMenu {
            id: WindowId(1),
            action: ContextMenuAction::ResetSize,
        },
        2.2,
    );
    assert!(!coordinator.context_menu(WindowId(1)).unwrap().has_custom_size);

    let effects = coordinator.handle(
        Event::ContextMenu {
            id: WindowId(1),
            action: ContextMenuAction::Hide,
        },
        2.3,
    );
    assert_eq!(
        changed_config(&effects).unwrap().profiles[0].hidden_characters,
        vec!["Alpha".to_owned()]
    );
    assert_eq!(visible_in(&effects, 1), Some(false));

    let effects = coordinator.handle(
        Event::ContextMenu {
            id: WindowId(1),
            action: ContextMenuAction::OpenSettings,
        },
        2.4,
    );
    assert_eq!(effects, vec![Effect::OpenSettings(SettingsPage::Previews)]);
}

#[test]
/// 最小化全部：按客户端登记的顺序给每个客户端发一个最小化。
fn minimize_all_minimizes_every_client_in_order() {
    let mut coordinator = started(config(), three_characters());
    let effects = coordinator.handle(
        Event::ContextMenu {
            id: WindowId(2),
            action: ContextMenuAction::MinimizeAll,
        },
        2.0,
    );
    assert_eq!(
        effects,
        vec![
            Effect::Minimize(WindowId(1)),
            Effect::Minimize(WindowId(2)),
            Effect::Minimize(WindowId(3))
        ]
    );
}

// MARK: 托盘

#[test]
/// 托盘切换配置方案：不存在的 id 忽略；切换成功后清空本次会话的跳过名单，托盘状态跟着更新。
fn switching_profile_clears_skips_and_ignores_unknown_ids() {
    let mut config = config();
    let mut second = config.profiles[0].clone();
    second.id = "P2".to_owned();
    second.name = "第二套".to_owned();
    config.profiles.push(second);
    let mut coordinator = started(config, three_characters());
    coordinator.handle(
        Event::ContextMenu {
            id: WindowId(1),
            action: ContextMenuAction::ToggleSkip,
        },
        2.0,
    );
    assert!(coordinator.context_menu(WindowId(1)).unwrap().is_skipped);
    assert!(
        coordinator
            .handle(Event::Tray(TrayAction::SwitchProfile("nope".to_owned())), 2.1)
            .is_empty()
    );
    let effects = coordinator.handle(Event::Tray(TrayAction::SwitchProfile("P2".to_owned())), 2.2);
    assert_eq!(changed_config(&effects).unwrap().active_profile_id, "P2");
    assert!(coordinator.session().skipped_characters.is_empty());
    let tray = coordinator.tray();
    assert_eq!(tray.active_profile_id, "P2");
    assert_eq!(tray.profiles.len(), 2);
    assert_eq!(tray.client_count, 3);
}

#[test]
/// 全部隐藏是开关：第一次隐藏全部缩略图，第二次恢复。
fn hide_all_hides_every_thumbnail() {
    let mut coordinator = started(config(), three_characters());
    let effects = coordinator.handle(Event::Tray(TrayAction::ToggleHideAll), 2.0);
    assert_eq!(visible_in(&effects, 1), Some(false));
    assert!(coordinator.tray().hide_all);
    let effects = coordinator.handle(Event::Tray(TrayAction::ToggleHideAll), 2.1);
    assert_eq!(visible_in(&effects, 1), Some(true));
}

#[test]
/// 退出后协调器不再处理任何事件，避免退出过程中重建刚要销毁的缩略图窗口。
fn quit_stops_processing() {
    let mut coordinator = started(config(), three_characters());
    assert_eq!(
        coordinator.handle(Event::Tray(TrayAction::Quit), 2.0),
        vec![Effect::Quit]
    );
    assert!(coordinator.is_stopped());
    assert!(
        coordinator
            .handle(Event::ThumbnailClicked(WindowId(1)), 2.1)
            .is_empty()
    );
    assert!(
        coordinator
            .handle(Event::Tray(TrayAction::OpenSettings), 2.2)
            .is_empty()
    );
}

#[test]
/// 从托盘打开设置时落在「通用」页。
fn open_settings_from_tray_lands_on_general() {
    let mut coordinator = started(config(), three_characters());
    assert_eq!(
        coordinator.handle(Event::Tray(TrayAction::OpenSettings), 2.0),
        vec![Effect::OpenSettings(SettingsPage::General)]
    );
}

#[test]
/// 拔掉显示器后缩略图被拉回屏幕内，但拉回的位置不写回配置，插回显示器后仍回到原位。
fn screens_change_replans_layout() {
    let mut coordinator = started(config(), three_characters());
    let small = vec![ScreenInfo {
        frame: ScreenRect::new(0.0, 0.0, 800.0, 600.0),
        visible_frame: ScreenRect::new(0.0, 0.0, 800.0, 560.0),
        scale: 1.0,
        size_scale: 1.0,
        is_main: true,
    }];
    let effects = coordinator.handle(Event::ScreensChanged(small), 2.0);
    // 换了屏幕后位置可能被拉回屏幕内；至少要重新发呈现或什么都没变，但不能改写已保存的布局。
    assert!(changed_config(&effects).is_none());
}

// MARK: 混合缩放

/// 左边 1920×1080 的主屏（100%），右边 2560×1600 的副屏（150%）。全局坐标是物理像素。
fn mixed_dpi_screens() -> Vec<ScreenInfo> {
    vec![
        ScreenInfo {
            frame: ScreenRect::new(0.0, 0.0, 1920.0, 1080.0),
            visible_frame: ScreenRect::new(0.0, 0.0, 1920.0, 1040.0),
            scale: 1.0,
            size_scale: 1.0,
            is_main: true,
        },
        ScreenInfo {
            frame: ScreenRect::new(1920.0, 0.0, 2560.0, 1600.0),
            visible_frame: ScreenRect::new(1920.0, 0.0, 2560.0, 1540.0),
            scale: 1.5,
            size_scale: 1.5,
            is_main: false,
        },
    ]
}

/// 效果里某个窗口最后一次呈现的 frame。
fn presented_frame(effects: &[Effect], id: u64) -> Option<ScreenRect> {
    effects.iter().rev().find_map(|e| match e {
        Effect::ApplyPresentations { presentations, .. } => presentations
            .iter()
            .find(|p| p.id == WindowId(id))
            .map(|p| p.frame),
        _ => None,
    })
}

/// 配置里的尺寸是逻辑单位：放在 150% 屏上的缩略图画成 1.5 倍的像素，看起来与主屏上一样大。
#[test]
fn thumbnail_size_follows_screen_scaling() {
    let mut config = config();
    config.profiles[0].layouts.insert(
        "Alpha".to_owned(),
        eveo_core::model::ThumbnailLayout {
            x: 2000.0,
            y: 100.0,
            width: None,
            height: None,
        },
    );
    let mut coordinator = Coordinator::new(config, mixed_dpi_screens());
    coordinator.handle(Event::Started, 1.0);
    let effects = coordinator.handle(Event::WindowsPolled(three_characters()), 1.1);
    // Alpha 在副屏：默认 384×216 画成 576×324；其余自动排在主屏，保持 384×216。
    assert_eq!(
        presented_frame(&effects, 1),
        Some(ScreenRect::new(2000.0, 100.0, 576.0, 324.0))
    );
    let bravo = presented_frame(&effects, 2).unwrap();
    assert_eq!((bravo.width, bravo.height), (384.0, 216.0));
    // 手势的尺寸上下限也换成副屏的像素。
    let context = coordinator.drag_context(WindowId(1)).unwrap();
    let minimum = config_minimum();
    assert_eq!(context.minimum_size.width, minimum.0 * 1.5);
    assert_eq!(context.minimum_size.height, minimum.1 * 1.5);
}

/// 默认配置的最小尺寸（逻辑单位）。
fn config_minimum() -> (f64, f64) {
    let size = config().profiles[0].thumbnail.minimum_size;
    (size.width, size.height)
}

/// 从主屏拖到副屏只是移动：不改记录的尺寸，落下后按副屏换算；在副屏上缩放时换回逻辑尺寸保存。
#[test]
fn dragging_across_screens_keeps_logical_size() {
    let mut coordinator = Coordinator::new(config(), mixed_dpi_screens());
    coordinator.handle(Event::Started, 1.0);
    coordinator.handle(Event::WindowsPolled(three_characters()), 1.1);
    // 拖动中尺寸仍是主屏的 384×216 像素，落点在副屏。
    coordinator.handle(Event::DragBegan(WindowId(1)), 2.0);
    let effects = coordinator.handle(
        Event::DragEnded {
            id: WindowId(1),
            frame: ScreenRect::new(2400.0, 200.0, 384.0, 216.0),
        },
        2.5,
    );
    let layout = &changed_config(&effects).unwrap().profiles[0].layouts["Alpha"];
    assert_eq!((layout.width, layout.height), (None, None));
    assert_eq!(
        presented_frame(&effects, 1),
        Some(ScreenRect::new(2400.0, 200.0, 576.0, 324.0))
    );
    // 在副屏上拉大到 720×405 像素：存成逻辑尺寸 480×270。
    coordinator.handle(Event::DragBegan(WindowId(1)), 3.0);
    let effects = coordinator.handle(
        Event::DragEnded {
            id: WindowId(1),
            frame: ScreenRect::new(2400.0, 200.0, 720.0, 405.0),
        },
        3.5,
    );
    let layout = &changed_config(&effects).unwrap().profiles[0].layouts["Alpha"];
    assert_eq!((layout.width, layout.height), (Some(480.0), Some(270.0)));
    // 再拖回主屏：尺寸记录不变，画成 480×270 像素。
    coordinator.handle(Event::DragBegan(WindowId(1)), 4.0);
    let effects = coordinator.handle(
        Event::DragEnded {
            id: WindowId(1),
            frame: ScreenRect::new(100.0, 100.0, 720.0, 405.0),
        },
        4.5,
    );
    let layout = &changed_config(&effects).unwrap().profiles[0].layouts["Alpha"];
    assert_eq!((layout.width, layout.height), (Some(480.0), Some(270.0)));
    assert_eq!(
        presented_frame(&effects, 1),
        Some(ScreenRect::new(100.0, 100.0, 480.0, 270.0))
    );
}

#[test]
/// 「测试闪烁」：每个客户端各有一条按当前方案持续时间的提醒，不要求战斗提醒已打开；到期后由重算清掉。
fn test_combat_alert_flashes_every_client() {
    let mut coordinator = started(config(), three_characters());
    let duration = coordinator.profile().combat_alert.duration_seconds;
    assert!(!coordinator.profile().combat_alert.enabled);
    let effects = coordinator.handle(Event::TestCombatAlert, 2.0);
    assert_eq!(coordinator.session.combat_alerts.len(), 3);
    assert!(
        coordinator
            .session
            .combat_alerts
            .values()
            .all(|a| a.started_at == 2.0 && a.until == 2.0 + duration)
    );
    // 重算后要在最早到期时唤醒，好让闪烁按时结束。
    assert!(
        effects
            .iter()
            .any(|e| matches!(e, Effect::ScheduleWake(Some(at)) if *at <= 2.0 + duration))
    );
    // 到期以后的事件触发重算，提醒被清掉。
    coordinator.handle(Event::TestCombatAlert, 2.5);
    coordinator.handle(Event::DragCancelled(WindowId(1)), 2.0 + duration + 1.0);
    assert!(coordinator.session.combat_alerts.is_empty());
}
