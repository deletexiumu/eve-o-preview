// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的输入与输出（架构文档 3.3 节）。
// 事件由可执行文件里的各个来源送进来：WinEvent 钩子与兜底轮询、热键窗口、缩略图窗口的手势、托盘菜单、设置窗口。
// 效果由可执行文件按顺序执行：缩略图窗口管理器、热键服务、配置写盘、定时器、激活与最小化。
// 协调器不知道效果是否执行成功；执行结果若影响状态（例如激活后前台变了），会以新的事件回来。

//! 协调器的事件与效果。

use std::collections::HashSet;

use eveo_core::geometry::{ScreenInfo, ScreenRect, ScreenSize};
use eveo_core::hotkeys::planner::HotkeyBinding;
use eveo_core::layout::SnapTargets;
use eveo_core::model::{AppConfig, Pid, WindowId, WindowInfo};
use eveo_core::planning::{ThumbnailPresentation, ThumbnailStatus};

/// 前台窗口属于谁，由平台层判断后送进来。协调器再按客户端列表换算成规划器用的 `FrontmostContext`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ForegroundOwner {
    /// 前台是本应用的窗口（设置窗口、托盘菜单）。
    SelfApp,
    /// 前台属于这个进程。是不是 EVE 客户端由协调器按客户端列表判断。
    Process(Pid),
    /// 没有前台窗口（例如刚锁屏），或读不到前台。
    #[default]
    Nobody,
}

/// 设置窗口的页面。托盘与右键菜单打开设置时指定落在哪一页。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SettingsPage {
    /// 通用。
    #[default]
    General,
    /// 预览与布局。
    Previews,
    /// 客户端。
    Clients,
    /// 切换与热键。
    Switching,
    /// 配置方案。
    Profiles,
    /// 关于。
    About,
}

/// 缩略图右键菜单里的动作，对应 macOS 的 `ThumbnailContextMenu.Action`（没有「恢复捕获」：DWM 不会被用户停止）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ContextMenuAction {
    /// 最小化这个客户端。
    Minimize,
    /// 最小化全部客户端。
    MinimizeAll,
    /// 切换这个角色在本次会话内的「跳过循环」。
    ToggleSkip,
    /// 把这个角色加进隐藏名单（持久化）。
    Hide,
    /// 清掉这个角色的尺寸记录，恢复默认尺寸。
    ResetSize,
    /// 打开设置窗口的「预览与布局」页。
    OpenSettings,
}

/// 托盘菜单里的动作。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TrayAction {
    /// 切换「全部隐藏」。
    ToggleHideAll,
    /// 最小化全部客户端。
    MinimizeAll,
    /// 切换到这个配置方案（id）。
    SwitchProfile(String),
    /// 打开设置窗口。
    OpenSettings,
    /// 退出。
    Quit,
}

/// 送进协调器的事件。每个事件只更新状态；需要时在同一次 `handle` 末尾重算一次。
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// 应用启动完成、各服务已就绪。协调器注册热键并做第一次规划。
    Started,
    /// 一轮窗口枚举的结果：全部候选窗口，协调器自己选主窗口、更新客户端登记。
    WindowsPolled(Vec<WindowInfo>),
    /// 前台变化（WinEvent 的前台事件，或轮询时顺带读到的前台）。
    ForegroundChanged(ForegroundOwner),
    /// 显示器排列或缩放变了，关联值是新的屏幕列表。
    ScreensChanged(Vec<ScreenInfo>),
    /// 一个窗口的 DWM 缩略图状态变了。
    ThumbnailStatusChanged {
        /// 客户端窗口。
        id: WindowId,
        /// 新状态。
        status: ThumbnailStatus,
    },
    /// `Effect::ScheduleWake` 安排的时刻到了。
    Wake,
    /// 热键触发，关联值是绑定 id（`RegisterHotKey` 的编号已由热键服务按代数解码）。
    HotkeyFired(u32),
    /// 左键点缩略图。
    ThumbnailClicked(WindowId),
    /// Ctrl+左键点缩略图：最小化对应客户端。
    ThumbnailMinimizeRequested(WindowId),
    /// 鼠标进入或离开缩略图。
    HoverChanged {
        /// 缩略图对应的客户端窗口。
        id: WindowId,
        /// 进入为真，离开为假。
        hovering: bool,
    },
    /// 开始拖动或缩放缩略图。
    DragBegan(WindowId),
    /// 松开鼠标，关联值是最终的 frame（已吸附与约束）。
    DragEnded {
        /// 缩略图对应的客户端窗口。
        id: WindowId,
        /// 最终的 frame，全局屏幕坐标。
        frame: ScreenRect,
    },
    /// 拖动被取消（按了 Esc 或缩略图被隐藏），不保存布局。
    DragCancelled(WindowId),
    /// 在缩略图的右键菜单里选了一项。
    ContextMenu {
        /// 缩略图对应的客户端窗口。
        id: WindowId,
        /// 选中的动作。
        action: ContextMenuAction,
    },
    /// 在托盘菜单里选了一项。
    Tray(TrayAction),
    /// 设置窗口改了配置，关联值是改后的完整配置。协调器校验后采用。
    ConfigEdited(AppConfig),
    /// 「提醒」页的「测试闪烁」：让全部客户端的缩略图按当前方案的设置闪一次，不要求战斗提醒已打开。
    TestCombatAlert,
}

