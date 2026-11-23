// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「通用」与「关于」两页与应用之间的连接。「通用」页的值在配置的 general 里，
// 与「预览与布局」页一样：用户改了任何一项就读回整页，从协调器手里的配置出发组成新配置，有变化才交给协调器。
// 「关于」页只有链接，核对是页上列出的地址后用默认浏览器打开。

//! 「通用」页与「关于」页。

use std::rc::Rc;

use eveo_app_core::Event;
use eveo_ui::general;
use slint::ComponentHandle;

use super::{App, Input, Runtime, post, shell};

/// 「通用」与「关于」页发给应用的输入。
#[derive(Debug, Clone)]
pub(super) enum GeneralInput {
    /// 「通用」页改了值。
    Edited,
    /// 在资源管理器里显示日志文件夹。
    RevealLogs,
    /// 「关于」页的链接。
    OpenUrl(String),
}

/// 接上两页的回调：都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    let sender = |runtime: &Rc<Runtime>| {
        let weak = Rc::downgrade(runtime);
        move |input: GeneralInput| post(&weak, Input::General(input))
    };
    let model = window.global::<eveo_ui::GeneralModel>();
    let send = sender(runtime);
    model.on_edited(move || send(GeneralInput::Edited));
    let send = sender(runtime);
    model.on_reveal_logs(move || send(GeneralInput::RevealLogs));
    let send = sender(runtime);
    // 地址在处理时再核对，回调里只转交。
    window
        .global::<eveo_ui::AboutModel>()
        .on_open_url(move |url| send(GeneralInput::OpenUrl(url.into())));
}

impl App {
    /// 处理「通用」与「关于」页的输入。
    pub(super) fn general_input(&mut self, input: GeneralInput, runtime: &Rc<Runtime>) {
        match input {
            GeneralInput::Edited => self.general_edited(runtime),
            GeneralInput::RevealLogs => shell::reveal(&self.logs_dir),
            // 只打开「关于」页上列出的地址。
            GeneralInput::OpenUrl(url) if general::is_about_link(&url) => shell::open_url(&url),
            GeneralInput::OpenUrl(_) => {}
        }
    }

    /// 读回「通用」页，有变化才交给协调器。
    fn general_edited(&mut self, runtime: &Rc<Runtime>) {
        let Some(window) = &self.settings else {
            return;
        };
        let mut config = self.coordinator.config().clone();
        general::read_general(window, &mut config.general);
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
    }

    /// 填「通用」与「关于」两页。「通用」页只随配置变化，在打开窗口与配置变化时调用。
    pub(super) fn show_general(&self, window: &eveo_ui::SettingsWindow) {
        let logs = self.logs_dir.display().to_string();
        general::show_general(window, &self.coordinator.config().general, &logs);
        general::show_about(window);
    }
}
