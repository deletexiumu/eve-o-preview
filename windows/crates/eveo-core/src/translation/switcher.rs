// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗快速切换频道的纯逻辑，对应 macOS 的 TranslationChannelSwitcher.swift：
// - 内置频道（本地、军团、联盟、舰队）始终排在第一组，按 ID 匹配。
// - 最近 24 小时从日志里发现的频道去掉内置种类与私聊后，活动角色出现过的排在前面，其余按最后活跃时间倒序，
//   最多保留 MAX_RECENT_CHANNELS（15）项，避免菜单过长。
// - 当前已选里如果还有不在内置与最近列表里的自定义频道（手动输入或超过 24 小时未发言），单独放进 custom_selected，
//   菜单里仍能看到当前正在翻译什么，也能随时切回。
// - 按钮文字：未选时显示占位词，单选时显示频道名，多选时显示「首个频道名 +其余个数」。

//! 翻译浮窗频道切换的纯计算规则。

use crate::chat_log::{ChatChannelKind, DiscoveredChannel};
use crate::model::ChannelRef;

/// 菜单里最多展示多少个近期日志频道。
pub const MAX_RECENT_CHANNELS: usize = 15;

/// 翻译浮窗频道切换的菜单分组。
#[derive(Debug, Clone, PartialEq)]
pub struct TranslationChannelSections {
    /// 4 个内置频道（本地、军团、联盟、舰队）。
    pub built_ins: Vec<ChannelRef>,
    /// 最近 24 小时活跃的非内置日志频道（已优先排当前角色，并按活跃时间倒序截断）。
    pub recent: Vec<DiscoveredChannel>,
    /// 当前已选但不在内置和最近列表里的频道，避免自定义或静默频道在菜单里「失踪」。
    pub custom_selected: Vec<ChannelRef>,
}

/// 两个频道引用是否指同一个频道（与设置页与配置校验的去重规则一致）：
/// 两边都有非空 ID 时按 ID 不区分大小写比较，否则按去掉首尾空白的名字不区分大小写比较。
pub fn is_same_channel(a: &ChannelRef, b: &ChannelRef) -> bool {
    let id_a = a.id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let id_b = b.id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    match (id_a, id_b) {
        (Some(x), Some(y)) => x.eq_ignore_ascii_case(y),
        _ => a.name.trim().to_lowercase() == b.name.trim().to_lowercase(),
    }
}

/// 候选频道是否在当前已选列表里（用于菜单里显示勾选标记）。
pub fn is_selected(candidate: &ChannelRef, selected: &[ChannelRef]) -> bool {
    selected
        .iter()
        .any(|existing| is_same_channel(existing, candidate))
}

/// 候选频道是否已经是唯一的当前翻译频道：是的话点击它无需重建跟踪器。
/// 若当前只存了名字（无 ID）而候选项带规范 ID，返回 false，点击后可顺带升级成带 ID 的引用。
pub fn is_only_selected(candidate: &ChannelRef, selected: &[ChannelRef]) -> bool {
    if selected.len() != 1 || !is_same_channel(&selected[0], candidate) {
        return false;
    }
    let existing_has_id = selected[0].id.as_deref().is_some_and(|s| !s.trim().is_empty());
    let candidate_has_id = candidate.id.as_deref().is_some_and(|s| !s.trim().is_empty());
    // 只有当候选项不带新 ID，或现有引用本身已经有 ID 时，才算完全一致无需替换。
    !candidate_has_id || existing_has_id
}

/// 整理近期日志频道：去掉内置种类与私聊，活动角色出现过的排前面，同组内按最后修改时间倒序（相同时按 ID），
/// 最多取 limit 个。
pub fn ordered_recent_channels(
    discovered: &[DiscoveredChannel],
    active_character: Option<&str>,
    limit: usize,
) -> Vec<DiscoveredChannel> {
    let active = active_character
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_lowercase);
    let mut filtered: Vec<DiscoveredChannel> = discovered
        .iter()
        .filter(|c| matches!(c.kind, ChatChannelKind::Player | ChatChannelKind::Other))
        .cloned()
        .collect();
    filtered.sort_by(|lhs, rhs| {
        if let Some(active) = active.as_deref() {
            let lhs_active = lhs.listener_names.iter().any(|n| n == active);
            let rhs_active = rhs.listener_names.iter().any(|n| n == active);
            if lhs_active != rhs_active {
                return rhs_active.cmp(&lhs_active);
            }
        }
        rhs.last_modified
            .total_cmp(&lhs.last_modified)
            .then_with(|| lhs.id.cmp(&rhs.id))
    });
    filtered.truncate(limit);
    filtered
}

/// 生成频道切换菜单的三组频道。
pub fn sections(
    selected: &[ChannelRef],
    discovered: &[DiscoveredChannel],
    active_character: Option<&str>,
    limit: usize,
) -> TranslationChannelSections {
    let built_ins = ChannelRef::built_ins().to_vec();
    let recent = ordered_recent_channels(discovered, active_character, limit);
    let recent_refs: Vec<ChannelRef> = recent.iter().map(DiscoveredChannel::channel_ref).collect();
    let custom_selected = selected
        .iter()
        .filter(|channel| !is_selected(channel, &built_ins) && !is_selected(channel, &recent_refs))
        .cloned()
        .collect();
    TranslationChannelSections {
        built_ins,
        recent,
        custom_selected,
    }
}

/// 浮窗标题栏右侧按钮的文字：没选时用 empty_label；1 个时显示名字；多个时显示「首个名字 +其余个数」。
pub fn button_label<F>(selected: &[ChannelRef], empty_label: &str, display_name: F) -> String
where
    F: Fn(&ChannelRef) -> String,
{
    let Some(first) = selected.first() else {
        return empty_label.to_owned();
    };
    let name = display_name(first);
    if selected.len() > 1 {
        format!("{name} +{}", selected.len() - 1)
    } else {
        name
    }
}
