// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的规划，对应 macOS 的 OverlayPlanner.swift（设计文档 8.6 节）：由客户端、前台、配置与屏幕算出每个已启用
// 浮窗的可见性、位置、层级与外观，以及活动角色。纯函数，由协调器在每次重算时调用。
// 可见性：没有任何客户端时不可见；「离开 EVE 时隐藏」到期后不可见，开关与延迟与缩略图共用；
// 每个浮窗还可选「仅游戏内」：前台既不是客户端也不是本应用时立即不可见。
// 「全部隐藏」（session.hide_all）只管缩略图，不影响浮窗。
//
// 与 macOS 的差别：Windows 的全局坐标是物理像素（PerMonitorV2），浮窗保存的 frame 也是物理像素。
// 默认尺寸、尺寸上下限与几个边距是按 100% 缩放写的，用时乘以所在屏幕的 size_scale（DPI ÷ 96），
// 在 150% 的屏幕上默认浮窗是 570×390 像素，看起来与 100% 屏幕上的 380×260 一样大。size_scale 为 1 时与 macOS 相同。

//! 浮窗的可见性、位置、层级与外观，以及活动角色。

use crate::geometry::{ScreenInfo, ScreenPoint, ScreenRect, ScreenSize, main_screen, size_scale_at};
use crate::model::{
    EveClient, OVERLAY_FONT_SIZE_RANGE, OVERLAY_OPACITY_RANGE, OverlayPanelSettings, OverlayVisibility, Pid,
    Profile,
};
use crate::overlay::OverlayKind;
use crate::planning::{FrontmostContext, SessionState};

/// 浮窗尺寸的下限（100% 缩放）。
pub const MINIMUM_SIZE: ScreenSize = ScreenSize::new(220.0, 120.0);
/// 浮窗尺寸的上限（100% 缩放）。
pub const MAXIMUM_SIZE: ScreenSize = ScreenSize::new(900.0, 900.0);
/// 浮窗的默认尺寸（100% 缩放）。
pub const DEFAULT_SIZE: ScreenSize = ScreenSize::new(380.0, 260.0);
/// 把保存的 frame 收进屏幕时至少要留下的长度（100% 缩放）。
pub const MINIMUM_VISIBLE_LENGTH: f64 = 40.0;
/// 默认位置距可见区域右边的距离。
const DEFAULT_RIGHT_MARGIN: f64 = 20.0;
/// 默认位置距可见区域顶边的距离。
const DEFAULT_TOP_MARGIN: f64 = 60.0;
/// 两个浮窗默认位置之间的间隔。
const DEFAULT_GAP: f64 = 12.0;

/// 规划的输入。都是借用：协调器每次重算时临时组装。
#[derive(Debug, Clone, Copy)]
pub struct OverlayPlannerInput<'a> {
    /// 已发现的客户端。
    pub clients: &'a [EveClient],
    /// 当前前台。
    pub frontmost: FrontmostContext,
    /// 当前配置方案。
    pub profile: &'a Profile,
    /// 会话状态（最近活动的客户端、离开 EVE 的时刻）。
    pub session: &'a SessionState,
    /// 当前屏幕。
    pub screens: &'a [ScreenInfo],
    /// 单调时钟的秒数，与 SessionState 同一时钟。
    pub now: f64,
}

/// 一个浮窗的呈现。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OverlayPresentation {
    /// 浮窗的种类。
    pub kind: OverlayKind,
    /// 是否可见。
    pub is_visible: bool,
    /// 全局屏幕坐标的位置与尺寸。
    pub frame: ScreenRect,
    /// 背景的不透明度。
    pub opacity: f64,
    /// 第一行的字号。
    pub font_size: f64,
    /// 是否置顶。
    pub is_always_on_top: bool,
    /// 是否盖在全屏的客户端上。
    pub is_over_full_screen: bool,
    /// 布局已锁定：忽略移动与缩放。
    pub is_locked: bool,
}

/// 规划的结果。
#[derive(Debug, Clone, PartialEq)]
pub struct OverlayPlan {
    /// 只含已启用的浮窗，按 Intel、Translation 的顺序。
    pub presentations: Vec<OverlayPresentation>,
    /// 活动角色；不论浮窗是否启用都算出来（聊天日志的跟踪也要用）。
    pub active_character: Option<String>,
    /// 下一次要重算的时刻（隐藏延迟到期），单调时钟；不用时为 None。
    pub next_wake_at: Option<f64>,
}

