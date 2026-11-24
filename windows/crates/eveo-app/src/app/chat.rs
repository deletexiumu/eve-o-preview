// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「预警」「翻译」两页与应用之间的连接。读回的设置与其他页一样以 ConfigEdited 交给协调器：
// - 标量的值整页读回（预警在当前方案的 intel；翻译在 translation，模型服务在 general.translationEndpoint）。
// - 频道的增删与「恢复默认位置」是动作，直接改协调器手里那份配置的副本。
// 「翻译」页的按钮（Key、测试、重试、清空缓存）与运行时状态在 translation 模块里。

//! 「预警」与「翻译」两页。

use std::rc::Rc;

use eveo_app_core::Event;
use eveo_core::model::{AppConfig, Profile};
use eveo_ui::chat::{self, ChannelEdit};
use slint::ComponentHandle;

use super::{App, Input, Runtime, post};

/// 哪一页：两页的频道列表与浮窗设置结构相同，动作带上页名区分。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ChatPage {
    /// 「预警」页，改 intel。
    Intel,
    /// 「翻译」页，改 translation。
    Translation,
}

/// 两页发给应用的输入。
#[derive(Debug, Clone)]
pub(super) enum ChatInput {
    /// 改了某个值，整页读回。
    Edited(ChatPage),
    /// 频道列表的增删。
    Channel(ChatPage, ChannelEdit),
    /// 「恢复默认位置」：浮窗的位置回到默认（frame 清空）。
    ResetFrame(ChatPage),
}

/// 接上两页的回调：都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    // 只带页名的回调（edited、恢复默认位置）用同一个闭包工厂；带参数的回调各写一个。
    let send = |runtime: &Rc<Runtime>, make: fn(ChatPage) -> ChatInput, page: ChatPage| {
        let weak = Rc::downgrade(runtime);
        move || post(&weak, Input::Chat(make(page)))
    };
    let intel = window.global::<eveo_ui::IntelModel>();
    intel.on_edited(send(runtime, ChatInput::Edited, ChatPage::Intel));
    intel.on_reset_overlay_frame(send(runtime, ChatInput::ResetFrame, ChatPage::Intel));
    let weak = Rc::downgrade(runtime);
    // 下标是 Slint 的 int；负数不会出现，转换失败时忽略。
    intel.on_remove_channel(move |index| {
        if let Ok(index) = usize::try_from(index) {
            post(
                &weak,
                Input::Chat(ChatInput::Channel(ChatPage::Intel, ChannelEdit::Remove(index))),
            );
        }
    });
    let weak = Rc::downgrade(runtime);
    intel.on_add_channel(move |name| {
        let edit = ChannelEdit::AddName(name.to_string());
        post(&weak, Input::Chat(ChatInput::Channel(ChatPage::Intel, edit)));
    });

    let translation = window.global::<eveo_ui::TranslationModel>();
    translation.on_edited(send(runtime, ChatInput::Edited, ChatPage::Translation));
    translation.on_reset_overlay_frame(send(runtime, ChatInput::ResetFrame, ChatPage::Translation));
    let weak = Rc::downgrade(runtime);
    translation.on_remove_channel(move |index| {
        if let Ok(index) = usize::try_from(index) {
            let edit = ChannelEdit::Remove(index);
            post(
                &weak,
                Input::Chat(ChatInput::Channel(ChatPage::Translation, edit)),
            );
        }
    });
    let weak = Rc::downgrade(runtime);
    translation.on_add_channel(move |name| {
        let edit = ChannelEdit::AddName(name.to_string());
        post(
            &weak,
            Input::Chat(ChatInput::Channel(ChatPage::Translation, edit)),
        );
    });
    let weak = Rc::downgrade(runtime);
    translation.on_add_built_in(move |index| {
        if let Ok(index) = usize::try_from(index) {
            let edit = ChannelEdit::AddBuiltIn(index);
            post(
                &weak,
                Input::Chat(ChatInput::Channel(ChatPage::Translation, edit)),
            );
        }
    });
}

impl App {
    /// 处理两页的输入：在协调器手里那份配置的副本上改，有变化才交给协调器（不覆盖期间别处的改动）。
    pub(super) fn chat_input(&mut self, input: ChatInput, runtime: &Rc<Runtime>) {
        let Some(window) = &self.settings else {
            return;
        };
        let mut config = self.coordinator.config().clone();
        let provider = config.general.translation_endpoint.provider;
        // 每种输入只改自己的那部分；没有当前方案（配置还没加载好）时什么也不改。
        match input {
            ChatInput::Edited(ChatPage::Intel) => {
                with_profile(&mut config, |profile| {
                    chat::read_intel(window, &mut profile.intel)
                });
            }
            ChatInput::Edited(ChatPage::Translation) => {
                // 模型服务在 general 里，与方案分开：借用规则不允许同时借 config 的两部分，先取出副本再放回。
                let mut endpoint = config.general.translation_endpoint.clone();
                with_profile(&mut config, |profile| {
                    chat::read_translation(window, &mut profile.translation, &mut endpoint);
                });
                config.general.translation_endpoint = endpoint;
            }
            ChatInput::Channel(page, edit) => with_profile(&mut config, |profile| {
                let channels = match page {
                    ChatPage::Intel => &mut profile.intel.channels,
                    ChatPage::Translation => &mut profile.translation.channels,
                };
                chat::apply_channel_edit(channels, &edit);
            }),
            // 浮窗下次显示时按默认位置摆放（M6 的浮窗按 frame 为空取默认位置）。
            ChatInput::ResetFrame(page) => with_profile(&mut config, |profile| match page {
                ChatPage::Intel => profile.intel.overlay.frame = None,
                ChatPage::Translation => profile.translation.overlay.frame = None,
            }),
        }
        // 换了服务预设：Key 的输入框与测试结果属于旧预设，先清掉。
        if config.general.translation_endpoint.provider != provider {
            self.translation_provider_changed();
        }
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
    }

    /// 填两页。只随配置变化，在打开窗口与配置变化时调用。
    pub(super) fn show_chat(&self, window: &eveo_ui::SettingsWindow) {
        // 两页都只看当前方案：切换方案后显示新方案的预警与翻译设置；模型服务对全部方案相同。
        let config = self.coordinator.config();
        if let Some(profile) = config.active_profile() {
            chat::show_intel(window, &profile.intel);
            chat::show_intel_status(window, self.chat_log_status());
            chat::show_translation(window, &profile.translation, &config.general.translation_endpoint);
        }
        // 运行时的状态整组重填：接口设置、Key 是否已保存与各段文字都可能随配置或界面语言变。
        self.show_translation_page_again();
    }
}

/// 对当前方案做一次修改；没有当前方案时什么也不做。
fn with_profile(config: &mut AppConfig, edit: impl FnOnce(&mut Profile)) {
    if let Some(profile) = config.active_profile_mut() {
        edit(profile);
    }
}
