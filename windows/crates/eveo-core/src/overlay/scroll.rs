// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗列表的滚动规则，对应 macOS 的 OverlayScrollRules.swift（设计文档 8.5 节）。纯函数，由界面层的浮窗列表调用。
// - 状态是 OverlayScrollState：是否贴住底部，以及离开底部后新到了几条。初始是贴住底部。
// - 用户滚动后：内容底部到可见区域底部的距离不超过 8 个单位时贴住底部并把条数清零，否则不贴。
// - 内容追加后：贴住底部时不计数（视图随后滚到底部）；不贴时累加条数，「N 条新消息」据此显示。
// - diff：两份行列表按行编号对齐。旧列表去掉头部若干行、尾部接上若干新行后，中间各行的编号与新列表逐一相同，
//   就是一般情况；编号相同但内容变了的行列进 changed。对不上时 is_reload 为真，视图整表重载。
// - placeholder：列表为空时显示哪一句。
// 这些规则让用户往上翻看旧消息时，新消息不会把视图拽回底部。

//! 浮窗列表的滚动状态、列表差异与空列表的说明。

use std::collections::HashSet;

use super::{OverlayContent, OverlayLine};

/// 离底部不超过这么多（逻辑像素）时算贴住底部：滚轮一格的余量，免得差一两个像素就不再自动滚动。
pub const BOTTOM_TOLERANCE: f64 = 8.0;

/// 列表的滚动状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OverlayScrollState {
    /// 是否贴住底部：贴住时内容更新后滚到底部。
    pub is_pinned_to_bottom: bool,
    /// 离开底部后新到的条数；贴住底部时为 0。
    pub unseen_count: usize,
}

impl OverlayScrollState {
    /// 初始状态：贴住底部，没有新消息。
    pub const INITIAL: Self = Self {
        is_pinned_to_bottom: true,
        unseen_count: 0,
    };
}

impl Default for OverlayScrollState {
    fn default() -> Self {
        Self::INITIAL
    }
}

/// 新旧两份行列表的差异。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct OverlayListDiff {
    /// 旧列表头部去掉的行数。
    pub removed_from_head: usize,
    /// 新列表尾部新增的行数。
    pub appended: usize,
    /// 新列表里编号没变、内容变了的行的下标，从小到大。
    pub changed: Vec<usize>,
    /// 对不上：视图应整表重载，其余字段都是 0 或空。
    pub is_reload: bool,
}

impl OverlayListDiff {
    /// 要整表重载的差异。
    pub fn reload() -> Self {
        Self {
            is_reload: true,
            ..Self::default()
        }
    }

    /// 没有任何变化：视图什么也不用做。
    pub fn is_empty(&self) -> bool {
        !self.is_reload && self.removed_from_head == 0 && self.appended == 0 && self.changed.is_empty()
    }
}

/// 列表为空时显示的说明（8.4 节）。
///
/// `OverlayContent` 没有「有没有活动角色」的字段。两个功能控制器的 context_key 都是「功能名 + `:` + 活动角色名」
/// （6.8 节），没有活动角色时以 `:` 结尾，这里按这个约定区分两种空列表。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayListPlaceholder {
    /// 当前窗口没有角色（如停在登录界面）。
    NoActiveCharacter,
    /// 有角色但还没有消息。
    Empty,
}

/// 用户滚动后的状态，保留离开底部期间已累计的条数：回到底部时清零，仍不在底部时条数不变。
/// 刚离开底部（之前是贴住的）时条数从 0 开始。距离不是有限值时按「不在底部」处理。
/// 弹性滚动越过底部时距离是负数，也算贴住。
pub fn after_user_scroll(state: OverlayScrollState, distance_from_bottom: f64) -> OverlayScrollState {
    if distance_from_bottom.is_finite() && distance_from_bottom <= BOTTOM_TOLERANCE {
        return OverlayScrollState::INITIAL;
    }
    OverlayScrollState {
        is_pinned_to_bottom: false,
        unseen_count: if state.is_pinned_to_bottom {
            0
        } else {
            state.unseen_count
        },
    }
}

/// 尾部追加了 appended 行之后的状态：贴住底部时不变，不贴时累加条数。
pub fn after_append(state: OverlayScrollState, appended: usize) -> OverlayScrollState {
    if state.is_pinned_to_bottom {
        return state;
    }
    OverlayScrollState {
        is_pinned_to_bottom: false,
        unseen_count: state.unseen_count + appended,
    }
}

/// 新旧两份行列表的差异：头部去掉几行、尾部加了几行、中间哪些行变了；对不上时 is_reload 为真。
///
/// 做法：旧列表里第一个编号也出现在新列表里的行是保留段的开头，它之前的行都算从头部去掉。
/// 保留段一直延续到旧列表末尾，各行的编号应与新列表开头的各行逐一相同；新列表剩下的行是尾部新增的，
/// 它们的编号不应出现在旧列表里。任何一条不满足时整表重载（中间删了一行、顺序变了、在头部插了行）。
pub fn diff(old: &[OverlayLine], new: &[OverlayLine]) -> OverlayListDiff {
    let new_ids: HashSet<u64> = new.iter().map(|l| l.id).collect();
    let start = old
        .iter()
        .position(|l| new_ids.contains(&l.id))
        .unwrap_or(old.len());
    let kept = old.len() - start;
    if kept > new.len() {
        return OverlayListDiff::reload();
    }
    let mut changed = Vec::new();
    for (offset, (before, after)) in old[start..].iter().zip(new).enumerate() {
        if before.id != after.id {
            return OverlayListDiff::reload();
        }
        if before != after {
            changed.push(offset);
        }
    }
    // 尾部新增的行若在旧列表里出现过（被头部去掉的那部分），说明顺序乱了。
    let old_ids: HashSet<u64> = old.iter().map(|l| l.id).collect();
    if new[kept..].iter().any(|l| old_ids.contains(&l.id)) {
        return OverlayListDiff::reload();
    }
    OverlayListDiff {
        removed_from_head: start,
        appended: new.len() - kept,
        changed,
        is_reload: false,
    }
}

/// 列表为空时显示哪一句；列表不空时为 None。context_key 为空或以 `:` 结尾表示没有活动角色。
pub fn placeholder(content: &OverlayContent) -> Option<OverlayListPlaceholder> {
    if !content.lines.is_empty() {
        return None;
    }
    let key = &content.context_key;
    Some(if key.is_empty() || key.ends_with(':') {
        OverlayListPlaceholder::NoActiveCharacter
    } else {
        OverlayListPlaceholder::Empty
    })
}