/// 设置页可以手工填写的 frame 字段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameField {
    /// 左边的 x 坐标。
    X,
    /// 上边的 y 坐标（y 轴向下）。
    Y,
    /// 宽度。
    Width,
    /// 高度。
    Height,
}

/// 规划全部浮窗：每个已启用的浮窗一个呈现，按 Intel、Translation 的顺序；没启用的不出现。
///
/// - 可见：有客户端，且「离开 EVE 时隐藏」没有到期（前台是本应用时不算离开）；
///   设为「仅游戏内」的浮窗另要求前台是客户端或本应用（[`is_in_eve_context`]），不等延迟。
/// - frame：保存过时取 [`clamped_frame`] 的结果，否则取 [`default_frame`]。
/// - 层级：is_always_on_top 取 behavior.always_on_top；置顶且前台是全屏的客户端时 is_over_full_screen 为真。
/// - next_wake_at：有启用的浮窗、有客户端、隐藏延迟还没到期时是到期时刻，否则为 None。
pub fn plan(input: &OverlayPlannerInput<'_>) -> OverlayPlan {
    let active = active_character(input.clients, input.frontmost, input.session.last_active_pid);
    let behavior = &input.profile.behavior;
    // 两个浮窗共用的条件先算好：是否整体隐藏、是否在 EVE 环境内、是否要盖在全屏客户端上。
    let hidden = input.clients.is_empty() || is_hidden_away_from_eve(input);
    let in_eve = is_in_eve_context(input.frontmost);
    let over_full_screen = behavior.always_on_top && is_frontmost_full_screen(input);
    let mut presentations = Vec::new();
    for kind in OverlayKind::ALL {
        let Some(settings) = enabled_settings(kind, input.profile) else {
            continue;
        };
        let visible_here = settings.visibility == OverlayVisibility::Always || in_eve;
        presentations.push(OverlayPresentation {
            kind,
            is_visible: !hidden && visible_here,
            frame: resolved_frame(settings.frame, kind, input.screens),
            opacity: clamp(settings.opacity, OVERLAY_OPACITY_RANGE, 0.75),
            font_size: clamp(settings.font_size, OVERLAY_FONT_SIZE_RANGE, 12.0),
            is_always_on_top: behavior.always_on_top,
            is_over_full_screen: over_full_screen,
            is_locked: behavior.lock_layout,
        });
    }
    // 没有浮窗或没有客户端时，到期与否都不改变结果，不必定时重算。
    let next_wake_at = if presentations.is_empty() || input.clients.is_empty() {
        None
    } else {
        hide_deadline(input)
    };
    OverlayPlan {
        presentations,
        active_character: active,
        next_wake_at,
    }
}

/// 活动客户端的角色名：前台是客户端时取它；否则取最后活动的客户端；都没有时取第一个有角色的客户端。
///
/// 前台是登录界面的客户端时返回 None（用户正看着登录界面）。最后活动的客户端停在登录界面或已不在时，
/// 退到 clients 里第一个有角色名的客户端。
pub fn active_character(
    clients: &[EveClient],
    frontmost: FrontmostContext,
    last_active_pid: Option<Pid>,
) -> Option<String> {
    if let FrontmostContext::Client(pid) = frontmost
        && let Some(client) = clients.iter().find(|c| c.pid == pid)
    {
        return client.character_name().map(str::to_owned);
    }
    if let Some(pid) = last_active_pid
        && let Some(name) = clients
            .iter()
            .find(|c| c.pid == pid)
            .and_then(EveClient::character_name)
    {
        return Some(name.to_owned());
    }
    clients
        .iter()
        .find_map(EveClient::character_name)
        .map(str::to_owned)
}

