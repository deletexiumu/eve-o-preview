// SPDX-License-Identifier: GPL-3.0-or-later
//
// 规划器的输入与输出，对应 macOS 的 Planning/PlannerModels.swift 与 Model/RuntimeModels.swift 里的
// FrontmostContext、SessionState、CombatAlertWindow。这些值都不持久化，应用重启后重新得到。

//! 规划器的输入与输出。

use std::collections::{BTreeMap, HashMap, HashSet};

use crate::geometry::{ScreenInfo, ScreenRect};
use crate::model::{CombatAlertStyle, EveClient, Pid, Profile, ThumbnailLayout, WindowId};

/// 当前前台窗口相对于 EVE 客户端的情况。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrontmostContext {
    /// 前台是某个已知客户端，关联值是它的 PID。
    Client(Pid),
    /// 前台是本应用（例如设置窗口），按「仍在 EVE 环境内」处理。
    SelfApp,
    /// 前台是其他应用。
    Other,
}

/// 一个窗口的战斗提醒时段，时间是单调时钟的秒数。持续受击时 `until` 一直延长，`started_at` 不变。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CombatAlertWindow {
    /// 本次提醒开始的时刻。
    pub started_at: f64,
    /// 提醒到期的时刻；`now >= until` 时视为已到期。
    pub until: f64,
}

impl CombatAlertWindow {
    /// 在 `now` 时刻是否仍未到期。
    pub fn is_active(&self, now: f64) -> bool {
        now < self.until
    }

    /// 受击一次（或「测试闪烁」）后的提醒时段，同 macOS 的 `CombatAlertRules.extended`。
    ///
    /// `existing` 未到期时保留 `started_at`，`until` 取原值与 `now + duration` 中较大的一个，不会缩短；
    /// 否则从 `now` 重新开始。
    pub fn extended(existing: Option<Self>, now: f64, duration: f64) -> Self {
        match existing {
            Some(existing) if existing.is_active(now) => Self {
                started_at: existing.started_at,
                until: existing.until.max(now + duration),
            },
            _ => Self {
                started_at: now,
                until: now + duration,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 未到期时延长且不缩短，开始时刻不变；到期后从现在重新开始。
    #[test]
    fn combat_alert_extension() {
        let first = CombatAlertWindow::extended(None, 10.0, 3.0);
        assert_eq!((first.started_at, first.until), (10.0, 13.0));
        let longer = CombatAlertWindow::extended(Some(first), 12.0, 3.0);
        assert_eq!((longer.started_at, longer.until), (10.0, 15.0));
        let shorter = CombatAlertWindow::extended(Some(longer), 12.5, 1.0);
        assert_eq!(shorter.until, 15.0);
        let restarted = CombatAlertWindow::extended(Some(longer), 20.0, 3.0);
        assert_eq!((restarted.started_at, restarted.until), (20.0, 23.0));
    }
}

/// 不持久化的会话状态，由协调器持有。时间都是单调时钟的秒数。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SessionState {
    /// 「全部隐藏」开关。
    pub hide_all: bool,
    /// 本次会话内被跳过、不参与循环的角色名；切换配置方案或重启后清空。
    pub skipped_characters: HashSet<String>,
    /// 鼠标悬停的缩略图对应的窗口；`None` 表示没有悬停。
    pub hovered_window: Option<WindowId>,
    /// 正在拖动的缩略图对应的窗口；规划器不放大它们，缩略图窗口不改它们的位置。
    pub interacting_windows: HashSet<WindowId>,
    /// 最近一次前台是 EVE 客户端或本应用的时刻，用于「离开 EVE 时隐藏」的延迟。
    pub last_eve_context_at: f64,
    /// 最近一次处于前台的客户端 PID；前台离开 EVE 后高亮仍留在它上面。
    pub last_active_pid: Option<Pid>,
    /// 战斗提醒，按窗口存放。到期的项由协调器在每次重算开头删掉；规划器只认未到期的项。
    pub combat_alerts: HashMap<WindowId, CombatAlertWindow>,
}

impl SessionState {
    /// 窗口在 `now` 时刻是否有未到期的战斗提醒。可见性、提醒外观、不透明度与下次重算都用这一个判断。
    pub fn has_active_combat_alert(&self, id: WindowId, now: f64) -> bool {
        self.combat_alerts.get(&id).is_some_and(|a| a.is_active(now))
    }

    /// 全部未到期提醒里最早的到期时刻；没有时返回 `None`。
    pub fn earliest_combat_alert_expiry(&self, now: f64) -> Option<f64> {
        self.combat_alerts
            .values()
            .filter(|a| a.is_active(now))
            .map(|a| a.until)
            .reduce(f64::min)
    }
}

/// 一个窗口的 DWM 缩略图状态，由平台层上报。没有记录的窗口按 `Pending` 处理。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThumbnailStatus {
    /// 还没注册，或已因隐藏而注销。
    #[default]
    Pending,
    /// 已注册，系统在合成画面。
    Shown,
    /// 注册失败（例如源窗口已不存在或系统拒绝），等下一轮重试。
    Failed,
}

/// 没有画面时缩略图显示的占位。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThumbnailPlaceholder {
    /// 不显示占位。
    None,
    /// DWM 缩略图注册失败，显示「画面不可用」。
    Unavailable,
    /// 客户端窗口已最小化，DWM 给不出画面。
    Minimized,
}

