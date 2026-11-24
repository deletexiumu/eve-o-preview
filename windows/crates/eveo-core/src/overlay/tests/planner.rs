// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗规划：启用与呈现、可见性、隐藏延迟、层级、活动角色、保存的位置与「仅游戏内」。

use super::{PID_A, PID_B, PID_C, PILOT_ALPHA, PILOT_BRAVO, character, client, main_screen};
use crate::geometry::{ScreenInfo, ScreenRect};
use crate::model::{ClientIdentity, EveClient, OverlayPanelSettings, OverlayVisibility, Profile};
use crate::overlay::OverlayKind;
use crate::overlay::planner::{OverlayPlan, OverlayPlannerInput, active_character, default_frame, plan};
use crate::planning::{FrontmostContext, SessionState};

/// 一次规划的场景：默认两个功能都启用，前台是其他应用，离开 EVE 的时刻是 99，now = 100。
struct Scenario {
    /// 客户端。
    clients: Vec<EveClient>,
    /// 前台。
    frontmost: FrontmostContext,
    /// 当前时刻。
    now: f64,
    /// 屏幕。
    screens: Vec<ScreenInfo>,
    /// 配置方案。
    profile: Profile,
    /// 会话状态。
    session: SessionState,
}

impl Scenario {
    /// 默认场景：两个已选角色的客户端，只有主屏。
    fn new() -> Self {
        let mut profile = Profile::new("t", "T");
        profile.intel.enabled = true;
        profile.translation.enabled = true;
        Self {
            clients: vec![character(PILOT_ALPHA, 1, PID_A), character(PILOT_BRAVO, 2, PID_B)],
            frontmost: FrontmostContext::Other,
            now: 100.0,
            screens: vec![main_screen()],
            profile,
            session: SessionState {
                last_eve_context_at: 99.0,
                ..SessionState::default()
            },
        }
    }

    /// 按当前场景规划。
    fn plan(&self) -> OverlayPlan {
        plan(&OverlayPlannerInput {
            clients: &self.clients,
            frontmost: self.frontmost,
            profile: &self.profile,
            session: &self.session,
            screens: &self.screens,
            now: self.now,
        })
    }

    /// 打开「离开 EVE 时隐藏」，延迟 seconds 秒。
    fn hide_away(mut self, seconds: f64) -> Self {
        self.profile.behavior.hide_when_eve_not_frontmost = true;
        self.profile.behavior.hide_delay_seconds = seconds;
        self
    }
}

/// 登录界面的客户端。
fn login() -> EveClient {
    client(3, PID_C, ClientIdentity::Login)
}

/// 各呈现的可见性。
fn visibility(plan: &OverlayPlan) -> Vec<bool> {
    plan.presentations.iter().map(|p| p.is_visible).collect()
}

/// 两个功能都没开时没有呈现，也没有定时重算；活动角色照样算出来。
#[test]
fn no_presentation_when_disabled() {
    let mut scenario = Scenario::new();
    scenario.profile.intel.enabled = false;
    scenario.profile.translation.enabled = false;
    // 活动角色还要交给聊天日志的跟踪，所以浮窗都关着也照样算。
    scenario.session.last_active_pid = Some(PID_B);
    let value = scenario.plan();
    assert!(value.presentations.is_empty());
    assert_eq!(value.next_wake_at, None);
    assert_eq!(value.active_character.as_deref(), Some(PILOT_BRAVO));
}

/// 只开一个功能时只有它的呈现；两个都开时按 Intel、Translation 的顺序，且都可见。
#[test]
fn only_enabled_kinds() {
    let mut scenario = Scenario::new();
    scenario.profile.intel.enabled = false;
    let kinds: Vec<OverlayKind> = scenario.plan().presentations.iter().map(|p| p.kind).collect();
    assert_eq!(kinds, [OverlayKind::Translation]);
    let both = Scenario::new().plan();
    let kinds: Vec<OverlayKind> = both.presentations.iter().map(|p| p.kind).collect();
    assert_eq!(kinds, OverlayKind::ALL);
    assert_eq!(visibility(&both), [true, true]);
}

