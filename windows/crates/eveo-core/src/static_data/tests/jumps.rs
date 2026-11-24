// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跳数：链与支线上的跳数、上限截断、4 种结果。

use std::collections::HashMap;

use super::*;
use crate::static_data::jumps::{JumpDistance, distance, distances};

/// 链上与支线上的跳数；出发星系是 0。
#[test]
fn chain_and_branch() {
    let data = data();
    let table = distances(JITA, 15, &data);
    assert_eq!(table[&JITA], 0);
    assert_eq!(table[&PERIMETER], 1);
    assert_eq!(table[&AMARR], 5);
    assert_eq!(table[&ONE_DQ], 3);
    assert_eq!(table[&HED_GP], 5);
    assert_eq!(table.len(), 9);
}

/// max_jumps 截断；0 时只有出发星系。
#[test]
fn limit() {
    let data = data();
    let table = distances(JITA, 2, &data);
    let mut keys: Vec<_> = table.keys().copied().collect();
    keys.sort_unstable();
    assert_eq!(keys, [JITA, PERIMETER, NEW_CALDARI]);
    assert_eq!(distance(AMARR, Some(&table), 2, &data), JumpDistance::Beyond(2));
    assert_eq!(distances(JITA, 0, &data), HashMap::from([(JITA, 0)]));
}

/// distance 的 4 种结果。
#[test]
fn distance_kinds() {
    let data = data();
    let table = distances(JITA, 15, &data);
    let table = Some(&table);
    assert_eq!(distance(HEK, table, 15, &data), JumpDistance::Jumps(4));
    assert_eq!(distance(JITA, table, 15, &data), JumpDistance::Jumps(0));
    // 不相连的星系：有星门，但不在同一块里。
    assert_eq!(distance(NAGA_SYSTEM, table, 15, &data), JumpDistance::Beyond(15));
    // 没有星门的星系与虫洞星系。
    assert_eq!(distance(ONSOOH, table, 15, &data), JumpDistance::Unreachable);
    assert_eq!(distance(THERA, table, 15, &data), JumpDistance::Unreachable);
    assert_eq!(distance(HEK, None, 15, &data), JumpDistance::UnknownOrigin);
}
