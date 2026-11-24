// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「切换与热键」页与应用之间的连接：页上的改动（循环组、热键行、作用范围）与热键的录制。
// 改动与其他页一样作用到协调器手里那份配置的副本上，有变化才以 ConfigEdited 交给协调器。
// 录制期间暂停全部热键，录到结果、按 Esc 或设置窗口失去前台时结束（与 macOS 的录制按钮相同）。

//! 「切换与热键」页。

use std::rc::Rc;

use eveo_app_core::Event;
use eveo_core::hotkeys::HotkeyScope;
use eveo_platform_win::events::foreground_window;
use eveo_platform_win::recorder::{HotkeyRecorder, RecordOutcome};
use eveo_ui::switching;
use slint::ComponentHandle;

use super::{App, Input, Runtime, post, window_hwnd};

/// 接上「切换与热键」页的回调：每个回调都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    use switching::SwitchingEdit as Edit;
    let model = window.global::<eveo_ui::SwitchingModel>();
    // 每个回调持有自己的弱引用；回调里只做参数换算，位置标识解析不了（不应出现）时丢弃这次操作。
    let sender = |runtime: &Rc<Runtime>| {
        let weak = Rc::downgrade(runtime);
        move |edit: Edit| post(&weak, Input::SwitchingEdit(edit))
    };
    let send = sender(runtime);
    // 默认作用范围：单选的下标 0 是全局，1 是仅游戏内。
    model.on_default_scope_changed(move |index| {
        let scope = if index == 1 {
            HotkeyScope::Game
        } else {
            HotkeyScope::Global
        };
        send(Edit::DefaultScope(scope));
    });
    let send = sender(runtime);
    // 新建循环组：id 在这里生成，绑定层只负责写进配置，测试里可以用固定的 id。
    model.on_add_group(move || send(Edit::AddGroup(switching::new_group_id())));
    let send = sender(runtime);
    // 改名在回车或离开输入框时提交；空白名称由绑定层拒绝。
    model.on_rename_group(move |id, name| {
        send(Edit::RenameGroup {
            id: id.into(),
            name: name.into(),
        });
    });
    let send = sender(runtime);
    // 删除不再确认，与 macOS 一致。
    model.on_delete_group(move |id| send(Edit::DeleteGroup(id.into())));
    let send = sender(runtime);
    model.on_add_member(move |id, name| {
        // 下拉框里在线的角色带「 ●」后缀，去掉后才是角色名。
        let name = name.strip_suffix(" ●").unwrap_or(&name).to_owned();
        send(Edit::AddMember { id: id.into(), name });
    });
    let send = sender(runtime);
    // Slint 的整数是 i32；负的位置不应出现，出现时丢弃。
    model.on_move_member(move |id, index, delta| {
        if let Ok(index) = usize::try_from(index) {
            send(Edit::MoveMember {
                id: id.into(),
                index,
                delta,
            });
        }
    });
    let send = sender(runtime);
    model.on_remove_member(move |id, index| {
        if let Ok(index) = usize::try_from(index) {
            send(Edit::RemoveMember { id: id.into(), index });
        }
    });
    let send = sender(runtime);
    // 移除与改范围都按「位置 + 原文」定位，原文已不在列表里时绑定层什么也不做。
    model.on_remove_hotkey(move |slot, text| {
        if let Some(slot) = switching::Slot::parse(&slot) {
            send(Edit::RemoveHotkey {
                slot,
                text: text.into(),
            });
        }
    });
    let send = sender(runtime);
    model.on_set_scope(move |slot, text, index| {
        // 下拉框的顺序：跟随默认、全局、仅游戏内。
        let scope = match index {
            1 => Some(HotkeyScope::Global),
            2 => Some(HotkeyScope::Game),
            _ => None,
        };
        if let Some(slot) = switching::Slot::parse(&slot) {
            send(Edit::SetScope {
                slot,
                text: text.into(),
                scope,
            });
        }
    });
    let weak = Rc::downgrade(runtime);
    // 录制按钮不改配置，只切换录制状态，单独走一个输入。
    model.on_record(move |slot, text| post(&weak, Input::Record(slot.into(), text.into())));
}

impl App {
    /// 「切换与热键」页上的改动：与其他页一样从协调器手里的配置出发，有变化才交给协调器。
    pub(super) fn switching_edited(&mut self, edit: &switching::SwitchingEdit, runtime: &Rc<Runtime>) {
        let mut config = self.coordinator.config().clone();
        let Some(profile) = config.active_profile_mut() else {
            return;
        };
        switching::apply_switching_edit(profile, edit);
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
    }

    /// 点了录制按钮：正在录这一行时取消；否则结束别的录制，开始录这一行。录制期间暂停全部热键。
    pub(super) fn toggle_recording(&mut self, slot: &str, text: String) {
        let Some(slot) = switching::Slot::parse(slot) else {
            return;
        };
        // 再点正在录制的那个按钮等于取消，与 macOS 的录制按钮相同。
        let same = self
            .recording
            .as_ref()
            .is_some_and(|(s, t, _)| *s == slot && *t == text);
        self.stop_recording();
        // 钩子装不上（极少见）时不进入录制状态，按钮保持原样。
        if !same && let Ok(recorder) = HotkeyRecorder::start() {
            self.hotkeys.set_suspended(true);
            self.recording = Some((slot, text, recorder));
        }
        self.refresh_settings_pages();
    }

    /// 结束录制：摘掉钩子，恢复热键。
    pub(super) fn stop_recording(&mut self) {
        if self.recording.take().is_some() {
            self.hotkeys.set_suspended(false);
        }
    }

    /// 定时器里检查录制：有结果时写进配置；设置窗口不在前台（切到了别的程序）时取消，
    /// 否则热键会一直暂停（同 macOS 在设置窗口失去焦点时取消录制）。
    pub(super) fn check_recording(&mut self, runtime: &Rc<Runtime>) {
        let Some((slot, text, recorder)) = &self.recording else {
            return;
        };
        // 先取结果再看前台：按下组合键的同时切走了窗口，录到的结果仍然有效。
        let outcome = recorder.take_outcome();
        // 设置窗口的句柄在显示后才有；取不到时按不在前台处理，录制随即取消。
        let settings_foreground = self
            .settings
            .as_ref()
            .and_then(|window| window_hwnd(window.window()))
            .is_some_and(|hwnd| foreground_window() == Some(eveo_platform_win::window_id(hwnd)));
        if outcome.is_none() && settings_foreground {
            return;
        }
        let edit = match outcome {
            Some(RecordOutcome::Recorded(hotkey)) => Some(switching::SwitchingEdit::Recorded {
                slot: slot.clone(),
                text: text.clone(),
                hotkey,
            }),
            // 清除只对已有的一行有意义；新增时按 Backspace 等于取消。
            Some(RecordOutcome::Cleared) if !text.is_empty() => {
                Some(switching::SwitchingEdit::RemoveHotkey {
                    slot: slot.clone(),
                    text: text.clone(),
                })
            }
            _ => None,
        };
        self.stop_recording();
        match edit {
            Some(edit) => self.switching_edited(&edit, runtime),
            // 没有改动时也要刷新一次，按钮从「按下组合键…」恢复原样。
            None => self.refresh_settings_pages(),
        }
    }
}
