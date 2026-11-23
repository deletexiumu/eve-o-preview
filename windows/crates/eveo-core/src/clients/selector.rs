// SPDX-License-Identifier: GPL-3.0-or-later
//
// 从一个 EVE 进程的多个顶层窗口里选出主窗口，对应 macOS 的 Clients/ClientWindowSelector.swift
// （架构文档 5.3 节、事实 E6）。macOS 上实测每个进程有 1 个带标题的主窗口，另有无标题的细长条与方形辅助窗口；
// Windows 上辅助窗口的形态由 M3 的探针确认（W1），规则先保持一致。
// macOS 按窗口层级预筛候选（isCandidateLayer）；Windows 的预筛（可见、未隐身、非工具窗口）属于平台层，不在这里。

//! 主窗口挑选规则。

use std::collections::BTreeMap;

use crate::clients::title;
use crate::geometry::ScreenSize;
use crate::model::{ClientIdentity, Pid, WindowInfo};

/// 无标题时可作为主窗口的最小尺寸。宽和高分别比较，不比较面积：
/// 500×500 的辅助窗口面积大于 640×360，但宽度不足 640，应排除。
pub const MINIMUM_UNTITLED_SIZE: ScreenSize = ScreenSize::new(640.0, 360.0);

/// 每个 PID 选出一个主窗口。输入是平台层预筛过的全部候选窗口。
///
/// 同一 PID 下：
/// 1. 先取标题能解析成角色或登录的窗口。
/// 2. 没有时，取宽不小于 640、高不小于 360 的窗口。
/// 3. 都没有时，该 PID 本轮不产生客户端。
///
/// 多个候选时取面积最大的，面积相同再取窗口 ID 最小的。
/// 返回每个 PID 至多一个窗口，按 PID 升序排列。
pub fn main_windows(candidates: &[WindowInfo]) -> Vec<WindowInfo> {
    // BTreeMap 按键升序遍历，正好得到按 PID 排序的结果。
    let mut by_pid: BTreeMap<Pid, Vec<&WindowInfo>> = BTreeMap::new();
    for window in candidates {
        by_pid.entry(window.pid).or_default().push(window);
    }
    by_pid
        .values()
        .filter_map(|windows| main_window(windows))
        .cloned()
        .collect()
}

/// 在同一进程的窗口里按上述规则选一个。
fn main_window<'a>(windows: &[&'a WindowInfo]) -> Option<&'a WindowInfo> {
    let titled = windows.iter().copied().filter(|w| {
        matches!(
            title::identity(w.title.as_deref()),
            ClientIdentity::Character(_) | ClientIdentity::Login
        )
    });
    if let Some(best) = largest(titled) {
        return Some(best);
    }
    let big_enough = windows.iter().copied().filter(|w| {
        w.frame.width >= MINIMUM_UNTITLED_SIZE.width && w.frame.height >= MINIMUM_UNTITLED_SIZE.height
    });
    largest(big_enough)
}

/// 面积最大者；面积相同取窗口 ID 最小者；没有候选时返回 `None`。
fn largest<'a>(windows: impl Iterator<Item = &'a WindowInfo>) -> Option<&'a WindowInfo> {
    windows.min_by(|a, b| {
        // min_by 取「排在最前」的元素：面积大的排前，面积相同时 ID 小的排前。
        b.frame
            .area()
            .total_cmp(&a.frame.area())
            .then(a.window_id.cmp(&b.window_id))
    })
}
