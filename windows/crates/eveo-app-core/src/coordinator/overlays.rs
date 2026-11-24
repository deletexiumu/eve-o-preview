// SPDX-License-Identifier: GPL-3.0-or-later
//
// 协调器的预警与翻译浮窗部分，对应 macOS 的 AppCoordinator+ChatOverlays.swift（设计文档 9.3 节）：
// - replan_overlays：在每次重算里、缩略图的规划之后调用。规划浮窗，结果有变化时发 ApplyOverlays，
//   返回浮窗规划的唤醒时刻（「离开 EVE 时隐藏」到期），与缩略图的唤醒时刻取较早的一个。
// - overlay_drag_context：按下鼠标时的拖动上下文：吸附到可见的缩略图、另一个浮窗与各屏幕。
// - overlay_drag_ended / overlay_menu_action：把结果写进当前配置方案。
//
// 与 macOS 的差别：
// - 拖动中的浮窗由应用层的浮窗管理器自己保持位置（不改正在拖动的浮窗的 frame），协调器不记交互状态，
//   所以没有 OverlayDragBegan、OverlayDragCancelled 两个事件。
// - 翻译功能还没有移植，规划结果里去掉翻译浮窗，免得用户打开翻译后看到一个永远空白的浮窗。
// - 浮窗的内容不经过协调器：聊天日志的总控在应用层，内容变了直接交给浮窗，不触发重算。

use eveo_core::geometry::{ScreenRect, ScreenSize, size_scale_at};
use eveo_core::layout::SnapTargets;
use eveo_core::overlay::OverlayKind;
use eveo_core::overlay::planner::{
    self, MAXIMUM_SIZE, MINIMUM_SIZE, OverlayPlannerInput, OverlayPresentation,
};

use super::Coordinator;
use crate::event::{DragContext, Effect, OverlayMenuAction, SettingsPage};

/// 上一次发给浮窗管理器的内容（呈现与活动角色），没变时不再发。
pub(super) type AppliedOverlays = (Vec<OverlayPresentation>, Option<String>);

impl Coordinator {
    /// 规划浮窗；结果与上一次发出的不同时发 ApplyOverlays。返回浮窗规划的唤醒时刻。
    pub(super) fn replan_overlays(&mut self) -> Option<f64> {
        let mut plan = planner::plan(&OverlayPlannerInput {
            clients: self.registry.clients(),
            frontmost: self.frontmost,
            profile: self.profile(),
            session: &self.session,
            screens: &self.screens,
            now: self.now,
        });
        // 翻译功能移植之前不显示翻译浮窗（见文件头）。
        plan.presentations.retain(|p| p.kind != OverlayKind::Translation);
        let applied = (plan.presentations.clone(), plan.active_character.clone());
        if self.last_overlays.as_ref() != Some(&applied) {
            let (presentations, active_character) = applied.clone();
            self.effects.push(Effect::ApplyOverlays {
                presentations,
                active_character,
            });
            self.last_overlays = Some(applied);
        }
        let wake = plan.next_wake_at;
        self.overlay_plan = plan.presentations;
        wake
    }

    /// 最近一次规划的浮窗呈现（只含已启用的浮窗）。
    pub fn overlay_presentations(&self) -> &[OverlayPresentation] {
        &self.overlay_plan
    }

    /// 浮窗的拖动上下文：起点是规划给的 frame（应用层按下时换成浮窗当前的 frame）；
    /// 吸附目标是可见的缩略图、另一个可见的浮窗与各屏幕。浮窗没在规划结果里时为 None。
    ///
    /// 尺寸上下限按 100% 缩放写，乘以浮窗所在屏幕的缩放比例，与规划器的约定一致；浮窗的宽高比不锁定，
    /// 总能缩放（缩略图的「登录界面不能缩放」对浮窗没有意义）。
    pub fn overlay_drag_context(&self, kind: OverlayKind) -> Option<DragContext> {
        let presentation = self.overlay_plan.iter().find(|p| p.kind == kind)?;
        let start = presentation.frame;
        let factor = size_scale_at(&self.screens, start.center());
        let scaled = |s: ScreenSize| ScreenSize::new(s.width * factor, s.height * factor);
        let thumbnails = self
            .last_plan
            .presentations
            .iter()
            .filter(|p| p.is_visible)
            .map(|p| p.frame);
        let overlays = self
            .overlay_plan
            .iter()
            .filter(|p| p.is_visible && p.kind != kind)
            .map(|p| p.frame);
        let neighbors: Vec<ScreenRect> = thumbnails.chain(overlays).collect();
        let profile = self.profile();
        Some(DragContext {
            start_frame: start,
            edge_frame: start,
            is_locked: profile.behavior.lock_layout,
            snap_enabled: profile.thumbnail.snap_enabled,
            lock_aspect_ratio: false,
            allows_resize: true,
            minimum_size: scaled(MINIMUM_SIZE),
            maximum_size: scaled(MAXIMUM_SIZE),
            targets: SnapTargets::from_screens(neighbors, &self.screens),
        })
    }

    /// 浮窗拖动结束：把最终 frame 写进当前配置方案。规划时再收进屏幕，这里原样保存。
    pub(super) fn overlay_drag_ended(&mut self, kind: OverlayKind, frame: ScreenRect) {
        self.update_profile(|profile| match kind {
            OverlayKind::Intel => profile.intel.overlay.frame = Some(frame),
            OverlayKind::Translation => profile.translation.overlay.frame = Some(frame),
        });
        // 配置没变（松开在原位）时 update_config 不会要求重算；这里也重算一次，浮窗回到规划的 frame。
        self.needs_replan = true;
    }

    /// 浮窗右键菜单里改配置的动作（8.7 节的表）。
    pub(super) fn overlay_menu_action(&mut self, kind: OverlayKind, action: OverlayMenuAction) {
        match action {
            OverlayMenuAction::ToggleLock => {
                self.update_profile(|profile| profile.behavior.lock_layout = !profile.behavior.lock_layout);
            }
            OverlayMenuAction::ResetFrame => self.update_profile(|profile| match kind {
                OverlayKind::Intel => profile.intel.overlay.frame = None,
                OverlayKind::Translation => profile.translation.overlay.frame = None,
            }),
            // 隐藏就是关掉功能：浮窗不再规划，聊天日志的跟踪随之停止；在设置窗口里再打开。
            OverlayMenuAction::Hide => self.update_profile(|profile| match kind {
                OverlayKind::Intel => profile.intel.enabled = false,
                OverlayKind::Translation => profile.translation.enabled = false,
            }),
            OverlayMenuAction::OpenSettings => self.effects.push(Effect::OpenSettings(match kind {
                OverlayKind::Intel => SettingsPage::Intel,
                OverlayKind::Translation => SettingsPage::Translation,
            })),
        }
    }
}
