// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的热键部分，对应 macOS 的 AppCoordinator+Hotkeys.swift（架构文档 5.5 节、6.5 节）。
// 热键规划每次都从 1 起重新编号，所以注册用的规划与回调查找用的规划必须是同一份：
// 只有 rebuild_hotkeys 改 hotkey_plan，并且改的同时发 RegisterHotkeys。
// 热键服务换代数重新注册，队列里上一代的 WM_HOTKEY 由它丢弃，送到这里的 id 都属于当前规划。

use eveo_core::hotkeys::HotkeyAction;
use eveo_core::hotkeys::planner;
use eveo_core::model::Pid;
use eveo_core::planning::FrontmostContext;
use eveo_core::switching::CycleDirection;
use eveo_core::switching::cycle;

use super::Coordinator;
use crate::event::Effect;

impl Coordinator {
    /// 按当前配置方案重新规划热键。与当前规划相同时不重新注册，避免每次配置变化都注销再注册；
    /// `force` 为真时（启动时）总是注册一次。
    pub(super) fn rebuild_hotkeys(&mut self, force: bool) {
        let plan = planner::plan(self.profile());
        if plan == self.hotkey_plan && !force {
            return;
        }
        // 先发注册效果再换规划：执行者按顺序处理，之后送来的 HotkeyFired 都按新规划查找。
        self.effects.push(Effect::RegisterHotkeys(plan.bindings.clone()));
        self.hotkey_plan = plan;
    }

    /// 前台是否是 EVE 客户端变了时告诉热键服务。前台是本应用（设置窗口）不算，`game` 热键不生效。
    pub(super) fn push_game_foreground(&mut self) {
        let game = matches!(self.frontmost, FrontmostContext::Client(_));
        if self.game_foreground != Some(game) {
            self.game_foreground = Some(game);
            self.effects.push(Effect::SetGameForeground(game));
        }
    }

    /// 热键触发：在当前规划里按 id 查绑定，再执行动作。查不到的 id 忽略。
    pub(super) fn hotkey_fired(&mut self, id: u32) {
        let Some(binding) = self.hotkey_plan.binding(id) else {
            return;
        };
        // 先复制动作再执行：执行时要可变借用 self，不能同时借着规划里的绑定。
        let action = binding.action.clone();
        self.perform(&action);
    }

    /// 执行热键动作。
    fn perform(&mut self, action: &HotkeyAction) {
        match action {
            HotkeyAction::Cycle { group_id, direction } => self.cycle(group_id, *direction),
            HotkeyAction::ActivateCharacter(name) => {
                if let Some(client) = self.registry.client_named(name) {
                    self.effects.push(Effect::Activate(client.id));
                }
            }
            // 登录客户端循环只有前进方向（上游没有后退热键）。
            HotkeyAction::CycleLoginClients => self.cycle_login_clients(CycleDirection::Forward),
            HotkeyAction::ToggleHideAll => self.toggle_hide_all(),
            HotkeyAction::MinimizeAll => self.minimize_all(),
        }
    }

    /// 活动客户端的 PID：前台是客户端时取它，否则取最近一次处于前台的客户端。
    pub(super) fn active_pid(&self) -> Option<Pid> {
        match self.frontmost {
            FrontmostContext::Client(pid) => Some(pid),
            FrontmostContext::SelfApp | FrontmostContext::Other => self.session.last_active_pid,
        }
    }

    /// 在循环组里前进或后退一步。起点是活动客户端的角色名；活动的是登录客户端或没有活动客户端时，
    /// 从该方向的第一个成员开始。只在在线的角色之间循环，离线成员与被跳过的成员自动跳过。
    fn cycle(&mut self, group_id: &str, direction: CycleDirection) {
        let Some(group) = self.profile().cycle_groups.iter().find(|g| g.id == group_id) else {
            return;
        };
        let active = self
            .active_pid()
            .and_then(|pid| self.registry.client_with_pid(pid))
            .and_then(|client| client.character_name());
        // 在线的角色：当前登记里有角色名的客户端。登录客户端没有角色名，不参与循环组。
        let running = self
            .registry
            .clients()
            .iter()
            .filter_map(|c| c.character_name().map(str::to_owned))
            .collect();
        // 找到的成员名再换回窗口：同名角色只会有一个客户端（标题按角色名区分）。
        let target = cycle::next(
            &group.members,
            direction,
            active,
            &running,
            &self.session.skipped_characters,
        )
        .and_then(|name| self.registry.client_named(name))
        .map(|client| client.id);
        if let Some(id) = target {
            self.effects.push(Effect::Activate(id));
        }
    }

    /// 在登录与未知客户端之间循环，按 PID 升序，与缩略图的层叠顺序一致。
    fn cycle_login_clients(&mut self, direction: CycleDirection) {
        // 登录与未知客户端都参与；排序交给 next_login_client。
        let pids: Vec<Pid> = self
            .registry
            .clients()
            .iter()
            .filter(|c| c.character_name().is_none())
            .map(|c| c.pid)
            .collect();
        let target = cycle::next_login_client(&pids, self.active_pid(), direction)
            .and_then(|pid| self.registry.client_with_pid(pid))
            .map(|client| client.id);
        if let Some(id) = target {
            self.effects.push(Effect::Activate(id));
        }
    }
}
