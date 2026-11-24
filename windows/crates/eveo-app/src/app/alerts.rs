// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「提醒」页与应用之间的连接。设置读回后与其他页一样以 ConfigEdited 交给协调器；
// 「测试闪烁」是协调器的 TestCombatAlert 事件，不改配置。
// 游戏日志的跟踪服务也在这里启停：协调器按开关与目录发 WatchGameLogs / StopGameLogs，
// 后台线程的消息由定时器取走，受击事件交回协调器，状态显示在本页的状态行。

//! 「提醒」页。

use std::path::PathBuf;
use std::rc::Rc;

use eveo_app_core::Event;
use eveo_app_core::game_log::{GameLogMessage, GameLogTailer};
use eveo_core::combat_log::{CombatLogStatus, directory};
use eveo_platform_win::known_folders;
use eveo_ui::alerts;
use slint::ComponentHandle;

use super::{App, Input, Runtime, post};

/// 「提醒」页发给应用的输入。
#[derive(Debug, Clone)]
pub(super) enum AlertsInput {
    /// 改了值。
    Edited,
    /// 「测试闪烁」。
    TestFlash,
}

/// 接上页的回调：都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    let model = window.global::<eveo_ui::AlertsModel>();
    let weak = Rc::downgrade(runtime);
    model.on_edited(move || post(&weak, Input::Alerts(AlertsInput::Edited)));
    let weak = Rc::downgrade(runtime);
    model.on_test_flash(move || post(&weak, Input::Alerts(AlertsInput::TestFlash)));
}

/// 自动查找时的日志目录：EVE 写在「文档\EVE\logs」。「文档」按系统的已知文件夹取（可能被移走或由 OneDrive 接管），
/// 取不到时退回 %USERPROFILE%\Documents。
pub(super) fn automatic_directory() -> String {
    known_folders::documents()
        .or_else(|| std::env::var_os("USERPROFILE").map(|home| PathBuf::from(home).join("Documents")))
        .map(|docs| docs.join("EVE").join("logs"))
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| r"Documents\EVE\logs".to_owned())
}

impl App {
    /// 处理「提醒」页的输入。
    pub(super) fn alerts_input(&mut self, input: AlertsInput, runtime: &Rc<Runtime>) {
        match input {
            AlertsInput::Edited => self.alerts_edited(runtime),
            AlertsInput::TestFlash => self.send(Event::TestCombatAlert, runtime),
        }
    }

    /// 读回页面：战斗提醒在当前方案里，日志目录在 general 里。有变化才交给协调器。
    fn alerts_edited(&mut self, runtime: &Rc<Runtime>) {
        let Some(window) = &self.settings else {
            return;
        };
        // 从协调器手里的配置出发，不覆盖期间别处的改动。
        let mut config = self.coordinator.config().clone();
        let mut general = config.general.clone();
        let Some(profile) = config.active_profile_mut() else {
            return;
        };
        alerts::read_alerts(window, profile, &mut general);
        config.general = general;
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
    }

    /// 填「提醒」页。在打开窗口与配置变化时调用；状态行另外随跟踪服务的消息刷新。
    pub(super) fn show_alerts(&self, window: &eveo_ui::SettingsWindow) {
        let config = self.coordinator.config();
        if let Some(profile) = config.active_profile() {
            alerts::show_alerts(window, profile, &config.general, &automatic_directory());
        }
        alerts::show_status(window, &self.combat_status);
    }

    /// 按这个目录设置开始跟踪游戏日志（`None` 是自动查找）。旧的服务先停掉，它没取走的消息随之丢弃。
    pub(super) fn watch_game_logs(&mut self, configured: Option<&str>) {
        self.game_log = None;
        let candidates = directory::candidates(configured, &automatic_directory());
        // 线程建不出来（系统资源耗尽）时按未启用显示，下次配置变化再试。
        self.game_log = GameLogTailer::start(candidates).ok();
        self.set_combat_status(CombatLogStatus::Stopped);
    }

    /// 停止跟踪游戏日志。
    pub(super) fn stop_game_logs(&mut self) {
        self.game_log = None;
        self.set_combat_status(CombatLogStatus::Stopped);
    }

    /// 定时器里调用：取走跟踪服务的消息，受击事件交给协调器，状态显示到「提醒」页。
    pub(super) fn drain_game_log(&mut self, runtime: &Rc<Runtime>) {
        let Some(tailer) = &self.game_log else {
            return;
        };
        for message in tailer.drain() {
            match message {
                GameLogMessage::Events(events) => self.send(Event::CombatEvents(events), runtime),
                GameLogMessage::Status(status) => self.set_combat_status(status),
            }
        }
    }

    /// 记下跟踪服务的状态；设置窗口开着时刷新状态行。
    fn set_combat_status(&mut self, status: CombatLogStatus) {
        super::logging::combat_status_changed(&self.combat_status, &status);
        self.combat_status = status;
        if let Some(window) = &self.settings {
            alerts::show_status(window, &self.combat_status);
        }
    }
}