/// 默认位置：主屏可见区域的右上角。预警浮窗距右边 20、距顶边 60；翻译浮窗在它正下方，隔 12。
/// 尺寸与边距乘以主屏的 size_scale。没有屏幕时以 (0, 0) 为主屏左上角、1440×900 为可见区域。
pub fn default_frame(kind: OverlayKind, screens: &[ScreenInfo]) -> ScreenRect {
    let screen = main_screen(screens);
    let visible = screen.map_or(ScreenRect::new(0.0, 0.0, 1440.0, 900.0), |s| s.visible_frame);
    let scale = screen.map_or(1.0, |s| s.size_scale);
    let width = DEFAULT_SIZE.width * scale;
    let height = DEFAULT_SIZE.height * scale;
    let x = visible.max_x() - DEFAULT_RIGHT_MARGIN * scale - width;
    let top = visible.min_y() + DEFAULT_TOP_MARGIN * scale;
    let y = match kind {
        OverlayKind::Intel => top,
        OverlayKind::Translation => top + height + DEFAULT_GAP * scale,
    };
    ScreenRect::new(x, y, width, height)
}

/// 把保存的 frame 收进屏幕：尺寸夹到上下限，至少 40（乘以缩放）留在某个屏幕的可见区域内。
///
/// 与某个屏幕的可见区域在水平、垂直方向都重叠至少 40 时只夹尺寸，位置不动（多屏时不把浮窗拉到主屏）。
/// 否则移到离 frame 中心最近的那个屏幕：左右各至少留 40，上下各至少留 40。没有屏幕时只夹尺寸。
pub fn clamped_frame(frame: ScreenRect, screens: &[ScreenInfo]) -> ScreenRect {
    let x = if frame.x.is_finite() { frame.x } else { 0.0 };
    let y = if frame.y.is_finite() { frame.y } else { 0.0 };
    // 尺寸上下限按 frame 中心所在（或最近）的屏幕换算；中心算不出时按 1。
    let center = ScreenPoint::new(
        x + finite_or(frame.width, 0.0) / 2.0,
        y + finite_or(frame.height, 0.0) / 2.0,
    );
    let scale = size_scale_at(screens, center);
    let width = clamp(
        frame.width,
        (MINIMUM_SIZE.width * scale, MAXIMUM_SIZE.width * scale),
        DEFAULT_SIZE.width * scale,
    );
    let height = clamp(
        frame.height,
        (MINIMUM_SIZE.height * scale, MAXIMUM_SIZE.height * scale),
        DEFAULT_SIZE.height * scale,
    );
    // 先只夹尺寸；位置已经合适（与某块屏幕有足够的重叠）时到此为止。
    let mut result = ScreenRect::new(x, y, width, height);
    if screens
        .iter()
        .any(|s| overlaps(&result, &s.visible_frame, MINIMUM_VISIBLE_LENGTH * s.size_scale))
    {
        return result;
    }
    let Some(target) = nearest_screen(result.center(), screens) else {
        return result;
    };
    let visible = target.visible_frame;
    let margin = MINIMUM_VISIBLE_LENGTH * target.size_scale;
    // 可见区域比边距还窄时（不会出现在真实屏幕上）以左上角对齐，免得上下界颠倒。
    result.x = result
        .x
        .max(visible.min_x() - width + margin)
        .min(visible.min_x().max(visible.max_x() - margin));
    result.y = result
        .y
        .max(visible.min_y() - height + margin)
        .min(visible.min_y().max(visible.max_y() - margin));
    result
}

/// 浮窗实际使用的 frame：保存过时取 [`clamped_frame`] 的结果，否则取 [`default_frame`]。
/// 规划与设置页的数字框共用它，设置页显示的数值与浮窗实际位置一致。
pub fn resolved_frame(saved: Option<ScreenRect>, kind: OverlayKind, screens: &[ScreenInfo]) -> ScreenRect {
    saved.map_or_else(
        || default_frame(kind, screens),
        |frame| clamped_frame(frame, screens),
    )
}

/// 在设置页改了一个字段后的新 frame：取整后写进该字段，再经 [`clamped_frame`] 夹尺寸、拉回屏幕。
/// base 一般是 [`resolved_frame`] 的结果（没保存过时就是默认位置，写入后即保存下来）。
/// 数值不是有限值时返回 None，调用方不写配置。
pub fn edited_frame(
    base: ScreenRect,
    field: FrameField,
    value: f64,
    screens: &[ScreenInfo],
) -> Option<ScreenRect> {
    if !value.is_finite() {
        return None;
    }
    let mut frame = base;
    let rounded = value.round();
    match field {
        FrameField::X => frame.x = rounded,
        FrameField::Y => frame.y = rounded,
        FrameField::Width => frame.width = rounded,
        FrameField::Height => frame.height = rounded,
    }
    Some(clamped_frame(frame, screens))
}

