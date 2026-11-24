// SPDX-License-Identifier: GPL-3.0-or-later
//
// 排队与节流：防抖与间隔、批量与在途、去重与上限、错误额度、三类失败的等待、清空。

use crate::intel::pilots::queue::{MAX_PENDING, PilotLookupQueue};
use crate::intel::pilots::{PilotLookupAnswer, PilotLookupFailure, PilotLookupStatus};

/// 排进一组名字的新队列。
fn queue(names: &[&str], now: f64) -> PilotLookupQueue {
    let mut value = PilotLookupQueue::default();
    value.enqueue(names, now);
    value
}

/// 带错误额度的答复。
fn answer(remain: Option<i64>, reset: Option<i64>) -> PilotLookupAnswer {
    PilotLookupAnswer {
        error_limit_remain: remain,
        error_limit_reset: reset,
        ..PilotLookupAnswer::default()
    }
}

/// 不足 0.5 秒时不取；两批之间隔 2 秒；next_attempt 给出对应的时刻。
#[test]
fn debounce_and_interval() {
    let mut value = queue(&["Kael Doran"], 0.0);
    assert_eq!(value.next_attempt(), Some(0.5));
    assert_eq!(value.take_batch(0.4), None);
    assert_eq!(value.take_batch(0.5), Some(vec!["Kael Doran".to_owned()]));
    assert_eq!(value.status(), PilotLookupStatus::Resolving);
    value.complete(&answer(None, None), 0.8);
    assert_eq!(value.status(), PilotLookupStatus::Idle);
    value.enqueue(&["Mira Voss"], 1.0);
    // 防抖要到 1.5，间隔要到 2.5，取较晚的。
    assert_eq!(value.next_attempt(), Some(2.5));
    assert_eq!(value.take_batch(2.0), None);
    assert_eq!(value.take_batch(2.5), Some(vec!["Mira Voss".to_owned()]));
}

/// 一批至多 500 个；有一批在途时不取，next_attempt 是 None。
#[test]
fn batch_size_and_in_flight() {
    let names: Vec<String> = (0..600).map(|i| format!("Name{i}")).collect();
    let mut value = PilotLookupQueue::default();
    value.enqueue(&names, 0.0);
    assert_eq!(value.take_batch(1.0).map(|b| b.len()), Some(500));
    assert_eq!(value.take_batch(10.0), None);
    assert_eq!(value.next_attempt(), None);
    value.complete(&answer(None, None), 10.0);
    assert_eq!(value.take_batch(10.0).map(|b| b.len()), Some(100));
    value.complete(&answer(None, None), 11.0);
    assert_eq!(value.next_attempt(), None);
}

/// 已在待查或在途的名字不重复排（按比较键）；超过 2,000 个时丢最早的。
#[test]
fn deduplication_and_cap() {
    // 第二个只是大小写与空白不同，比较键相同，不再排。
    let mut value = queue(&["Kael Doran", "kael  doran"], 0.0);
    assert_eq!(value.pending_count(), 1);
    value.take_batch(1.0);
    // 在途的同名也不排：答复回来就有结果了，重复发只是浪费请求。
    value.enqueue(&["KAEL DORAN"], 1.0);
    assert_eq!(value.pending_count(), 0);
    let names: Vec<String> = (0..2_005).map(|i| format!("N{i}")).collect();
    let mut big = PilotLookupQueue::default();
    big.enqueue(&names, 0.0);
    assert_eq!(big.pending_count(), MAX_PENDING);
    // 最早的 N0～N4 被挤掉。
    assert_eq!(big.take_batch(1.0).unwrap()[0], "N5");
}

/// complete 在错误额度小于 20 时进入等待，秒数夹到 1～120，没有重置头时 60；20 及以上回到 Idle。
#[test]
fn low_error_budget() {
    let mut value = queue(&["A1", "B2"], 0.0);
    value.take_batch(1.0);
    // 额度 19 低于 20：等重置的 500 秒，但夹到 120 秒。
    value.complete(&answer(Some(19), Some(500)), 10.0);
    assert_eq!(value.status(), PilotLookupStatus::Waiting(130.0));
    value.enqueue(&["C3"], 10.0);
    assert_eq!(value.take_batch(129.0), None);
    assert_eq!(value.next_attempt(), Some(130.0));
    value.take_batch(130.0);
    // 没有重置头时按 60 秒。
    value.complete(&answer(Some(5), None), 131.0);
    assert_eq!(value.status(), PilotLookupStatus::Waiting(191.0));
    value.take_batch(191.0);
    value.complete(&answer(Some(20), None), 192.0);
    assert_eq!(value.status(), PilotLookupStatus::Idle);
}