/// 协调器要求执行的效果，按产生的顺序执行。
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// 按规划更新缩略图窗口：建、销毁、移动、改外观；只给 `thumbnails` 里的窗口保持 DWM 注册。
    ApplyPresentations {
        /// 每个客户端一个呈现，顺序同客户端登记。
        presentations: Vec<ThumbnailPresentation>,
        /// 要保持 DWM 缩略图注册的窗口。
        thumbnails: Vec<WindowId>,
        /// 正在拖动的窗口：缩略图窗口管理器不改它们的 frame。
        interacting: HashSet<WindowId>,
    },
    /// 用这份绑定替换全部已注册的热键。热键服务换一个代数重新注册。
    RegisterHotkeys(Vec<HotkeyBinding>),
    /// 前台是否是 EVE 客户端变了：作用范围是 `game` 的热键据此启用或停用。
    SetGameForeground(bool),
    /// 配置变了：通知设置窗口，并延迟合并后写盘（配置不可写时只通知）。
    ConfigChanged(AppConfig),
    /// 在这个单调时钟时刻送一个 `Event::Wake`；`None` 取消已安排的唤醒。新的安排取代旧的。
    ScheduleWake(Option<f64>),
    /// 切换到这个客户端。执行后应再轮询一次窗口。
    Activate(WindowId),
    /// 最小化这个客户端。执行后应再轮询一次窗口。
    Minimize(WindowId),
    /// 立即枚举一次窗口，结果以 `Event::WindowsPolled` 送回。
    PollNow,
    /// 打开设置窗口并切到这一页。
    OpenSettings(SettingsPage),
    /// 退出应用：先把配置立即写盘，再拆掉各服务。
    Quit,
}

/// 构建缩略图右键菜单所需的状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextMenuModel {
    /// 角色名；登录与未知客户端为 `None`，按角色的菜单项置灰。
    pub character_name: Option<String>,
    /// 本次会话内是否已跳过。
    pub is_skipped: bool,
    /// 是否有尺寸记录（决定「恢复默认尺寸」是否可用）。
    pub has_custom_size: bool,
}

/// 构建托盘菜单所需的状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrayModel {
    /// 全部配置方案，`(id, 名称)`，按配置里的顺序。
    pub profiles: Vec<(String, String)>,
    /// 当前配置方案的 id。
    pub active_profile_id: String,
    /// 「全部隐藏」是否打开。
    pub hide_all: bool,
    /// 当前客户端数。
    pub client_count: usize,
}

/// 开始拖动前给手势状态机的上下文，对应 macOS 的 `ThumbnailDragContext`。
#[derive(Debug, Clone, PartialEq)]
pub struct DragContext {
    /// 拖动的起点：未放大的基准 frame。悬停放大时按放大锚点缩回去，否则松开后会把放大的尺寸存下来。
    pub start_frame: ScreenRect,
    /// 当前显示的 frame（可能是放大后的），只用于判断按住的是哪条边。
    pub edge_frame: ScreenRect,
    /// 布局已锁定：忽略移动与缩放。
    pub is_locked: bool,
    /// 是否吸附。
    pub snap_enabled: bool,
    /// 缩放时是否保持宽高比。
    pub lock_aspect_ratio: bool,
    /// 能否缩放：登录与未知客户端只能移动。
    pub allows_resize: bool,
    /// 尺寸下限。
    pub minimum_size: ScreenSize,
    /// 尺寸上限。
    pub maximum_size: ScreenSize,
    /// 吸附目标：其他可见缩略图与各屏幕。
    pub targets: SnapTargets,
}