/// 前台是客户端或本应用（设置窗口等）时算在 EVE 环境内；「仅游戏内」的浮窗只在这时显示。
/// 本应用算在内：在设置页调整浮窗时要能看到它；浮窗本身不抢焦点，点它不会改变前台。
pub fn is_in_eve_context(frontmost: FrontmostContext) -> bool {
    frontmost != FrontmostContext::Other
}

/// 已启用的浮窗的设置；没启用时为 None。
fn enabled_settings(kind: OverlayKind, profile: &Profile) -> Option<&OverlayPanelSettings> {
    match kind {
        OverlayKind::Intel => profile.intel.enabled.then_some(&profile.intel.overlay),
        OverlayKind::Translation => profile
            .translation
            .enabled
            .then_some(&profile.translation.overlay),
    }
}

/// 「离开 EVE 时隐藏」是否已到期：开关打开、前台是其他应用、离开的时长不小于延迟。
/// 规则与缩略图的第 4 条相同，但浮窗不受战斗提醒的例外影响。
fn is_hidden_away_from_eve(input: &OverlayPlannerInput<'_>) -> bool {
    let behavior = &input.profile.behavior;
    behavior.hide_when_eve_not_frontmost
        && input.frontmost == FrontmostContext::Other
        && input.now - input.session.last_eve_context_at >= behavior.hide_delay_seconds
}

/// 隐藏延迟还没到期时返回到期时刻，否则返回 None。
fn hide_deadline(input: &OverlayPlannerInput<'_>) -> Option<f64> {
    let behavior = &input.profile.behavior;
    if !behavior.hide_when_eve_not_frontmost || input.frontmost != FrontmostContext::Other {
        return None;
    }
    let deadline = input.session.last_eve_context_at + behavior.hide_delay_seconds;
    (input.now < deadline).then_some(deadline)
}

/// 前台是否是全屏的客户端，规则与缩略图相同。全屏状态不知道（None）时按不全屏处理。
fn is_frontmost_full_screen(input: &OverlayPlannerInput<'_>) -> bool {
    let FrontmostContext::Client(pid) = input.frontmost else {
        return false;
    };
    input
        .clients
        .iter()
        .any(|c| c.pid == pid && c.is_full_screen == Some(true))
}

/// 两个矩形在水平、垂直方向是否都重叠至少 length。
fn overlaps(a: &ScreenRect, b: &ScreenRect, length: f64) -> bool {
    let horizontal = a.max_x().min(b.max_x()) - a.min_x().max(b.min_x());
    let vertical = a.max_y().min(b.max_y()) - a.min_y().max(b.min_y());
    horizontal >= length && vertical >= length
}

/// 可见区域离点最近的屏幕；点在某个可见区域内时距离为 0。距离相同时取靠前的屏幕。
fn nearest_screen(point: ScreenPoint, screens: &[ScreenInfo]) -> Option<&ScreenInfo> {
    let distance = |rect: &ScreenRect| {
        let dx = (rect.min_x() - point.x).max(0.0).max(point.x - rect.max_x());
        let dy = (rect.min_y() - point.y).max(0.0).max(point.y - rect.max_y());
        dx * dx + dy * dy
    };
    let mut best: Option<(&ScreenInfo, f64)> = None;
    for screen in screens {
        let d = distance(&screen.visible_frame);
        // 只在严格更近时替换，距离相同时留下靠前的。
        if best.is_none_or(|(_, current)| d < current) {
            best = Some((screen, d));
        }
    }
    best.map(|(screen, _)| screen)
}

/// 把数值夹进范围；不是有限值时取 fallback。配置已由校验器夹过，这里只作防御。
fn clamp(value: f64, range: (f64, f64), fallback: f64) -> f64 {
    if value.is_finite() {
        value.clamp(range.0, range.1)
    } else {
        fallback
    }
}

/// 有限值原样返回，否则返回 fallback。
fn finite_or(value: f64, fallback: f64) -> f64 {
    if value.is_finite() { value } else { fallback }
}
