// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图规划器，对应 macOS 的 Planning/ThumbnailPlanner.swift：由全部运行时状态算出每个缩略图的呈现、
// 要保持注册的 DWM 缩略图、要持久化的自动布局，以及下一次定时重算的时刻。
// 布局与外观的规则与 macOS 相同；捕获规格、裁剪与权限相关的占位换成 DWM 缩略图的状态（见 mod.rs）。

//! 缩略图规划器。

use std::collections::{BTreeMap, HashMap};

use super::{
    FrontmostContext, PlannerInput, ThumbnailAlert, ThumbnailPlaceholder, ThumbnailPlan,
    ThumbnailPresentation, ThumbnailStatus, visibility,
};
use crate::geometry::ScreenRect;
use crate::layout::{self, resolver};
use crate::model::{EveClient, Pid, ThumbnailLayout, WindowId};

/// 由状态算出全部缩略图的呈现。纯函数，同样的输入总是得到同样的输出（自动排位只依赖输入顺序）。
///
/// - 布局：先给有记录的角色与登录客户端定位，再按客户端顺序给没有记录的角色自动排位，
///   使自动排位避开全部已知缩略图；每个自动排位的 frame 立即加入已占用的范围。
/// - `layouts_to_persist` 只含自动排位的角色（宽高为 `None`，表示用默认尺寸）；
///   被拉回屏幕的有记录布局不写回，避免拔掉显示器后覆盖保存的位置。
pub fn plan(input: &PlannerInput<'_>) -> ThumbnailPlan {
    let layout = resolve_layouts(input);
    let mut result = ThumbnailPlan {
        layouts_to_persist: layout.to_persist,
        next_wake_at: next_wake_at(input),
        ..ThumbnailPlan::default()
    };
    for client in input.clients {
        let base = layout
            .frames
            .get(&client.id)
            .copied()
            .unwrap_or_else(|| resolver::frame(client, 0, input.profile, input.screens, &[]).frame);
        let presentation = present(client, base, input);
        if presentation.is_visible {
            result.thumbnails.push(client.id);
        }
        result.presentations.push(presentation);
    }
    result
}

/// 下一次定时重算的时刻：隐藏期限与最早的提醒到期时刻中较小的一个。
/// 提醒到期时重算一次，把呈现里的提醒清掉，并让第 4 条可见性规则恢复生效。
fn next_wake_at(input: &PlannerInput<'_>) -> Option<f64> {
    [
        visibility::hide_deadline(input),
        input.session.earliest_combat_alert_expiry(input.now),
    ]
    .into_iter()
    .flatten()
    .reduce(f64::min)
}

/// 两遍定位的结果：每个窗口的基准 frame 与要持久化的自动布局。
#[derive(Default)]
struct LayoutPass {
    frames: HashMap<WindowId, ScreenRect>,
    to_persist: BTreeMap<String, ThumbnailLayout>,
}

/// 两遍定位：第一遍是有记录的角色与登录客户端，第二遍是需要自动排位的角色。
fn resolve_layouts(input: &PlannerInput<'_>) -> LayoutPass {
    let mut pass = LayoutPass::default();
    let mut occupied: Vec<ScreenRect> = Vec::new();
    let login_index = login_indices(input.clients);
    let mut pending: Vec<&EveClient> = Vec::new();
    for client in input.clients {
        if let Some(name) = client.character_name()
            && !input.profile.layouts.contains_key(name)
        {
            pending.push(client);
            continue;
        }
        let index = login_index.get(&client.id).copied().unwrap_or(0);
        let resolved = resolver::frame(client, index, input.profile, input.screens, &occupied);
        pass.frames.insert(client.id, resolved.frame);
        occupied.push(resolved.frame);
    }
    for client in pending {
        let resolved = resolver::frame(client, 0, input.profile, input.screens, &occupied);
        pass.frames.insert(client.id, resolved.frame);
        occupied.push(resolved.frame);
        // 同名的多个客户端只持久化第一个的位置。
        if resolved.is_auto_placed
            && let Some(name) = client.character_name()
        {
            pass.to_persist.entry(name.to_owned()).or_insert(ThumbnailLayout {
                x: resolved.frame.x,
                y: resolved.frame.y,
                width: None,
                height: None,
            });
        }
    }
    pass
}

/// 登录与未知客户端按 (PID, 窗口) 升序的序号。
fn login_indices(clients: &[EveClient]) -> HashMap<WindowId, usize> {
    let mut login: Vec<&EveClient> = clients.iter().filter(|c| c.character_name().is_none()).collect();
    login.sort_by_key(|c| (c.pid, c.id));
    login.iter().enumerate().map(|(i, c)| (c.id, i)).collect()
}

