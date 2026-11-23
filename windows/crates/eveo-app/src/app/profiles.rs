// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口「配置方案」页与应用之间的连接：回调排队、名称校验、操作作用到配置，以及在资源管理器里显示配置文件。
// 与其他页一样，改动从协调器手里的配置出发，有变化才以 ConfigEdited 交给协调器；切换方案也是一次配置改动，
// 协调器据此清掉跳过名单、重建热键（见 Coordinator::update_config）。

//! 「配置方案」页。

use std::rc::Rc;

use eveo_app_core::Event;
use eveo_app_core::config_store::new_profile;
use eveo_core::config::new_id;
use eveo_ui::profiles::{self, ProfileEdit};
use slint::ComponentHandle;

use super::{App, Input, Runtime, post, shell};

/// 「配置方案」页发给应用的输入。
#[derive(Debug, Clone)]
pub(super) enum ProfilesInput {
    /// 一个不需要名称的操作（切换、删除）。
    Edit(ProfileEdit),
    /// 名称输入框变了：重新校验。
    NameEdited,
    /// 点了确定（新建、改名、复制）。
    ConfirmName,
    /// 在资源管理器里显示配置文件。
    Reveal,
}

/// 接上页的回调：都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    let model = window.global::<eveo_ui::ProfilesModel>();
    // 每个回调持有自己的弱引用。
    let sender = |runtime: &Rc<Runtime>| {
        let weak = Rc::downgrade(runtime);
        move |input: ProfilesInput| post(&weak, Input::Profiles(input))
    };
    let send = sender(runtime);
    // 切换与删除不需要名称，直接带方案 id。
    model.on_switch_to(move |id| send(ProfilesInput::Edit(ProfileEdit::Switch(id.into()))));
    let send = sender(runtime);
    model.on_confirm_delete(move |id| send(ProfilesInput::Edit(ProfileEdit::Delete(id.into()))));
    let send = sender(runtime);
    // 名称相关的回调不带参数：编辑状态在页上，处理时再读，读到的总是最新的输入。
    model.on_name_edited(move || send(ProfilesInput::NameEdited));
    let send = sender(runtime);
    model.on_confirm_edit(move || send(ProfilesInput::ConfirmName));
    let send = sender(runtime);
    model.on_reveal_config(move || send(ProfilesInput::Reveal));
}

impl App {
    /// 处理「配置方案」页的输入。
    pub(super) fn profiles_input(&mut self, input: ProfilesInput, runtime: &Rc<Runtime>) {
        match input {
            ProfilesInput::Edit(edit) => {
                self.profile_edited(&edit, runtime);
            }
            ProfilesInput::NameEdited => self.check_profile_name(),
            ProfilesInput::ConfirmName => self.confirm_profile_name(runtime),
            // 路径取配置存储实际用的那个，与页上显示的一致。
            ProfilesInput::Reveal => shell::reveal(self.store.path()),
        }
    }

    /// 把操作作用到协调器手里的配置；合法且有变化时交给协调器。返回操作是否合法。
    fn profile_edited(&mut self, edit: &ProfileEdit, runtime: &Rc<Runtime>) -> bool {
        let Some(config) = profiles::apply_profile_edit(self.coordinator.config(), edit) else {
            return false;
        };
        if &config != self.coordinator.config() {
            self.send(Event::ConfigEdited(config), runtime);
        }
        true
    }

    /// 校验输入框里的名称，把问题写到页上（确定按钮随之可用或置灰）。
    fn check_profile_name(&self) {
        let Some(window) = &self.settings else {
            return;
        };
        if let Some(edit) = profiles::name_edit(window) {
            // 与协调器手里的配置比较：方案列表可能刚被别处改过。
            let problem = profiles::name_problem(self.coordinator.config(), &edit);
            window
                .global::<eveo_ui::ProfilesModel>()
                .set_name_error(problem.into());
        }
    }

    /// 点了确定：按编辑的种类新建、改名或复制。成功后结束编辑；不合法时（按钮已置灰，一般不会发生）只更新提示。
    fn confirm_profile_name(&mut self, runtime: &Rc<Runtime>) {
        let Some(edit) = self.settings.as_ref().and_then(profiles::name_edit) else {
            return;
        };
        // 新建的方案取 Windows 的默认值（「全部隐藏」的热键与 macOS 不同），id 在这里生成。
        let Some(change) = edit.to_edit(|| new_profile(new_id(), "")) else {
            return;
        };
        if self.profile_edited(&change, runtime) {
            if let Some(window) = &self.settings {
                profiles::finish_edit(window);
            }
        } else {
            self.check_profile_name();
        }
    }
}
