// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」页「游戏帧率」一组与应用之间的连接：用 NVIDIA 驱动给 exefile.exe 限帧。
// 调度在 eveo_app_core::frame_cap（后台线程、排队、还原记录），规则在 eveo_core::frame_cap，
// 读写驱动在平台层 nvidia 模块；这里只把三者接起来：
// - 启动时与配置变化时把配置里想要的帧数交给控制器（值没变时控制器自己跳过）；
// - 定时器里取走同步结果，状态变了就刷新设置页的开关能否拨与说明。
// 应用退出时不还原：这是驱动设置，开关开着就一直有效，本工具没有运行时也一样；用户关掉开关才还原。

//! 「游戏帧率」：NVIDIA 驱动限帧。

use eveo_app_core::frame_cap::FrameCapController;
use eveo_app_core::paths::DataPaths;
use eveo_core::frame_cap::{DriverState, FrameCapStatus, Plan};
use eveo_platform_win::nvidia;
use eveo_ui::general;

use super::App;

/// 建控制器，还原记录放在本机数据目录。
pub(super) fn controller(paths: &DataPaths) -> FrameCapController {
    FrameCapController::new(driver, paths.frame_cap_record_file())
}

/// 交给控制器的驱动函数：在一个驱动会话里按规则改并保存（见 nvidia::apply）。
fn driver(planner: &mut dyn FnMut(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32> {
    nvidia::apply(|state| planner(state))
}

impl App {
    /// 配置里想要的帧数交给控制器：启动时调一次（顺带检测是不是 NVIDIA），之后每次配置变化都调。
    pub(super) fn frame_cap_config_changed(&mut self) {
        let desired = self
            .coordinator
            .config()
            .general
            .frame_cap
            .as_ref()
            .and_then(|settings| settings.desired_fps());
        self.frame_cap.sync(desired);
    }

    /// 定时器里调用：同步跑完且状态变了时刷新设置页。
    pub(super) fn frame_cap_tick(&mut self) {
        if self.frame_cap.tick()
            && let Some(window) = &self.settings
        {
            self.show_frame_cap(window);
        }
    }

    /// 按控制器的状态填「游戏帧率」一组：开关能否拨，以及开关下方的说明（当前界面语言）。
    pub(super) fn show_frame_cap(&self, window: &eveo_ui::SettingsWindow) {
        let text = eveo_l10n::settings(self.language);
        let status = self.frame_cap.status();
        let note = match status {
            FrameCapStatus::Checking => text.frame_cap_checking().to_owned(),
            FrameCapStatus::NotNvidia => text.frame_cap_not_nvidia().to_owned(),
            // 可用但没有限帧：显示默认说明（做法与关闭时还原）。
            FrameCapStatus::Ready => String::new(),
            FrameCapStatus::Applied(fps) => text.frame_cap_applied(i64::from(fps)),
            FrameCapStatus::NeedsAdmin => text.frame_cap_needs_admin().to_owned(),
            FrameCapStatus::Failed(code) => text.frame_cap_failed(i64::from(code)),
        };
        general::show_frame_cap_status(window, status, &note);
    }
}
