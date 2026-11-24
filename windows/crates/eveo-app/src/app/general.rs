// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「通用」与「关于」两页与应用之间的连接。「通用」页的值在配置的 general 里，
// 与「预览与布局」页一样：用户改了任何一项就读回整页，从协调器手里的配置出发组成新配置，有变化才交给协调器。
// 「关于」页只有链接，核对是页上列出的地址后用默认浏览器打开。
// 界面语言：配置的选项求出实际语言（跟随系统时看 Windows 的语言偏好），变了就重填设置窗口的文字，不用重启。

//! 「通用」页与「关于」页。

use std::rc::Rc;

use eveo_app_core::Event;
use eveo_core::model::{AppLanguage, GeneralSettings};
use eveo_platform_win::appearance;
use eveo_ui::general;
use slint::ComponentHandle;

use super::{App, Input, Runtime, post, shell};
use crate::menus;

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

/// 求出界面实际使用的语言。环境变量 `EVEO_LANG`（只用于调试）优先，规则在 Core 的
/// `LanguagePreference::resolved`，与 macOS 相同。
pub(super) fn resolve_language(general: &GeneralSettings) -> AppLanguage {
    let preferred = appearance::preferred_ui_languages();
    let override_code = std::env::var("EVEO_LANG").ok();
    general.language.resolved(&preferred, override_code.as_deref())
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

    /// 把设置窗口的各页整页填一次：打开窗口时，以及换语言后（由 Rust 拼的文字要按新语言重拼）。
    pub(super) fn show_settings_pages(&self, window: &eveo_ui::SettingsWindow) {
        if let Some(profile) = self.coordinator.config().active_profile() {
            eveo_ui::bind::show_previews(window, profile);
            let clients = self.coordinator.registry().clients();
            eveo_ui::bind::show_clients(window, profile, clients, self.coordinator.tray().hide_all);
            self.show_switching(window, profile);
        }
        self.show_profiles(window);
        self.show_general(window);
        self.show_alerts(window);
        self.show_chat(window);
        self.show_environment(window);
    }

    /// 配置变化后重新求界面语言；变了就把设置窗口的文字换成新语言。
    pub(super) fn update_language(&mut self) {
        let language = resolve_language(&self.coordinator.config().general);
        if language == self.language {
            return;
        }
        self.language = language;
        self.thumbnails.set_language(language);
        self.chat_language_changed();
        self.tray
            .set_tooltip(&menus::tray_tooltip(&self.coordinator.tray(), language));
        // 设置窗口：Slint 全局里的文字由 set_language 换；由 Rust 拼的文字（热键的问题提示等）
        // 要把各页重新填一次。
        if let Some(window) = &self.settings {
            eveo_ui::set_language(window, language);
            self.show_settings_pages(window);
        }
    }

    /// 填「通用」与「关于」两页。「通用」页只随配置变化，在打开窗口与配置变化时调用。
    pub(super) fn show_general(&self, window: &eveo_ui::SettingsWindow) {
        let logs = self.logs_dir.display().to_string();
        general::show_general(window, &self.coordinator.config().general, &logs);
        general::show_about(window);
    }
}
