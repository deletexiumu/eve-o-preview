// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗规划与滚动规则的用例，对应 macOS 的 OverlayPlannerTests、OverlayFrameEditTests 与 OverlayScrollRulesTests。
// 屏幕的数值与 macOS 的夹具相同（size_scale 为 1），另加一块 150% 的屏幕检查 Windows 的尺寸换算。
// 角色名是虚构的。

mod frame;
mod planner;
mod scroll;

use crate::geometry::{ScreenInfo, ScreenRect};
use crate::model::{ClientIdentity, EveClient, Pid, WindowId};

/// 第一个角色的名字。
pub(super) const PILOT_ALPHA: &str = "Pilot Alpha";
/// 第二个角色的名字。
pub(super) const PILOT_BRAVO: &str = "Pilot Bravo";
/// 第一个客户端的 PID。
pub(super) const PID_A: Pid = 4101;
/// 第二个客户端的 PID。
pub(super) const PID_B: Pid = 4102;
/// 登录界面客户端的 PID。
pub(super) const PID_C: Pid = 4103;

/// 一个客户端；窗口范围对规划没有影响，统一取 1280×720。
pub(super) fn client(id: u64, pid: Pid, identity: ClientIdentity) -> EveClient {
    EveClient {
        id: WindowId(id),
        pid,
        identity,
        window_frame: ScreenRect::new(0.0, 0.0, 1280.0, 720.0),
        is_on_screen: true,
        is_minimized: Some(false),
        is_full_screen: Some(false),
    }
}

/// 已选角色的客户端。
pub(super) fn character(name: &str, id: u64, pid: Pid) -> EveClient {
    client(id, pid, ClientIdentity::Character(name.to_owned()))
}

/// 主屏：1728×1117，顶部 33 被占用（与 macOS 夹具的菜单栏相同），尺寸不换算。
pub(super) fn main_screen() -> ScreenInfo {
    ScreenInfo {
        frame: ScreenRect::new(0.0, 0.0, 1728.0, 1117.0),
        visible_frame: ScreenRect::new(0.0, 33.0, 1728.0, 1084.0),
        scale: 2.0,
        size_scale: 1.0,
        is_main: true,
    }
}

/// 副屏：在主屏左侧，x 为负数，1920×1080，尺寸不换算。
pub(super) fn left_screen() -> ScreenInfo {
    ScreenInfo {
        frame: ScreenRect::new(-1920.0, 0.0, 1920.0, 1080.0),
        visible_frame: ScreenRect::new(-1920.0, 0.0, 1920.0, 1080.0),
        scale: 1.0,
        size_scale: 1.0,
        is_main: false,
    }
}

/// Windows 的 150% 主屏：2560×1440 物理像素，底部 72 像素是任务栏，尺寸乘 1.5。
pub(super) fn scaled_screen() -> ScreenInfo {
    ScreenInfo {
        frame: ScreenRect::new(0.0, 0.0, 2560.0, 1440.0),
        visible_frame: ScreenRect::new(0.0, 0.0, 2560.0, 1368.0),
        scale: 1.5,
        size_scale: 1.5,
        is_main: true,
    }
}
