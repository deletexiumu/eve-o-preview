// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警缓冲：按收听者分开、收听者的大小写、容量、到达顺序、prune、reparse 与 remove_all。收听者与说话人都是虚构的。

use crate::chat_log::ChatMessage;
use crate::intel::IntelReport;
use crate::intel::feed::{CAPACITY_PER_CHARACTER, IntelFeed};

/// 一条预警频道的消息。
fn message(text: &str, listener: &str, time: f64) -> ChatMessage {
    ChatMessage {
        listener: listener.into(),
        channel_id: "player_00".into(),
        channel_name: "intel.Demo".into(),
        time,
        speaker: "Mira Voss".into(),
        text: text.into(),
        is_backfill: false,
    }
}

/// 加一条只有普通文字的消息（收听者 Kael Doran）。
fn add(feed: &mut IntelFeed, text: &str, time: f64) -> u64 {
    feed.append(message(text, "Kael Doran", time), IntelReport::plain(text))
}

/// Kael Doran 的消息正文。
fn texts(feed: &IntelFeed) -> Vec<String> {
    feed.items("Kael Doran")
        .iter()
        .map(|item| item.message.text.clone())
        .collect()
}

/// 按收听者分开；编号从 1 起递增。
#[test]
fn separates_listeners() {
    let mut feed = IntelFeed::default();
    // 两个收听者各一条：编号在整个缓冲里递增，不按收听者分别计数，浮窗才能用编号判断哪些是新消息。
    let first = feed.append(message("a", "Kael Doran", 1_000.0), IntelReport::plain("a"));
    let second = feed.append(message("b", "Mira Voss", 1_000.0), IntelReport::plain("b"));
    assert_eq!((first, second), (1, 2));
    assert_eq!(texts(&feed), ["a"]);
    assert_eq!(feed.items("Mira Voss").len(), 1);
    assert!(feed.items("Tarn Vex").is_empty());
}

/// 收听者先原样比较，再不区分大小写比较：大小写不同的同一个角色放进同一份。
#[test]
fn case_insensitive_fallback() {
    let mut feed = IntelFeed::default();
    feed.append(message("a", "Kael Doran", 1_000.0), IntelReport::plain("a"));
    // 同一个角色在不同日志里大小写可能不同（文件头与频道里的名字），不该分成两份。
    feed.append(message("b", "KAEL DORAN", 1_000.0), IntelReport::plain("b"));
    assert_eq!(feed.items("kael doran").len(), 2);
    assert!(feed.remove_items("kael DORAN"));
    assert_eq!(feed.len(), 0);
    assert!(!feed.remove_items("Kael Doran"));
}

/// 超过容量时丢最早的。
#[test]
fn capacity() {
    let mut feed = IntelFeed::default();
    for index in 0..CAPACITY_PER_CHARACTER + 5 {
        add(&mut feed, &index.to_string(), index as f64);
    }
    // 多加的 5 条挤掉最早的 0～4，剩下的从 5 开始。
    let texts = texts(&feed);
    assert_eq!(texts.len(), CAPACITY_PER_CHARACTER);
    assert_eq!(texts[0], "5");
}

/// 按到达顺序排列：晚到的较早消息追加在末尾，已有条目的位置与编号不变；prune 仍按时间丢。
#[test]
fn keeps_arrival_order() {
    let mut feed = IntelFeed::default();
    let late = add(&mut feed, "late", 200.0);
    let early = add(&mut feed, "early", 100.0);
    add(&mut feed, "same", 200.0);
    assert_eq!(texts(&feed), ["late", "early", "same"]);
    let ids: Vec<u64> = feed.items("Kael Doran").iter().map(|i| i.id).collect();
    assert_eq!(ids[..2], [late, early]);
    feed.prune(150.0);
    assert_eq!(texts(&feed), ["late", "same"]);
}

/// prune 丢掉早于 cutoff 的消息，返回有没有丢；全丢光时收听者也去掉。
#[test]
fn prune() {
    let mut feed = IntelFeed::default();
    add(&mut feed, "old", 10.0);
    add(&mut feed, "new", 100.0);
    assert!(feed.prune(50.0));
    assert_eq!(texts(&feed), ["new"]);
    // 再按同一个时间丢一次：没有可丢的，返回 false，控制器据此跳过浮窗刷新。
    assert!(!feed.prune(50.0));
    assert!(feed.prune(1_000.0));
    assert!(feed.is_empty());
}

/// reparse 换掉解析结果，编号不变；remove_all 清空全部，编号不重新开始。
#[test]
fn reparse_and_remove_all() {
    let mut feed = IntelFeed::default();
    let id = add(&mut feed, "Jita", 1_000.0);
    // 模拟星图数据读完后重新解析：原来的普通文字现在认出了一个星系。
    feed.reparse(|_| IntelReport {
        system_ids: vec![1],
        ..IntelReport::default()
    });
    let items = feed.items("Kael Doran");
    assert_eq!(items[0].id, id);
    assert!(items[0].report.is_intel_like());
    feed.remove_all();
    assert_eq!(feed.len(), 0);
    // 清空后编号接着往下数：浮窗里旧编号对应的行不会被新消息误认。
    assert_eq!(add(&mut feed, "x", 1_000.0), id + 1);
}