/// 外观与锁定取自配置；越界的数值被夹进范围（配置校验之外的防御）。
#[test]
fn appearance_from_settings() {
    let mut scenario = Scenario::new();
    scenario.profile.intel.overlay.opacity = 0.4;
    scenario.profile.intel.overlay.font_size = 18.0;
    // 翻译浮窗故意给越界的值：不透明度夹到 1.0，字号夹到 10。
    scenario.profile.translation.overlay.opacity = 5.0;
    scenario.profile.translation.overlay.font_size = 2.0;
    scenario.profile.behavior.always_on_top = false;
    scenario.profile.behavior.lock_layout = true;
    let value = scenario.plan();
    let intel = value.presentations[0];
    assert_eq!((intel.opacity, intel.font_size), (0.4, 18.0));
    assert!(!intel.is_always_on_top);
    assert!(intel.is_locked);
    let translation = value.presentations[1];
    assert_eq!((translation.opacity, translation.font_size), (1.0, 10.0));
}

/// 没有任何客户端时不可见，也不安排定时重算，没有活动角色。
#[test]
fn invisible_without_clients() {
    // 即使打开了「离开 EVE 时隐藏」，没有客户端时也不需要按延迟醒来：结果不会变。
    let mut scenario = Scenario::new().hide_away(1.0);
    scenario.clients.clear();
    let value = scenario.plan();
    assert_eq!(visibility(&value), [false, false]);
    assert_eq!(value.next_wake_at, None);
    assert_eq!(value.active_character, None);
}

/// 只有登录界面的客户端时浮窗可见（有客户端），但没有活动角色。
#[test]
fn visible_with_only_login_client() {
    let mut scenario = Scenario::new();
    // 停在登录界面也算在玩，浮窗照常显示（内容会是「当前窗口没有角色」）。
    scenario.clients = vec![login()];
    let value = scenario.plan();
    assert_eq!(visibility(&value), [true, true]);
    assert_eq!(value.active_character, None);
}

/// 隐藏延迟到期前可见、next_wake_at 是到期时刻；到期后不可见、next_wake_at 为 None；开关关着时不隐藏。
#[test]
fn hide_delay() {
    let mut before = Scenario::new().hide_away(3.0);
    // 99 离开，延迟 3 秒：102 到期。101 时还可见，要在 102 醒来重算。
    before.now = 101.0;
    let value = before.plan();
    assert_eq!(visibility(&value), [true, true]);
    assert_eq!(value.next_wake_at, Some(102.0));
    let mut at_deadline = Scenario::new().hide_away(3.0);
    at_deadline.now = 102.0;
    let value = at_deadline.plan();
    assert_eq!(visibility(&value), [false, false]);
    assert_eq!(value.next_wake_at, None);
    let mut off = Scenario::new();
    off.now = 500.0;
    let value = off.plan();
    assert_eq!(visibility(&value), [true, true]);
    assert_eq!(value.next_wake_at, None);
}

/// 前台是本应用或客户端时不算离开 EVE，不隐藏。
#[test]
fn self_app_and_client_do_not_hide() {
    for frontmost in [FrontmostContext::SelfApp, FrontmostContext::Client(PID_A)] {
        let mut scenario = Scenario::new().hide_away(1.0);
        scenario.frontmost = frontmost;
        scenario.now = 500.0;
        let value = scenario.plan();
        assert_eq!(visibility(&value), [true, true], "{frontmost:?}");
        assert_eq!(value.next_wake_at, None);
    }
}

/// 「全部隐藏」只管缩略图，不影响浮窗。
#[test]
fn hide_all_does_not_affect_overlays() {
    let mut scenario = Scenario::new();
    // 「全部隐藏」是缩略图的快捷键，用户按下它多半是想看清游戏画面，预警仍要看得到。
    scenario.session.hide_all = true;
    assert_eq!(visibility(&scenario.plan()), [true, true]);
}

/// 前台是全屏的客户端且置顶时 is_over_full_screen 为真；不置顶或前台不是那个客户端时为假。
#[test]
fn over_full_screen() {
    let mut scenario = Scenario::new();
    // 第一个客户端是全屏的，并且在前台：浮窗要盖在它上面才看得到。
    scenario.clients[0].is_full_screen = Some(true);
    scenario.frontmost = FrontmostContext::Client(PID_A);
    let on_top = scenario.plan();
    assert!(
        on_top
            .presentations
            .iter()
            .all(|p| p.is_over_full_screen && p.is_always_on_top)
    );
    scenario.profile.behavior.always_on_top = false;
    assert!(
        scenario
            .plan()
            .presentations
            .iter()
            .all(|p| !p.is_over_full_screen)
    );
    scenario.profile.behavior.always_on_top = true;
    scenario.frontmost = FrontmostContext::Client(PID_B);
    assert!(
        scenario
            .plan()
            .presentations
            .iter()
            .all(|p| !p.is_over_full_screen)
    );
}

