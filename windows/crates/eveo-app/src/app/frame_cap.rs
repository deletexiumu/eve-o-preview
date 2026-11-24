// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」页「游戏帧率」一组与应用之间的连接：用显卡驱动给 EVE 客户端限帧。
// 调度在 eveo_app_core::frame_cap（后台线程、排队、还原记录），规则在 eveo_core::frame_cap，
// 读写驱动在平台层（nvidia、amd、intel 模块）；这里只把它们接起来：
// - 一次同步先试 NVIDIA（进程内，已实测）；没有 NVIDIA 时起子进程试 AMD 与 Intel（见 frame_cap_helper）；
// - 启动时把配置里想要的帧数立即交给控制器；配置变化时推迟约 1 秒再交（打字时只写最终值，值没变时控制器自己跳过）；
// - 定时器里取走同步结果，状态变了就刷新设置页的开关能否拨与说明。
// 应用退出时不还原：这是驱动设置，开关开着就一直有效，本工具没有运行时也一样；用户关掉开关才还原。

//! 「游戏帧率」：显卡驱动限帧。

use std::path::Path;

use eveo_app_core::frame_cap::{FrameCapController, run_nvidia};
use eveo_app_core::paths::DataPaths;
use eveo_core::frame_cap::{DriverState, Plan, SyncError, SyncReport, Vendor};
use eveo_platform_win::nvidia;
use eveo_ui::general;

use super::App;

/// 建控制器，还原记录放在本机数据目录。
pub(super) fn controller(paths: &DataPaths) -> FrameCapController {
    let nvidia_record = paths.frame_cap_record_file(Vendor::Nvidia);
    FrameCapController::new(move |desired| sync(&nvidia_record, desired))
}

/// 一次同步（在控制器的后台线程里）：先 NVIDIA，没有 NVIDIA 时交给子进程试 AMD 与 Intel。
fn sync(nvidia_record: &Path, desired: Option<u32>) -> SyncReport {
    match run_nvidia(driver, nvidia_record, desired) {
        Err(SyncError::Unsupported) => crate::frame_cap_helper::spawn(desired),
        result => SyncReport {
            vendor: Some(Vendor::Nvidia),
            result,
        },
    }
}

/// NVIDIA 的驱动函数：在一个驱动会话里按规则改并保存（见 nvidia::apply）。
fn driver(planner: &mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32> {
    nvidia::apply(|state| planner(state))
}

impl App {
    /// 启动时把配置里想要的帧数立即交给控制器（顺带检测是哪家显卡）。
    pub(super) fn frame_cap_start(&mut self) {
        let desired = self.desired_frame_cap();
        self.frame_cap.sync(desired);
    }

    /// 配置变化后：推迟一会儿再同步，连续的改动只写最后的值。
    pub(super) fn frame_cap_config_changed(&mut self) {
        let desired = self.desired_frame_cap();
        self.frame_cap.sync_later(desired, std::time::Instant::now());
    }

    /// 配置里想要的帧数：打开时是夹到范围内的帧数，关闭或没设置过时为 `None`。
    fn desired_frame_cap(&self) -> Option<u32> {
        self.coordinator
            .config()
            .general
            .frame_cap
            .as_ref()
            .and_then(|settings| settings.desired_fps())
    }

    /// 定时器里调用：同步跑完且状态变了时刷新设置页。
    pub(super) fn frame_cap_tick(&mut self) {
        if self.frame_cap.tick(std::time::Instant::now())
            && let Some(window) = &self.settings
        {
            self.show_frame_cap(window);
        }
    }

    /// 按控制器的状态与显卡厂商填「游戏帧率」一组：开关能否拨、说明、AMD 的红字警告（当前界面语言）。
    pub(super) fn show_frame_cap(&self, window: &eveo_ui::SettingsWindow) {
        general::show_frame_cap_status(
            window,
            self.frame_cap.status(),
            self.frame_cap.vendor(),
            self.language,
        );
    }
}
