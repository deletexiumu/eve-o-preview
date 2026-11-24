// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跳数，对应 macOS 的 JumpGraph.swift（设计文档 6.6 节）：只按星门连接算，不考虑跳桥、虫洞与安全等级的路线偏好。
// distances 从出发星系做一次广度优先，得到 max_jumps 跳以内每个星系的跳数；预警按「出发星系与 max_jumps」
// 缓存这张表，出发星系变了才重算。表至多遍历已知空间的 5,485 个星系。

//! 星门图上的跳数。

use std::collections::HashMap;

use super::EveStaticData;

/// 到一个星系的跳数。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JumpDistance {
    /// 跳数；0 表示就在出发星系。
    Jumps(i64),
    /// 超过上限，或与出发星系不在同一片星门网里；关联值是上限。
    Beyond(i64),
    /// 目标星系没有任何星门（虫洞星系等）。
    Unreachable,
    /// 不知道从哪里算。
    UnknownOrigin,
}

/// 广度优先，返回 max_jumps 跳以内每个星系的跳数，含出发星系（0）。max_jumps 小于 0 时按 0 算。
pub fn distances(origin: i64, max_jumps: i64, data: &EveStaticData) -> HashMap<i64, i64> {
    let mut table = HashMap::from([(origin, 0)]);
    let mut frontier = vec![origin];
    let mut depth = 0;
    while depth < max_jumps && !frontier.is_empty() {
        depth += 1;
        let mut next = Vec::new();
        for system in frontier {
            for &neighbor in data.neighbors(system) {
                if let std::collections::hash_map::Entry::Vacant(slot) = table.entry(neighbor) {
                    slot.insert(depth);
                    next.push(neighbor);
                }
            }
        }
        frontier = next;
    }
    table
}

/// 到目标星系的跳数：table 为 `None` 时是 UnknownOrigin；表里有目标时是 Jumps；目标没有任何星门时是
/// Unreachable；其余是 Beyond(max_jumps)。
pub fn distance(
    target: i64,
    table: Option<&HashMap<i64, i64>>,
    max_jumps: i64,
    data: &EveStaticData,
) -> JumpDistance {
    let Some(table) = table else {
        return JumpDistance::UnknownOrigin;
    };
    if let Some(&jumps) = table.get(&target) {
        return JumpDistance::Jumps(jumps);
    }
    if data.neighbors(target).is_empty() {
        return JumpDistance::Unreachable;
    }
    JumpDistance::Beyond(max_jumps)
}
