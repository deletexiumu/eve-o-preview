// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的动作入口，对应 macOS 的 AppCoordinator+Actions.swift（架构文档 7.2 节）：
// 缩略图的点击、最小化、悬停、拖动与右键菜单，托盘菜单的全局动作，以及给手势与菜单用的查询。

use eveo_core::geometry::{ScreenPoint, ScreenRect};
use eveo_core::layout::SnapTargets;
use eveo_core::layout::resolver::LOGIN_CASCADE_OFFSET;
use eveo_core::model::{EveClient, ThumbnailLayout, WindowId};

use super::Coordinator;
use crate::event::{
    ContextMenuAction, ContextMenuModel, DragContext, Effect, SettingsPage, TrayAction, TrayModel,
};

/// 尺寸与默认尺寸相差不到这么多点时视为默认尺寸，存成 `None`，以后改默认尺寸时这个缩略图跟着变。
const DEFAULT_SIZE_TOLERANCE: f64 = 0.5;

impl Coordinator {
    // MARK: 切换与最小化

    /// 左键点缩略图：切换到对应客户端。客户端已在本轮轮询中消失时忽略。
    pub(super) fn thumbnail_clicked(&mut self, id: WindowId) {
        if self.registry.client_with_id(id).is_some() {
            self.effects.push(Effect::Activate(id));
        }
    }

    /// 最小化一个客户端。客户端已消失时忽略。
    pub(super) fn minimize(&mut self, id: WindowId) {
        if self.registry.client_with_id(id).is_some() {
            self.effects.push(Effect::Minimize(id));
        }
    }

    /// 最小化全部客户端，按客户端登记的顺序。
    pub(super) fn minimize_all(&mut self) {
        // 每个客户端各发一个效果，执行者逐个调 ShowWindow；先收集 id，避免借用登记表的同时写效果列表。
        let ids: Vec<WindowId> = self.registry.clients().iter().map(|c| c.id).collect();
        self.effects.extend(ids.into_iter().map(Effect::Minimize));
    }

    /// 切换「全部隐藏」。
    pub(super) fn toggle_hide_all(&mut self) {
        // 只改会话状态，不持久化：重启后总是显示。规划器据它把全部呈现标成不可见。
        self.session.hide_all = !self.session.hide_all;
        self.needs_replan = true;
    }

    // MARK: 悬停与拖动

    /// 悬停变化。离开时只清掉自己的悬停，避免相邻缩略图的进入事件先到、被这里覆盖。
    pub(super) fn hover_changed(&mut self, id: WindowId, hovering: bool) {
        if hovering {
            self.session.hovered_window = Some(id);
        } else if self.session.hovered_window == Some(id) {
            self.session.hovered_window = None;
        }
        self.needs_replan = true;
    }

    /// 松开鼠标：清掉拖动状态，把最终 frame 写进当前配置方案，下一次重算即用新布局。
    ///
    /// 角色写 `layouts[角色名]`，尺寸与默认尺寸相同时宽高写 `None`；
    /// 登录与未知客户端写 `loginPosition`，扣掉层叠偏移。
    pub(super) fn drag_ended(&mut self, id: WindowId, frame: ScreenRect) {
        self.session.interacting_windows.remove(&id);
        self.needs_replan = true;
        let Some(client) = self.registry.client_with_id(id) else {
            return;
        };
        // 先复制角色名，后面的 update_profile 要可变借用 self。
        match client.character_name().map(str::to_owned) {
            Some(name) => {
                // 只比较尺寸不比较位置：位置总要保存，尺寸是默认值时存 None。
                let default = self.profile().thumbnail.default_size;
                let is_default = (frame.width - default.width).abs() < DEFAULT_SIZE_TOLERANCE
                    && (frame.height - default.height).abs() < DEFAULT_SIZE_TOLERANCE;
                let layout = ThumbnailLayout {
                    x: frame.x,
                    y: frame.y,
                    width: (!is_default).then_some(frame.width),
                    height: (!is_default).then_some(frame.height),
                };
                self.update_profile(|profile| {
                    profile.layouts.insert(name, layout);
                });
            }
            None => {
                // 登录客户端共用一个层叠起点，第 n 个（按 PID 排）向右下偏移 n 个 LOGIN_CASCADE_OFFSET。
                let offset = LOGIN_CASCADE_OFFSET * self.login_index(client) as f64;
                let position = ScreenPoint::new(frame.x - offset, frame.y - offset);
                self.update_profile(|profile| profile.login_position = position);
            }
        }
    }

    /// 登录与未知客户端按 PID 升序（再按窗口 ID）的序号，与规划器的层叠顺序一致。
    fn login_index(&self, client: &EveClient) -> usize {
        let mut login: Vec<&EveClient> = self
            .registry
            .clients()
            .iter()
            .filter(|c| c.character_name().is_none())
            .collect();
        // 与规划器的排序键相同；PID 相同（同一进程两个窗口）时再按窗口 ID，保证顺序稳定。
        login.sort_by_key(|c| (c.pid, c.id));
        login.iter().position(|c| c.id == client.id).unwrap_or(0)
    }

