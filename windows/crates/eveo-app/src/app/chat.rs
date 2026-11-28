// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「预警」「翻译」两页与应用之间的连接。读回的设置与其他页一样以 ConfigEdited 交给协调器：
// - 标量的值整页读回（预警在当前方案的 intel；翻译在 translation，模型服务在 general.translationEndpoint）。
// - 频道的增删与「恢复默认位置」是动作，直接改协调器手里那份配置的副本。
// 「翻译」页的按钮（Key、测试、重试、清空缓存）与运行时状态在 translation 模块里。

//! 「预警」与「翻译」两页。

use std::rc::Rc;
use std::sync::mpsc;

use eveo_app_core::Event;
use eveo_app_core::chat_log::discovery::discover_channels;
use eveo_core::model::{AppConfig, Profile};
use eveo_ui::chat::{self, ChannelEdit};
use slint::ComponentHandle;

use super::alerts::automatic_directory;
use super::intel::wall_clock;
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
    /// 添加「从日志添加」里的第几个频道（页上的下标，不含提示文字）。
    AddDiscovered(ChatPage, usize),
    /// 重新扫描日志目录里最近出现过的频道（切到页面、点「刷新」）。
    RefreshDiscovered,
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

    let weak = Rc::downgrade(runtime);
    intel.on_add_discovered(move |index| {
        if let Ok(index) = usize::try_from(index) {
            post(
                &weak,
                Input::Chat(ChatInput::AddDiscovered(ChatPage::Intel, index)),
            );
        }
    });
    let weak = Rc::downgrade(runtime);
    intel.on_refresh_discovered(move || post(&weak, Input::Chat(ChatInput::RefreshDiscovered)));

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
    translation.on_add_discovered(move |index| {
        if let Ok(index) = usize::try_from(index) {
            let input = ChatInput::AddDiscovered(ChatPage::Translation, index);
            post(&weak, Input::Chat(input));
        }
    });
    let weak = Rc::downgrade(runtime);
    translation.on_refresh_discovered(move || post(&weak, Input::Chat(ChatInput::RefreshDiscovered)));
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
        // 扫描不改配置，单独处理。
        if matches!(input, ChatInput::RefreshDiscovered) {
            self.refresh_discovered();
            return;
        }
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
            // 下标按页上显示时的同一份列表换回频道；列表已变（别处刚加过）时越界，什么也不做。
            ChatInput::AddDiscovered(page, index) => with_profile(&mut config, |profile| {
                let channels = match page {
                    ChatPage::Intel => &mut profile.intel.channels,
                    ChatPage::Translation => &mut profile.translation.channels,
                };
                let discovered = self.chat.discovered.as_deref().unwrap_or_default();
                if let Some(found) = chat::discovered_choices(discovered, channels).get(index) {
                    let edit = ChannelEdit::AddRef(found.channel_ref());
                    chat::apply_channel_edit(channels, &edit);
                }
            }),
            ChatInput::RefreshDiscovered => {}
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
        self.show_discovered();
        // 运行时的状态整组重填：接口设置、Key 是否已保存与各段文字都可能随配置或界面语言变。
        self.show_translation_page_again();
        self.show_intel_page_again();
    }
}

impl App {
    /// 在后台线程里扫描日志目录（读几十到几百个文件的开头），结果在定时器里取回。正在扫描时不再开一个。
    pub(super) fn refresh_discovered(&mut self) {
        if self.chat.discovery.is_some() {
            return;
        }
        let configured = self.coordinator.config().general.eve_log_directory.clone();
        let automatic = automatic_directory();
        let (sender, receiver) = mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("chat-discovery".to_owned())
            .spawn(move || {
                // 设置窗口关了、应用退出时接收端已丢掉，发送失败无妨。
                let _ = sender.send(discover_channels(configured.as_deref(), &automatic, wall_clock()));
            });
        // 线程建不出来（系统资源耗尽）时不扫描，下次切页或点「刷新」再试。
        if spawned.is_ok() {
            self.chat.discovery = Some(receiver);
        }
    }

    /// 定时器里调用：扫描完成时记下结果并填两页；扫描线程意外结束时放弃这一次。
    pub(super) fn take_discovered(&mut self) {
        let Some(receiver) = &self.chat.discovery else {
            return;
        };
        match receiver.try_recv() {
            Ok(found) => {
                self.chat.discovery = None;
                self.chat.discovered = Some(found);
                self.show_discovered();
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => self.chat.discovery = None,
        }
    }

    /// 把发现的频道填进两页的下拉框（各自去掉已选的）；设置窗口没开或没有当前方案时什么也不做。
    pub(super) fn show_discovered(&self) {
        let (Some(window), Some(profile)) = (&self.settings, self.coordinator.config().active_profile())
        else {
            return;
        };
        chat::show_discovered(
            window,
            self.chat.discovered.as_deref(),
            &profile.intel.channels,
            &profile.translation.channels,
        );
    }
}

/// 对当前方案做一次修改；没有当前方案时什么也不做。
fn with_profile(config: &mut AppConfig, edit: impl FnOnce(&mut Profile)) {
    if let Some(profile) = config.active_profile_mut() {
        edit(profile);
    }
}