/// 生成一个客户端的呈现。
fn present(client: &EveClient, base: ScreenRect, input: &PlannerInput<'_>) -> ThumbnailPresentation {
    let profile = input.profile;
    let session = input.session;
    let overlay = &profile.overlay;
    let is_hovered = session.hovered_window == Some(client.id);
    let is_interacting = session.interacting_windows.contains(&client.id);
    // 拖动中不放大：放大会改变 frame，与拖动直接设置的窗口位置冲突。
    let zoom = is_hovered && profile.thumbnail.zoom_enabled && !is_interacting;
    let frame = if zoom {
        layout::zoomed_frame(base, profile.thumbnail.zoom_factor, profile.thumbnail.zoom_anchor)
    } else {
        base
    };
    let is_active = active_pid(input) == Some(client.pid);
    // 高亮只画在活动客户端上；按角色的颜色优先，登录与未知客户端没有角色名，用全局颜色。
    let highlight_color = (overlay.highlight_enabled && is_active).then(|| {
        client
            .character_name()
            .and_then(|name| profile.highlight_colors.get(name))
            .unwrap_or(&overlay.highlight_color)
            .clone()
    });
    // 提醒不看 combat_alert.enabled：是否读日志由协调器把关，「测试闪烁」在关闭时也要能显示。
    let has_alert = session.has_active_combat_alert(client.id, input.now);
    ThumbnailPresentation {
        id: client.id,
        pid: client.pid,
        frame,
        is_visible: visibility::is_visible(client, input),
        title: client.display_title(),
        shows_title: overlay.show_title,
        title_font_size: overlay.title_font_size,
        title_color: overlay.title_color.clone(),
        // 悬停或有提醒时不透明，提醒中的缩略图在默认透明度下也能看清。
        opacity: if is_hovered || has_alert {
            1.0
        } else {
            profile.thumbnail.opacity
        },
        highlight_color,
        highlight_thickness: overlay.highlight_thickness as f64,
        border_color: overlay.border_enabled.then(|| overlay.border_color.clone()),
        border_thickness: overlay.border_thickness as f64,
        alert: has_alert.then(|| ThumbnailAlert {
            color: profile.combat_alert.color.clone(),
            style: profile.combat_alert.style,
        }),
        is_active,
        is_skipped: client
            .character_name()
            .is_some_and(|name| session.skipped_characters.contains(name)),
        is_always_on_top: profile.behavior.always_on_top,
        is_over_full_screen: profile.behavior.always_on_top && is_frontmost_full_screen(input),
        is_zoomed: zoom,
        placeholder: placeholder(client, input),
    }
}

/// 活动客户端的 PID：前台是客户端时取它，否则取最后一次处于前台的客户端。
fn active_pid(input: &PlannerInput<'_>) -> Option<Pid> {
    match input.frontmost {
        FrontmostContext::Client(pid) => Some(pid),
        _ => input.session.last_active_pid,
    }
}

/// 前台是否是全屏的客户端。只在这时让缩略图盖过全屏窗口；客户端全屏、用户却在桌面时不必。
fn is_frontmost_full_screen(input: &PlannerInput<'_>) -> bool {
    let FrontmostContext::Client(pid) = input.frontmost else {
        return false;
    };
    input
        .clients
        .iter()
        .any(|c| c.pid == pid && c.is_full_screen == Some(true))
}

/// 按顺序取第一个成立的占位：注册失败排最前，其次是最小化。
fn placeholder(client: &EveClient, input: &PlannerInput<'_>) -> ThumbnailPlaceholder {
    let status = input
        .thumbnail_states
        .get(&client.id)
        .copied()
        .unwrap_or_default();
    if status == ThumbnailStatus::Failed {
        ThumbnailPlaceholder::Unavailable
    } else if client.is_minimized == Some(true) {
        ThumbnailPlaceholder::Minimized
    } else {
        ThumbnailPlaceholder::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ClientIdentity, Profile};
    use crate::planning::SessionState;

    /// 只有 Windows 有的占位：注册失败优先于最小化。
    #[test]
    fn failed_thumbnail_shows_unavailable() {
        let client = |id: u64, minimized: bool| EveClient {
            id: WindowId(id),
            pid: u32::try_from(id).unwrap(),
            identity: ClientIdentity::Login,
            window_frame: ScreenRect::new(0.0, 0.0, 1280.0, 720.0),
            is_on_screen: true,
            is_minimized: Some(minimized),
            is_full_screen: None,
        };
        let clients = [client(1, true), client(2, true), client(3, false)];
        let states = HashMap::from([(WindowId(1), ThumbnailStatus::Failed)]);
        let profile = Profile::default();
        let session = SessionState::default();
        let input = PlannerInput {
            clients: &clients,
            frontmost: FrontmostContext::Other,
            profile: &profile,
            session: &session,
            screens: &[],
            thumbnail_states: &states,
            now: 0.0,
        };
        let placeholders: Vec<_> = plan(&input).presentations.iter().map(|p| p.placeholder).collect();
        assert_eq!(
            placeholders,
            [
                ThumbnailPlaceholder::Unavailable,
                ThumbnailPlaceholder::Minimized,
                ThumbnailPlaceholder::None
            ]
        );
    }
}