/// RateLimited：回到待查，等 retry_after 秒。
#[test]
fn rate_limited_requeues() {
    let mut value = queue(&["Kael Doran"], 0.0);
    value.take_batch(1.0);
    value.fail(&PilotLookupFailure::RateLimited { retry_after: 45.0 }, 2.0);
    assert_eq!(value.status(), PilotLookupStatus::Waiting(47.0));
    assert_eq!(value.pending_count(), 1);
    // 等待期间不发；到点后同一个名字重新发出。
    assert_eq!(value.take_batch(46.0), None);
    assert_eq!(value.take_batch(47.0), Some(vec!["Kael Doran".to_owned()]));
}

/// Network、Server、MalformedAnswer：回到待查，等 30 秒，连续失败时加倍，上限 600 秒；成功后清零。
#[test]
fn transient_failures_back_off() {
    let mut value = queue(&["Kael Doran"], 0.0);
    let mut now = 1.0;
    let mut waits = Vec::new();
    let failures = [
        PilotLookupFailure::Network("x".into()),
        PilotLookupFailure::Server { status: 503 },
        PilotLookupFailure::MalformedAnswer,
        PilotLookupFailure::Network("x".into()),
        PilotLookupFailure::Network("x".into()),
        PilotLookupFailure::Network("x".into()),
    ];
    for failure in &failures {
        assert!(value.take_batch(now).is_some());
        value.fail(failure, now);
        let PilotLookupStatus::Waiting(until) = value.status() else {
            panic!("应当在等待");
        };
        waits.push(until - now);
        now = until;
    }
    assert_eq!(waits, [30.0, 60.0, 120.0, 240.0, 480.0, 600.0]);
    value.take_batch(now);
    value.complete(&answer(None, None), now);
    value.enqueue(&["Mira Voss"], now);
    value.take_batch(now + 2.0);
    value.fail(&PilotLookupFailure::Network("x".into()), now + 2.0);
    // 成功一次后连续失败清零，又从 30 秒起。
    assert_eq!(value.status(), PilotLookupStatus::Waiting(now + 32.0));
}

/// Rejected：这一批丢掉、不回到待查，等 300 秒。
#[test]
fn rejected_drops_batch() {
    let mut value = queue(&["Kael Doran"], 0.0);
    value.take_batch(1.0);
    value.fail(&PilotLookupFailure::Rejected { status: 400 }, 2.0);
    assert_eq!(value.pending_count(), 0);
    assert_eq!(value.status(), PilotLookupStatus::Waiting(302.0));
    assert_eq!(value.next_attempt(), None);
    // 新名字可以排，但要等 300 秒的惩罚过去才发。
    value.enqueue(&["Mira Voss"], 3.0);
    assert_eq!(value.next_attempt(), Some(302.0));
}

/// Rejected 的名字 1 小时内不再排（补排不会把同一批反复发出）；过了 1 小时又能排；别的名字不受影响。
#[test]
fn rejected_names_are_held_back() {
    let mut value = queue(&["Kael Doran", "Tarn Vex"], 0.0);
    value.take_batch(1.0);
    value.fail(&PilotLookupFailure::Rejected { status: 400 }, 2.0);
    // 只有没被拒过的 Mira Voss 排进来。
    value.enqueue(&["kael doran", "Tarn Vex", "Mira Voss"], 10.0);
    assert_eq!(value.pending_count(), 1);
    // remove_all 不清「暂不查」表。
    value.remove_all();
    value.enqueue(&["Kael Doran"], 2.0 + 3_599.0);
    assert_eq!(value.pending_count(), 0);
    value.enqueue(&["Kael Doran"], 2.0 + 3_600.0);
    assert_eq!(value.pending_count(), 1);
}

/// remove_all 清空待查与在途，保留等待的时刻。
#[test]
fn remove_all_keeps_wait() {
    let mut value = queue(&["Kael Doran"], 0.0);
    value.take_batch(1.0);
    value.fail(&PilotLookupFailure::RateLimited { retry_after: 100.0 }, 1.0);
    value.remove_all();
    assert_eq!(value.pending_count(), 0);
    assert_eq!(value.status(), PilotLookupStatus::Waiting(101.0));
    // 关了再开也不能绕过 ESI 要求的等待。
    value.enqueue(&["Mira Voss"], 2.0);
    assert_eq!(value.take_batch(50.0), None);
}

/// 失败的一批回到最前面并保持原来的顺序，排在失败期间新排进来的名字之前。
#[test]
fn requeue_keeps_order() {
    let mut value = queue(&["Aa Bb", "Cc Dd"], 0.0);
    value.take_batch(1.0);
    value.enqueue(&["Ee Ff", "aa bb"], 1.5);
    value.fail(&PilotLookupFailure::Server { status: 500 }, 2.0);
    assert_eq!(value.pending_count(), 3);
    let batch = value.take_batch(100.0).unwrap();
    assert_eq!(batch, ["Aa Bb", "Cc Dd", "Ee Ff"]);
}
