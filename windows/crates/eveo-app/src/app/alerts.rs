// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「提醒」页与应用之间的连接。设置读回后与其他页一样以 ConfigEdited 交给协调器；
// 「测试闪烁」是协调器的 TestCombatAlert 事件，不改配置。读游戏日志在 M6 接上。

//! 「提醒」页。

use std::path::PathBuf;
use std::rc::Rc;

use eveo_app_core::Event;
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

/// 自动查找时的日志目录，只用作输入框的提示：EVE 默认写在「文档\EVE\logs」。
/// 真正的查找（文档文件夹被移到别处、OneDrive 等）随读日志的功能在 M6 做。
pub(super) fn automatic_directory() -> String {
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .map(|home| home.join("Documents").join("EVE").join("logs"))
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

    /// 填「提醒」页。只随配置变化，在打开窗口与配置变化时调用。
    pub(super) fn show_alerts(&self, window: &eveo_ui::SettingsWindow) {
        let config = self.coordinator.config();
        if let Some(profile) = config.active_profile() {
            alerts::show_alerts(window, profile, &config.general, &automatic_directory());
        }
    }
}
