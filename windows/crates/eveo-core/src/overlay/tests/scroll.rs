// SPDX-License-Identifier: GPL-3.0-or-later
//
// 滚动状态、追加计数、列表差异与空列表的说明。

use crate::overlay::scroll::{
    OverlayListDiff, OverlayListPlaceholder, OverlayScrollState, after_append, after_user_scroll, diff,
    placeholder,
};
use crate::overlay::{OverlayContent, OverlayLine, OverlaySpan, OverlaySpanStyle};

/// 一行：编号与正文；正文不同的两行内容不等。
fn line(id: u64, text: &str) -> OverlayLine {
    let shown = if text.is_empty() {
        format!("line {id}")
    } else {
        text.to_owned()
    };
    OverlayLine {
        id,
        primary: vec![OverlaySpan::new(shown, OverlaySpanStyle::Plain)],
        copy_text: text.to_owned(),
        ..OverlayLine::default()
    }
}

/// 一组编号对应的行。
fn lines(ids: &[u64]) -> Vec<OverlayLine> {
    ids.iter().map(|&id| line(id, "")).collect()
}

/// 不贴底部、已累计 count 条的状态。
fn away(count: usize) -> OverlayScrollState {
    OverlayScrollState {
        is_pinned_to_bottom: false,
        unseen_count: count,
    }
}

/// 距底部 0、8 时贴住底部且条数为 0；9 时不贴；弹性滚动越过底部（负数）也算贴住。
#[test]
fn user_scroll_distances() {
    let initial = OverlayScrollState::INITIAL;
    assert_eq!(after_user_scroll(initial, 0.0), initial);
    assert_eq!(after_user_scroll(initial, 8.0), initial);
    assert_eq!(after_user_scroll(initial, 9.0), away(0));
    assert!(after_user_scroll(initial, -12.0).is_pinned_to_bottom);
}

/// 不在底部时保留已累计的条数，回到底部时清零；距离不是有限值时按不在底部处理。
#[test]
fn user_scroll_keeps_count() {
    // 往上翻看时又滚了一下，仍不在底部：新消息条数保持。
    assert_eq!(after_user_scroll(away(5), 200.0), away(5));
    assert_eq!(after_user_scroll(away(5), 3.0), OverlayScrollState::INITIAL);
    assert_eq!(
        after_user_scroll(OverlayScrollState::INITIAL, 200.0).unseen_count,
        0
    );
    assert!(!after_user_scroll(OverlayScrollState::INITIAL, f64::NAN).is_pinned_to_bottom);
}

/// 贴住底部时追加不计数；不贴时累加。
#[test]
fn append_counting() {
    // 贴住底部时视图会自动滚到最新，不需要「新消息」提示。
    assert_eq!(
        after_append(OverlayScrollState::INITIAL, 3),
        OverlayScrollState::INITIAL
    );
    assert_eq!(after_append(away(2), 3).unseen_count, 5);
    assert_eq!(after_append(away(2), 0).unseen_count, 2);
    assert!(!after_append(away(2), 3).is_pinned_to_bottom);
}

/// 只追加：旧列表全部保留，尾部新增；从空列表开始也是只追加；完全相同时没有变化。
#[test]
fn diff_append_only() {
    let expected = OverlayListDiff {
        appended: 2,
        ..OverlayListDiff::default()
    };
    assert_eq!(diff(&lines(&[1, 2, 3]), &lines(&[1, 2, 3, 4, 5])), expected);
    assert_eq!(diff(&[], &lines(&[7, 8])).appended, 2);
    assert!(diff(&lines(&[1, 2]), &lines(&[1, 2])).is_empty());
}

/// 头部去掉加尾部追加；全部换成新行时去掉全部、加全部；清空时只去掉。
#[test]
fn diff_head_removed_and_appended() {
    let shifted = OverlayListDiff {
        removed_from_head: 2,
        appended: 1,
        ..OverlayListDiff::default()
    };
    // 最旧的两条过了保留时长被去掉，同时到了一条新的。
    assert_eq!(diff(&lines(&[1, 2, 3, 4]), &lines(&[3, 4, 5])), shifted);
    let replaced = OverlayListDiff {
        removed_from_head: 2,
        appended: 2,
        ..OverlayListDiff::default()
    };
    assert_eq!(diff(&lines(&[1, 2]), &lines(&[8, 9])), replaced);
    let cleared = OverlayListDiff {
        removed_from_head: 2,
        ..OverlayListDiff::default()
    };
    assert_eq!(diff(&lines(&[1, 2]), &[]), cleared);
}

/// 中间一行内容变了（译文晚到、人名核对的结果到达）：编号不变，列进 changed，下标是新列表里的。
#[test]
fn diff_changed_row() {
    let mut new = lines(&[2, 3, 4, 5]);
    new[1] = line(3, "translated");
    let expected = OverlayListDiff {
        removed_from_head: 1,
        appended: 1,
        changed: vec![1],
        is_reload: false,
    };
    assert_eq!(diff(&lines(&[1, 2, 3, 4]), &new), expected);
}

/// 对不上时整表重载：中间删了一行、顺序变了、头部插了一行、新增的编号与旧列表重复。
#[test]
fn diff_reload() {
    let old = lines(&[1, 2, 3]);
    assert!(diff(&old, &lines(&[1, 3])).is_reload);
    assert!(diff(&old, &lines(&[2, 1, 3])).is_reload);
    // 头部插入：补读到了更早的消息，按编号对不齐，整表重载最稳妥。
    assert!(diff(&old, &lines(&[0, 1, 2, 3])).is_reload);
    assert!(diff(&old, &lines(&[3, 1])).is_reload);
    assert_eq!(diff(&old, &lines(&[1, 2, 3, 2])), OverlayListDiff::reload());
}

/// 列表不空时没有说明；context_key 以 `:` 结尾或为空时是「没有角色」，否则是「还没有消息」。
#[test]
fn placeholders() {
    let content = |key: &str, ids: &[u64]| OverlayContent {
        context_key: key.into(),
        title: "T".into(),
        channel_label: None,
        status: None,
        lines: lines(ids),
    };
    assert_eq!(placeholder(&content("intel:", &[1])), None);
    assert_eq!(
        placeholder(&content("translation:", &[])),
        Some(OverlayListPlaceholder::NoActiveCharacter)
    );
    assert_eq!(
        placeholder(&content("", &[])),
        Some(OverlayListPlaceholder::NoActiveCharacter)
    );
    assert_eq!(
        placeholder(&content("intel:Pilot Alpha", &[])),
        Some(OverlayListPlaceholder::Empty)
    );
}
