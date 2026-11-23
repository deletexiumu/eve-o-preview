// SPDX-License-Identifier: GPL-3.0-or-later
//
// 循环顺序，对应 macOS 的 Switching/CycleEngine.swift（架构文档 5.4 节），
// 语义与上游 EVE-O Preview 的 FindNextClientInCycleGroup 相同。用例在 shared/fixtures/cycle。

//! 循环组与登录客户端的循环计算。

use std::collections::HashSet;

use crate::model::Pid;

/// 循环方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CycleDirection {
    /// 按成员顺序向后。
    Forward,
    /// 按成员顺序向前。
    Backward,
}

/// 在 `members` 里从 `active` 的位置按方向找下一个可用成员，返回它的角色名。
///
/// - 可用指同时满足「在 `running` 里」和「不在 `skipped` 里」；找完一圈（绕回一次）为止。
/// - `active` 不在 `members` 里（或为 `None`）时，从该方向的第一个成员开始找（前进从头，后退从尾）。
/// - `active` 自己被跳过时，仍以它的位置为起点。
/// - 没有可用成员时返回 `None`；唯一可用的成员就是 `active` 时返回它自己。
/// - 重复成员由配置校验在读入与修改配置时去掉，这里不处理重复。
///   直接传入重复项时，`active` 以第一次出现的位置为起点，结果不保证能走遍全部成员。
pub fn next<'a>(
    members: &'a [String],
    direction: CycleDirection,
    active: Option<&str>,
    running: &HashSet<String>,
    skipped: &HashSet<String>,
) -> Option<&'a str> {
    if members.is_empty() {
        return None;
    }
    // 下标用有符号数计算，绕回时用欧几里得取余得到非负结果。
    let count = members.len() as i64;
    let step: i64 = match direction {
        CycleDirection::Forward => 1,
        CycleDirection::Backward => -1,
    };
    let start = match active.and_then(|a| members.iter().position(|m| m == a)) {
        Some(index) => index as i64,
        // 起点设在第一个成员「之前」，这样第一步正好落在该方向的第一个成员上。
        None => match direction {
            CycleDirection::Forward => -1,
            CycleDirection::Backward => count,
        },
    };
    (1..=count)
        .map(|offset| &members[(start + step * offset).rem_euclid(count) as usize])
        .find(|candidate| running.contains(*candidate) && !skipped.contains(*candidate))
        .map(String::as_str)
}

/// 在登录客户端之间循环。
///
/// `pids` 先按升序排列，从 `active_pid` 的位置按方向取下一个并绕回；`active_pid` 不在其中时取该方向的第一个
/// （前进取最小，后退取最大）；空切片返回 `None`；只有一个时返回它自己。
pub fn next_login_client(pids: &[Pid], active_pid: Option<Pid>, direction: CycleDirection) -> Option<Pid> {
    let mut sorted = pids.to_vec();
    sorted.sort_unstable();
    let index = match active_pid.and_then(|pid| sorted.iter().position(|&p| p == pid)) {
        Some(index) => index,
        None => {
            return match direction {
                CycleDirection::Forward => sorted.first().copied(),
                CycleDirection::Backward => sorted.last().copied(),
            };
        }
    };
    let count = sorted.len();
    let next = match direction {
        CycleDirection::Forward => (index + 1) % count,
        CycleDirection::Backward => (index + count - 1) % count,
    };
    Some(sorted[next])
}
