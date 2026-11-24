// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页的运行时部分与手动位置的保存，对应 macOS 的 SettingsViewModel+Intel.swift 与
// IntelFeedController 里 state.json 的读写：
// - 页上的按钮：给某个角色手动设星系、清除某个角色的位置、清空人名缓存。都转成输入排队，在应用的循环里执行。
// - 页上的状态：在线角色的位置、参考星系查不到、人名核对状态与缓存条数、星图数据。每次定时器都算一份，
//   与上一次不同才交给界面（位置的「多久以前」与核对的等待秒数随时间变）。
// - 手动位置：预警控制器在手动位置变了时（手动设置、清除、或被新的线索覆盖）标记，这里取走写进 state.json。
//   写盘失败只影响重启后的恢复，不提示用户（与 macOS 相同，写盘失败只记日志；诊断日志接上前直接丢掉）。
// 隐私：角色名只进 state.json（留在本机，不进问题报告），不写日志。

//! 「预警」页的位置、人名核对与星图数据。

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use eveo_app_core::chat::intel_page::IntelPageState;
use eveo_core::overlay::OverlayKind;
use eveo_ui::intel::{IntelView, LocationView, show_intel_view};
use slint::ComponentHandle;

use super::intel::wall_clock;
use super::{App, Input, Runtime, post};

/// 「预警」页的按钮。
#[derive(Debug, Clone)]
pub(super) enum IntelAction {
    /// 给某个角色手动设星系（角色名、输入的星系名）。
    SetLocation(String, String),
    /// 清除某个角色的位置。
    ClearLocation(String),
    /// 「清空人名缓存」。
    ClearPilotCache,
}

/// 「预警」页在应用里的状态：控制器之外、只给页面显示的几项。
#[derive(Debug, Default)]
pub(super) struct IntelPage {
    /// 上次输入的星系名查不到的角色，行下显示提示；设置成功或清除后去掉。
    not_found: BTreeSet<String>,
    /// 各角色设置成功的次数：交给页面后，那一行的输入框随之清空（查不到时不清，留着输错的文字）。
    cleared: BTreeMap<String, i32>,
    /// 上一次交给界面的状态，没变时不再交。填页面的方法只借用应用，所以放在 RefCell 里。
    shown: RefCell<Option<IntelView>>,
}

/// 接上「预警」页的按钮：都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    let model = window.global::<eveo_ui::IntelModel>();
    let weak = Rc::downgrade(runtime);
    model.on_set_location(move |character, system| {
        let action = IntelAction::SetLocation(character.to_string(), system.to_string());
        post(&weak, Input::IntelPage(action));
    });
    let weak = Rc::downgrade(runtime);
    model.on_clear_location(move |character| {
        post(
            &weak,
            Input::IntelPage(IntelAction::ClearLocation(character.to_string())),
        );
    });
    let weak = Rc::downgrade(runtime);
    model.on_clear_pilot_cache(move || post(&weak, Input::IntelPage(IntelAction::ClearPilotCache)));
}

impl App {
    /// 执行「预警」页的一个按钮，然后保存手动位置、刷新页面与预警浮窗（位置变了，跳数跟着变）。
    pub(super) fn intel_action(&mut self, action: IntelAction) {
        let now = wall_clock();
        let intel = self.chat.features.intel_mut();
        match action {
            IntelAction::SetLocation(character, system) => {
                // 空白的输入不做任何事（页上已挡过一次）。
                let system = system.trim();
                if system.is_empty() {
                    return;
                }
                // 查不到（或星图数据还没读完）时只在行下提示，记录不变。
                if intel.set_manual_location(&character, system, now) {
                    self.chat.intel_page.not_found.remove(&character);
                    let cleared = self.chat.intel_page.cleared.entry(character).or_default();
                    *cleared = cleared.wrapping_add(1);
                } else {
                    self.chat.intel_page.not_found.insert(character);
                }
            }
            IntelAction::ClearLocation(character) => {
                intel.clear_manual_location(&character, now);
                self.chat.intel_page.not_found.remove(&character);
            }
            // 清空后已核对过的人名再出现时会重新联网查。
            IntelAction::ClearPilotCache => intel.clear_pilot_cache(now),
        }
        self.save_manual_locations();
        self.show_intel_page();
        self.refresh_overlay(OverlayKind::Intel);
    }

    /// 手动位置变了时写进 state.json。在每次定时器取完日志事件之后、与页上的按钮之后调用。
    pub(super) fn save_manual_locations(&mut self) {
        let Some(manual) = self.chat.features.intel_mut().take_manual_locations() else {
            return;
        };
        // 写盘失败时内存里的记录照常用，下次变化时再写（诊断日志接上之前不记）。
        let _ = self.chat.state.set_manual_locations(manual);
    }

    /// 设置窗口开着时算一份「预警」页的运行时状态，与上一次不同才交给界面。
    pub(super) fn show_intel_page(&self) {
        let Some(window) = &self.settings else {
            return;
        };
        let view = self.intel_view();
        let mut shown = self.chat.intel_page.shown.borrow_mut();
        if shown.as_ref() == Some(&view) {
            return;
        }
        show_intel_view(window, &view);
        *shown = Some(view);
    }

    /// 不管上一次是什么，整组重填一次（打开窗口、换界面语言之后）。
    pub(super) fn show_intel_page_again(&self) {
        self.chat.intel_page.shown.take();
        self.show_intel_page();
    }

    /// 「预警」页的运行时状态：总控算好的文字，加上应用记着的「查不到」。
    fn intel_view(&self) -> IntelView {
        let state: IntelPageState = self
            .chat
            .features
            .intel_page(&self.online_characters(), wall_clock());
        let not_found = &self.chat.intel_page.not_found;
        let cleared = &self.chat.intel_page.cleared;
        IntelView {
            locations: state
                .locations
                .into_iter()
                .map(|row| LocationView {
                    not_found: not_found.contains(&row.name),
                    cleared: cleared.get(&row.name).copied().unwrap_or_default(),
                    name: row.name,
                    text: row.text,
                    has_location: row.has_location,
                })
                .collect(),
            reference_not_found: state.reference_not_found,
            pilot_status: state.pilot_status.unwrap_or_default(),
            pilot_cache: state.pilot_cache.unwrap_or_default(),
            static_data: state.static_data,
        }
    }

    /// 在线的角色：当前登记里有角色名的客户端（登录界面的客户端没有角色名，不列）。
    fn online_characters(&self) -> Vec<String> {
        self.coordinator
            .registry()
            .clients()
            .iter()
            .filter_map(|client| client.character_name().map(str::to_owned))
            .collect()
    }
}