/// 3 级取法：前台客户端、最后活动的客户端、第一个有角色名的客户端。
#[test]
fn active_character_levels() {
    // 第一个是登录界面的客户端：第 3 级取法跳过它，取第一个有角色名的。
    let clients = [
        login(),
        character(PILOT_ALPHA, 1, PID_A),
        character(PILOT_BRAVO, 2, PID_B),
    ];
    let pick = |frontmost, last| active_character(&clients, frontmost, last);
    assert_eq!(
        pick(FrontmostContext::Client(PID_B), Some(PID_A)).as_deref(),
        Some(PILOT_BRAVO)
    );
    assert_eq!(
        pick(FrontmostContext::Other, Some(PID_B)).as_deref(),
        Some(PILOT_BRAVO)
    );
    assert_eq!(
        pick(FrontmostContext::SelfApp, None).as_deref(),
        Some(PILOT_ALPHA)
    );
    assert_eq!(active_character(&[], FrontmostContext::Other, None), None);
}

/// 前台是登录界面的客户端时为 None；最后活动的客户端在登录界面或已不在时退到第一个有角色名的客户端。
#[test]
fn active_character_with_login_clients() {
    let clients = vec![
        login(),
        character(PILOT_BRAVO, 2, PID_B),
        character(PILOT_ALPHA, 1, PID_A),
    ];
    let pick = |frontmost, last| active_character(&clients, frontmost, last);
    // 用户正看着登录界面：不显示别的角色的预警，免得看错。
    assert_eq!(pick(FrontmostContext::Client(PID_C), Some(PID_A)), None);
    assert_eq!(
        pick(FrontmostContext::Other, Some(PID_C)).as_deref(),
        Some(PILOT_BRAVO)
    );
    // 9999 是已经关掉的客户端。
    assert_eq!(
        pick(FrontmostContext::Other, Some(9_999)).as_deref(),
        Some(PILOT_BRAVO)
    );
    // 规划结果里的活动角色用同一个取法。
    let mut scenario = Scenario::new();
    scenario.clients = clients.clone();
    scenario.frontmost = FrontmostContext::Client(PID_C);
    assert_eq!(scenario.plan().active_character, None);
}

/// 没有保存位置时用默认位置；保存过时用收进屏幕后的位置。
#[test]
fn frame_from_settings() {
    let saved = ScreenRect::new(100.0, 200.0, 300.0, 200.0);
    let mut scenario = Scenario::new();
    // 只给预警浮窗保存位置；翻译浮窗没保存过，用默认位置。
    scenario.profile.intel.overlay.frame = Some(saved);
    let value = scenario.plan();
    assert_eq!(value.presentations[0].frame, saved);
    assert_eq!(
        value.presentations[1].frame,
        default_frame(OverlayKind::Translation, &[main_screen()])
    );
}

/// 「仅游戏内」：前台是其他应用时立即隐藏（不等延迟、也不看「离开 EVE 时隐藏」）；前台是客户端或本应用时显示。
/// 「始终显示」的另一个浮窗不受影响。
#[test]
fn game_only_hides_when_eve_not_frontmost() {
    let mut scenario = Scenario::new();
    scenario.profile.intel.overlay.visibility = OverlayVisibility::GameOnly;
    assert_eq!(visibility(&scenario.plan()), [false, true]);
    for frontmost in [FrontmostContext::Client(PID_A), FrontmostContext::SelfApp] {
        scenario.frontmost = frontmost;
        assert_eq!(visibility(&scenario.plan()), [true, true]);
    }
}

/// 没有客户端时两种显示范围都不可见；不认识的显示范围解码成默认值，不让配置读取失败。
#[test]
fn visibility_edge_cases() {
    let mut scenario = Scenario::new();
    scenario.clients.clear();
    scenario.frontmost = FrontmostContext::SelfApp;
    scenario.profile.translation.overlay.visibility = OverlayVisibility::GameOnly;
    assert_eq!(visibility(&scenario.plan()), [false, false]);
    // 新版本可能加别的取值；旧版本读到不认识的值时按「始终显示」，不让整个配置读取失败。
    let decoded: OverlayPanelSettings = serde_json::from_str(r#"{"visibility":"someday"}"#).unwrap();
    assert_eq!(decoded.visibility, OverlayVisibility::Always);
    assert_eq!(
        OverlayPanelSettings::default().visibility,
        OverlayVisibility::Always
    );
}