/// 一个缩略图的战斗提醒外观：颜色与样式。闪烁的动画由界面层负责。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThumbnailAlert {
    /// 闪烁颜色，`#RRGGBB`。
    pub color: String,
    /// 闪烁样式。
    pub style: CombatAlertStyle,
}

/// 一个缩略图在某一时刻应有的全部外观属性。
#[derive(Debug, Clone, PartialEq)]
pub struct ThumbnailPresentation {
    /// 客户端主窗口。
    pub id: WindowId,
    /// 客户端进程的 PID。
    pub pid: Pid,
    /// 缩略图窗口的位置与大小，全局屏幕坐标，已含悬停放大。
    /// 窗口正被拖动时是基准位置，界面层应保留拖动中的实际位置。
    pub frame: ScreenRect,
    /// 是否显示。
    pub is_visible: bool,
    /// 标题文字（角色名、`EVE` 或 `EVE (<pid>)`）。
    pub title: String,
    /// 是否显示标题。
    pub shows_title: bool,
    /// 标题字号，单位是点（界面层按显示器的缩放换算成像素）。
    pub title_font_size: f64,
    /// 标题颜色，`#RRGGBB`。
    pub title_color: String,
    /// 不透明度，0～1。
    pub opacity: f64,
    /// 高亮边框颜色；`None` 表示不画高亮。
    pub highlight_color: Option<String>,
    /// 高亮边框粗细。
    pub highlight_thickness: f64,
    /// 中性边框颜色；`None` 表示不画。不看是否活动，界面先用高亮、没有高亮时用它。
    pub border_color: Option<String>,
    /// 中性边框粗细。
    pub border_thickness: f64,
    /// 战斗提醒；`None` 表示没有未到期的提醒。不含时间，提醒延长时呈现不变。
    pub alert: Option<ThumbnailAlert>,
    /// 是否为活动客户端（前台客户端；前台不是 EVE 时为最后活动的客户端）。
    pub is_active: bool,
    /// 布局是否已锁定（`behavior.lock_layout`）。锁定特效叠在内侧，不覆盖活动高亮。
    pub is_locked: bool,
    /// 角色是否在本次会话内被跳过，显示跳过标记。
    pub is_skipped: bool,
    /// 是否置顶。
    pub is_always_on_top: bool,
    /// 置顶时是否要盖过全屏的客户端：前台是全屏的客户端时为真。
    pub is_over_full_screen: bool,
    /// frame 是否为悬停放大后的尺寸。
    pub is_zoomed: bool,
    /// 占位。
    pub placeholder: ThumbnailPlaceholder,
}

/// 规划器的输入：一次重算所需的全部状态。
#[derive(Debug, Clone, Copy)]
pub struct PlannerInput<'a> {
    /// 当前客户端，顺序即呈现的顺序（通常是客户端登记的顺序）。
    pub clients: &'a [EveClient],
    /// 当前前台。
    pub frontmost: FrontmostContext,
    /// 当前配置方案。
    pub profile: &'a Profile,
    /// 会话状态。
    pub session: &'a SessionState,
    /// 当前全部显示器。
    pub screens: &'a [ScreenInfo],
    /// 各窗口的 DWM 缩略图状态。
    pub thumbnail_states: &'a HashMap<WindowId, ThumbnailStatus>,
    /// 当前时刻，单调时钟的秒数，与 `SessionState::last_eve_context_at` 同一时钟。
    pub now: f64,
}

/// 规划器的输出。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ThumbnailPlan {
    /// 每个客户端一个呈现，顺序同 `PlannerInput::clients`。
    pub presentations: Vec<ThumbnailPresentation>,
    /// 要保持 DWM 缩略图注册的窗口，按客户端顺序，只含可见的缩略图；其余窗口的缩略图应注销。
    pub thumbnails: Vec<WindowId>,
    /// 要写进当前配置方案 `layouts` 的布局，只含本轮自动排位的角色。
    pub layouts_to_persist: BTreeMap<String, ThumbnailLayout>,
    /// 下一次需要重算的时刻，取隐藏延迟到期与最早的战斗提醒到期中较早的一个；`None` 表示不需要定时重算。
    pub next_wake_at: Option<f64>,
}