    /// 开始拖动前的上下文：基准 frame、显示的 frame、吸附与尺寸约束、吸附目标。
    /// 客户端已消失或还没有规划过时返回 `None`。
    ///
    /// 悬停放大时显示的是放大后的 frame：缩放边缘按它判断（用户按住的是放大后的边），
    /// 拖动本身从基准 frame 开始，否则松开后会把放大的尺寸存下来。
    pub fn drag_context(&self, id: WindowId) -> Option<DragContext> {
        let client = self.registry.client_with_id(id)?;
        let presentation = self.last_plan.presentations.iter().find(|p| p.id == id)?;
        let profile = self.profile();
        let settings = &profile.thumbnail;
        let displayed = presentation.frame;
        let start = if presentation.is_zoomed && settings.zoom_factor > 1 {
            displayed.scaled(
                1.0 / settings.zoom_factor as f64,
                settings.zoom_anchor.unit_position(),
            )
        } else {
            displayed
        };
        // 吸附目标取上一次规划里其他可见缩略图的 frame；悬停放大的邻居按放大后的 frame 吸附，与用户看到的一致。
        let neighbors = self
            .last_plan
            .presentations
            .iter()
            .filter(|p| p.is_visible && p.id != id)
            .map(|p| p.frame)
            .collect();
        Some(DragContext {
            start_frame: start,
            edge_frame: displayed,
            is_locked: profile.behavior.lock_layout,
            snap_enabled: settings.snap_enabled,
            lock_aspect_ratio: settings.lock_aspect_ratio,
            allows_resize: client.character_name().is_some(),
            minimum_size: settings.minimum_size,
            maximum_size: settings.maximum_size,
            targets: SnapTargets::from_screens(neighbors, &self.screens),
        })
    }

    // MARK: 右键菜单

    /// 构建右键菜单所需的状态。客户端已消失时返回 `None`。
    pub fn context_menu(&self, id: WindowId) -> Option<ContextMenuModel> {
        let client = self.registry.client_with_id(id)?;
        // 「恢复默认尺寸」只在保存过宽度时可用；只存了位置的布局已经是默认尺寸。
        let name = client.character_name().map(str::to_owned);
        Some(ContextMenuModel {
            is_skipped: name
                .as_ref()
                .is_some_and(|n| self.session.skipped_characters.contains(n)),
            has_custom_size: name
                .as_ref()
                .and_then(|n| self.profile().layouts.get(n))
                .is_some_and(|layout| layout.width.is_some()),
            character_name: name,
        })
    }

    /// 执行右键菜单里选中的动作。按角色的动作对登录客户端没有意义，菜单里已置灰；这里再判断一次。
    pub(super) fn context_menu_action(&mut self, id: WindowId, action: ContextMenuAction) {
        let Some(client) = self.registry.client_with_id(id) else {
            return;
        };
        let name = client.character_name().map(str::to_owned);
        match (action, name) {
            (ContextMenuAction::Minimize, _) => self.minimize(id),
            (ContextMenuAction::MinimizeAll, _) => self.minimize_all(),
            (ContextMenuAction::OpenSettings, _) => {
                self.effects.push(Effect::OpenSettings(SettingsPage::Previews))
            }
            (ContextMenuAction::ToggleSkip, Some(name)) => {
                // 跳过只影响循环与缩略图上的标记，按会话保存，不写配置。
                if !self.session.skipped_characters.remove(&name) {
                    self.session.skipped_characters.insert(name);
                }
                self.needs_replan = true;
            }
            // 隐藏写进当前配置方案，设置窗口的「隐藏的角色」里可以取消。
            (ContextMenuAction::Hide, Some(name)) => self.update_profile(|profile| {
                if !profile.hidden_characters.contains(&name) {
                    profile.hidden_characters.push(name);
                }
            }),
            // 只清宽高，位置不动。
            (ContextMenuAction::ResetSize, Some(name)) => self.update_profile(|profile| {
                if let Some(layout) = profile.layouts.get_mut(&name) {
                    layout.width = None;
                    layout.height = None;
                }
            }),
            (
                ContextMenuAction::ToggleSkip | ContextMenuAction::Hide | ContextMenuAction::ResetSize,
                None,
            ) => {}
        }
    }

    // MARK: 托盘

    /// 构建托盘菜单所需的状态。
    pub fn tray(&self) -> TrayModel {
        TrayModel {
            profiles: self
                .config
                .profiles
                .iter()
                .map(|p| (p.id.clone(), p.name.clone()))
                .collect(),
            active_profile_id: self.profile().id.clone(),
            hide_all: self.session.hide_all,
            client_count: self.registry.clients().len(),
        }
    }

    /// 执行托盘菜单里选中的动作。
    pub(super) fn tray_action(&mut self, action: TrayAction) {
        match action {
            TrayAction::ToggleHideAll => self.toggle_hide_all(),
            TrayAction::MinimizeAll => self.minimize_all(),
            TrayAction::SwitchProfile(id) => {
                // 切换后在 update_config 里清空跳过名单并重新规划热键。不存在的 id 忽略。
                if self.config.profile_with_id(&id).is_some() {
                    self.update_config(|config| config.active_profile_id = id);
                }
            }
            TrayAction::OpenSettings => self.effects.push(Effect::OpenSettings(SettingsPage::General)),
            TrayAction::Quit => {
                // 先停，再发 Quit：之后的事件全部忽略，handle 末尾也不再重算。
                self.stopped = true;
                self.effects.push(Effect::Quit);
            }
        }
    }
}
