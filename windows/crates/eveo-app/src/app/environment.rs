// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「环境检查」页与应用之间的连接。页上没有设置，只有检查结果与两个按钮：
// - 权限：本工具是否以管理员运行在启动时读一次（运行中不会变）；以管理员运行的客户端在每次轮询时
//   从候选窗口的进程信息里记下 PID，显示时按协调器的登记表换成名字，与「客户端」页一致。
// - 日志目录：读磁盘，只在打开窗口、配置变化与「重新检查」时查。
// 「在资源管理器中显示」打开日志目录；目录不在时 shell::reveal 打开最近的上一级。

//! 「环境检查」页。

use std::path::Path;
use std::rc::Rc;

use eveo_platform_win::events::local_timestamp;
use eveo_ui::environment;
use slint::ComponentHandle;

use super::{App, Input, Runtime, alerts, post, shell};

/// 「环境检查」页发给应用的输入。
#[derive(Debug, Clone, Copy)]
pub(super) enum EnvironmentInput {
    /// 「重新检查」。
    Recheck,
    /// 在资源管理器里打开日志目录。
    RevealLogs,
}

/// 接上页的回调：转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    let model = window.global::<eveo_ui::EnvironmentModel>();
    let weak = Rc::downgrade(runtime);
    model.on_recheck(move || post(&weak, Input::Environment(EnvironmentInput::Recheck)));
    let weak = Rc::downgrade(runtime);
    model.on_reveal_logs(move || post(&weak, Input::Environment(EnvironmentInput::RevealLogs)));
}

impl App {
    /// 处理页的输入。重新检查时也立即轮询一次：刚以别的权限重启的客户端马上反映出来。
    pub(super) fn environment_input(&mut self, input: EnvironmentInput) {
        match input {
            EnvironmentInput::Recheck => {
                self.poll_at = std::time::Instant::now();
                if let Some(window) = &self.settings {
                    self.show_environment(window);
                }
            }
            EnvironmentInput::RevealLogs => shell::reveal(Path::new(&self.log_root())),
        }
    }

    /// 用到的日志目录：设置的或自动查找的位置，填成子文件夹时取上一级。
    fn log_root(&self) -> String {
        let configured = self.coordinator.config().general.eve_log_directory.as_deref();
        environment::log_root(configured, &alerts::automatic_directory())
    }

    /// 填整页，包括读磁盘的日志目录检查。在打开窗口、配置变化与「重新检查」时调用。
    pub(super) fn show_environment(&self, window: &eveo_ui::SettingsWindow) {
        self.show_privileges(window);
        let folders = environment::check_log_folders(&self.log_root());
        environment::show_logs(window, &folders, &time_of_day(&local_timestamp()));
    }

    /// 只填权限部分，不碰磁盘：每批事件之后调一次，客户端的启动与退出随即反映出来。
    pub(super) fn show_privileges(&self, window: &eveo_ui::SettingsWindow) {
        // 按登记表的顺序列名字，与「客户端」页的顺序一致；还没登记的进程（刚启动）等下次轮询。
        let names: Vec<String> = self
            .coordinator
            .registry()
            .clients()
            .iter()
            .filter(|client| self.elevated_pids.contains(&client.pid))
            .map(|client| client.display_title())
            .collect();
        environment::show_privileges(window, self.self_elevated, &names);
    }
}

/// 从平台层的本地时间戳（`YYYYMMDD-HHMMSS`）取出「时:分:秒」。格式不对时（不应出现）原样返回。
fn time_of_day(timestamp: &str) -> String {
    match timestamp.split_once('-') {
        Some((_, hms)) if hms.len() == 6 && hms.is_ascii() => {
            format!("{}:{}:{}", &hms[0..2], &hms[2..4], &hms[4..6])
        }
        _ => timestamp.to_owned(),
    }
}
