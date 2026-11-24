// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的队列：进入队列不足 1 秒时不取；同一时刻只有一批在途；complete 把相同原文的消息一并完成；
// 几类失败各自的状态与消息阶段；Waiting 到时后可再取；连续失败时等待时长加倍且有上限；reset；
// activate 只排最近 600 秒内的最新 20 条；next_attempt 的各种结果；只取活动角色的消息；旧请求的结果；
// 清空缓冲不解除暂停；截断后拆小。收听者名是虚构的。

use std::collections::BTreeMap;

use super::message_at;
use crate::model::AppLanguage;
use crate::translation::queue::{CAPACITY_PER_CHARACTER, TranslationQueue};
use crate::translation::rules::MAX_BATCH_MESSAGES;
use crate::translation::{Failure, Phase, SkipReason, TranslatedText, TranslationItem, TranslationStatus};

/// 起始时刻（墙上时钟）。
const T0: f64 = 1_000_000.0;
/// 活动角色。
const ALPHA: &str = "Pilot Alpha";

/// 放入几条 Pending 的消息（时间都是 now）并激活 ALPHA，返回队列与编号。
fn queue_with(texts: &[&str], now: f64) -> (TranslationQueue, Vec<u64>) {
    let mut queue = TranslationQueue::new();
    queue.activate(Some(ALPHA), now);
    let ids = texts
        .iter()
        .map(|text| queue.append(message_at(text, ALPHA, now), Phase::Pending, now))
        .collect();
    (queue, ids)
}

/// ALPHA 的一条消息，时间是 T0。
fn alpha(text: &str) -> crate::chat_log::ChatMessage {
    message_at(text, ALPHA, T0)
}

/// 取一批；没有时测试失败。
fn take(queue: &mut TranslationQueue, now: f64) -> Vec<TranslationItem> {
    queue.take_batch(now).expect("这时应能取到一批")
}

/// ALPHA 的各条阶段。
fn phases(queue: &TranslationQueue) -> Vec<Phase> {
    queue.items(ALPHA).into_iter().map(|item| item.phase).collect()
}

/// 一条结果。
fn result(text: &str, source: Option<&str>) -> TranslatedText {
    TranslatedText {
        text: text.to_owned(),
        source_language: source.map(str::to_owned),
    }
}

/// 已翻译的阶段。
fn done(text: &str, source: Option<&str>) -> Phase {
    Phase::Done {
        text: text.to_owned(),
        source_language: source.map(str::to_owned),
    }
}

/// 当前状态是 Waiting 时的等待结束时刻。
fn waiting_until(queue: &TranslationQueue) -> f64 {
    match queue.status() {
        TranslationStatus::Waiting { until, .. } => *until,
        other => panic!("应在等待，实际是 {other:?}"),
    }
}

/// 进入队列不足 1 秒时不取，满 1 秒后取。
#[test]
fn debounce() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    // 半秒内又可能有新消息进来，先攒一攒再发，省请求次数。
    assert!(queue.take_batch(T0 + 0.5).is_none());
    let batch = take(&mut queue, T0 + 1.0);
    assert_eq!(batch.len(), 1);
    assert_eq!(batch[0].phase, Phase::InFlight);
    assert_eq!(queue.status(), &TranslationStatus::Translating);
    // 缓冲里的那一条也标成在途，浮窗显示「翻译中…」。
    assert_eq!(phases(&queue), vec![Phase::InFlight]);
}

/// 同一时刻只有一批在途。
#[test]
fn single_batch_in_flight() {
    let (mut queue, _) = queue_with(&["one"], T0);
    assert!(queue.take_batch(T0 + 2.0).is_some());
    // 在途期间进来的新消息排着，等这一批回来再发。
    queue.append(alpha("two"), Phase::Pending, T0 + 2.0);
    assert!(queue.take_batch(T0 + 10.0).is_none());
    assert!(queue.has_batch_in_flight());
}

/// complete：有结果的 Done，没有结果的 Failed，缓存键相同的 Pending 消息一并 Done，状态回到 Idle。
#[test]
fn complete_fills_duplicates() {
    let (mut queue, ids) = queue_with(&["hello there", "hello  there*", "other"], T0);
    let batch = take(&mut queue, T0 + 1.0);
    let batch_ids: Vec<u64> = batch.iter().map(|i| i.id).collect();
    // 第二条与第一条缓存键相同，不重复发送。
    assert_eq!(batch_ids, vec![ids[0], ids[2]]);
    queue.complete(
        // 模型只答了第一条，「other」没有结果。
        &BTreeMap::from([(ids[0], result("你好", Some("en")))]),
        &batch,
        None,
    );
    assert_eq!(
        phases(&queue),
        vec![done("你好", Some("en")), done("你好", Some("en")), Phase::Failed]
    );
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    assert!(!queue.has_batch_in_flight());
}

/// 致命的失败：这一批回到 Pending，状态 Blocked，之后不再取；发请求之前的失败也一样。
#[test]
fn fatal_failure_blocks() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    let batch = take(&mut queue, T0 + 1.0);
    // Key 无效：等用户改设置，消息保留在队列里，改好后不用重新收。
    queue.fail(Failure::Unauthorized(401), &batch, T0 + 2.0);
    assert_eq!(
        queue.status(),
        &TranslationStatus::Blocked(Failure::Unauthorized(401))
    );
    assert_eq!(phases(&queue), vec![Phase::Pending]);
    assert!(queue.take_batch(T0 + 100.0).is_none());
    assert_eq!(queue.next_attempt(), None);

    // 没有 Key 时在发请求之前就失败，batch 为空。
    let (mut early, _) = queue_with(&["hello"], T0);
    early.fail(Failure::MissingKey, &[], T0);
    assert_eq!(early.status(), &TranslationStatus::Blocked(Failure::MissingKey));
    assert_eq!(phases(&early), vec![Phase::Pending]);
}

/// 临时故障：回到 Pending，Waiting 到时刻；到时后可再取。
#[test]
fn temporary_failure_waits_then_retries() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    let first = take(&mut queue, T0 + 1.0);
    // 服务说 12 秒后再来。
    queue.fail(Failure::RateLimited(Some(12.0)), &first, T0 + 2.0);
    assert_eq!(
        queue.status(),
        &TranslationStatus::Waiting {
            until: T0 + 14.0,
            reason: Failure::RateLimited(Some(12.0))
        }
    );
    assert_eq!(phases(&queue), vec![Phase::Pending]);
    // 还没到时间。
    assert!(queue.take_batch(T0 + 13.0).is_none());
    assert_eq!(queue.next_attempt(), Some(T0 + 14.0));
    assert!(queue.take_batch(T0 + 14.0).is_some());
    assert_eq!(queue.status(), &TranslationStatus::Translating);
}

/// 只影响这一批的失败：这一批 Failed，状态回到 Idle，后面的消息照常处理。
#[test]
fn batch_only_failure() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    let batch = take(&mut queue, T0 + 1.0);
    // 答复格式不对只算这一批失败，重试多半还是一样，不再自动重试。
    queue.fail(Failure::MalformedAnswer, &batch, T0 + 2.0);
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    assert_eq!(phases(&queue), vec![Phase::Failed]);
    queue.append(alpha("next"), Phase::Pending, T0 + 3.0);
    assert_eq!(queue.take_batch(T0 + 4.0).map(|b| b.len()), Some(1));
}

/// 服务出错与网络失败：30、60、120、240、300、300 秒；成功后计数清零。带秒数的 429 不参与加倍。
#[test]
fn backoff_doubles_with_cap() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    let mut now = T0 + 1.0;
    let mut waits = Vec::new();
    for index in 0..6 {
        let batch = take(&mut queue, now);
        // 服务出错与网络失败交替出现，共用一个连续失败计数。
        let failure = if index % 2 == 0 {
            Failure::Server(503)
        } else {
            Failure::Network("timeout".to_owned())
        };
        queue.fail(failure, &batch, now);
        let until = waiting_until(&queue);
        waits.push(until - now);
        now = until;
    }
    assert_eq!(waits, vec![30.0, 60.0, 120.0, 240.0, 300.0, 300.0]);
    // 带秒数的限流按服务给的时间等，不影响加倍的计数。
    let limited = take(&mut queue, now);
    queue.fail(Failure::RateLimited(Some(7.0)), &limited, now);
    assert_eq!(waiting_until(&queue), now + 7.0);
    now += 7.0;
    // 成功一批后计数清零，下一次失败又从 30 秒起。
    let ok = take(&mut queue, now);
    queue.complete(&BTreeMap::from([(ok[0].id, result("x", None))]), &ok, None);
    queue.append(alpha("again"), Phase::Pending, now);
    let next = take(&mut queue, now + 1.0);
    queue.fail(Failure::Server(500), &next, now + 1.0);
    assert_eq!(waiting_until(&queue), now + 31.0);
}

/// 429 没有给秒数：30、60、120……秒，上限 600 秒；成功后计数清零。
#[test]
fn rate_limit_without_retry_after_backs_off() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    let mut now = T0 + 1.0;
    let mut waits = Vec::new();
    for _ in 0..7 {
        let batch = take(&mut queue, now);
        queue.fail(Failure::RateLimited(None), &batch, now);
        let until = waiting_until(&queue);
        waits.push(until - now);
        now = until;
    }
    assert_eq!(waits, vec![30.0, 60.0, 120.0, 240.0, 480.0, 600.0, 600.0]);
    let ok = take(&mut queue, now);
    queue.complete(&BTreeMap::from([(ok[0].id, result("x", None))]), &ok, None);
    queue.append(alpha("again"), Phase::Pending, now);
    let next = take(&mut queue, now + 1.0);
    queue.fail(Failure::RateLimited(None), &next, now + 1.0);
    assert_eq!(waiting_until(&queue), now + 31.0);
}

/// reset：状态回到 Idle，在途与最近 600 秒内 Failed 的消息回到 Pending，更早的 Failed 不动。
#[test]
fn reset_requeues() {
    let mut queue = TranslationQueue::new();
    queue.activate(Some(ALPHA), T0);
    // 十多分钟前的失败消息已经过时，重试时不再花钱翻译。
    queue.append(message_at("old", ALPHA, T0 - 700.0), Phase::Failed, T0);
    queue.append(message_at("recent", ALPHA, T0 - 10.0), Phase::Failed, T0);
    queue.append(message_at("sending", ALPHA, T0), Phase::Pending, T0);
    let batch = take(&mut queue, T0 + 1.0);
    queue.fail(Failure::Unauthorized(401), &batch, T0 + 1.0);
    queue.reset(T0 + 5.0);
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    assert_eq!(
        phases(&queue),
        vec![Phase::Failed, Phase::Pending, Phase::Pending]
    );
    // 「sending」在 T0 + 1 回到 Pending，是最早的一条。
    assert_eq!(queue.next_attempt(), Some(T0 + 2.0));
}

/// activate 只把最近 600 秒内的最新 20 条里 Off 的改成 Pending；重复调用不排更多。
#[test]
fn activate_queues_recent_only() {
    let mut queue = TranslationQueue::new();
    // 5 条太旧，25 条在 600 秒内，其中最后 1 条已翻译。
    // 太旧的消息只在缓冲里显示原文，不补译。
    for index in 0..5 {
        queue.append(
            message_at(&format!("stale {index}"), ALPHA, T0 - 900.0),
            Phase::Off,
            T0,
        );
    }
    for index in 0..25 {
        let phase = if index == 24 { done("x", None) } else { Phase::Off };
        let time = T0 - 100.0 + f64::from(index);
        queue.append(message_at(&format!("recent {index}"), ALPHA, time), phase, T0);
    }
    queue.activate(Some(ALPHA), T0);
    let count_pending =
        |queue: &TranslationQueue| phases(queue).iter().filter(|p| **p == Phase::Pending).count();
    assert_eq!(count_pending(&queue), 19);
    // 5 条太旧的加上 600 秒内最早的 5 条（不在最新 20 条里）都还是 Off。
    assert!(phases(&queue)[..10].iter().all(|p| *p == Phase::Off));
    // 再激活一次：最新 20 条里已经没有 Off 的，不会多排。
    queue.activate(Some(ALPHA), T0 + 1.0);
    assert_eq!(count_pending(&queue), 19);
    assert_eq!(queue.active_listener(), Some(ALPHA));
}

/// 只取活动角色的消息：别的收听者的 Pending 留在缓冲里，切换后才发。收听者不区分大小写匹配。
#[test]
fn only_active_listener_is_sent() {
    let mut queue = TranslationQueue::new();
    queue.activate(Some(ALPHA), T0);
    // Beta 不是活动角色：没人看它的浮窗，先不发。
    queue.append(message_at("for beta", "Pilot Beta", T0), Phase::Pending, T0);
    assert!(queue.take_batch(T0 + 5.0).is_none());
    assert_eq!(queue.next_attempt(), None);
    // 切到 Beta（大小写不同的写法也认）后才发。
    queue.activate(Some("pilot beta"), T0 + 5.0);
    let texts: Vec<String> = take(&mut queue, T0 + 5.0)
        .into_iter()
        .map(|item| item.message.text)
        .collect();
    assert_eq!(texts, vec!["for beta"]);
    assert_eq!(queue.items("PILOT BETA").len(), 1);
}

/// next_attempt：没有待办为 None；有 Pending 时是最早进入时刻加 1 秒；有一批在途时为 None。
#[test]
fn next_attempt_cases() {
    let mut queue = TranslationQueue::new();
    assert_eq!(queue.next_attempt(), None);
    queue.activate(Some(ALPHA), T0);
    // Off 的消息不排队，不影响下一次的时刻。
    queue.append(alpha("a"), Phase::Off, T0);
    assert_eq!(queue.next_attempt(), None);
    queue.append(alpha("b"), Phase::Pending, T0 + 2.0);
    assert_eq!(queue.next_attempt(), Some(T0 + 3.0));
    take(&mut queue, T0 + 3.0);
    assert_eq!(queue.next_attempt(), None);
}

/// 答复被截断：多条的一批放回 Pending，下一批取一半；只剩 1 条再被截断时改成 Failed。成功后上限加倍。
#[test]
fn truncated_batch_is_split() {
    let texts: Vec<String> = (0..8).map(|n| format!("line {n}")).collect();
    let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
    let (mut queue, ids) = queue_with(&refs, T0);
    // 8 条一起发，答复被截断。
    let full = take(&mut queue, T0 + 1.0);
    assert_eq!(full.len(), 8);
    queue.fail(Failure::Truncated, &full, T0 + 2.0);
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    assert!(!queue.has_batch_in_flight());
    assert!(phases(&queue).iter().all(|p| *p == Phase::Pending));
    assert_eq!(queue.batch_limit(), 4);
    // 拆成一半重发，按原来的顺序取前 4 条。
    let half = take(&mut queue, T0 + 3.0);
    let half_ids: Vec<u64> = half.iter().map(|i| i.id).collect();
    assert_eq!(half_ids, ids[..4].to_vec());
    queue.fail(Failure::Truncated, &half, T0 + 4.0);
    assert_eq!(queue.batch_limit(), 2);
    // 2 条成功后上限加倍回到 4。
    let quarter = take(&mut queue, T0 + 5.0);
    let results = quarter.iter().map(|i| (i.id, result("ok", None))).collect();
    queue.complete(&results, &quarter, None);
    assert_eq!(queue.batch_limit(), 4);
    // 只有 1 条的一批被截断：这一条 Failed。
    let (mut single, _) = queue_with(&["very long line"], T0);
    let one = take(&mut single, T0 + 1.0);
    single.fail(Failure::Truncated, &one, T0 + 2.0);
    assert_eq!(phases(&single), vec![Phase::Failed]);
    // reset 把上限恢复成 20。
    queue.reset(T0 + 6.0);
    assert_eq!(queue.batch_limit(), MAX_BATCH_MESSAGES);
}

/// 等待中而没有 Pending 的消息（清空了列表、或没有活动角色）：next_attempt 是等待结束的时刻，
/// 到时 take_batch 把状态改回 Idle，不停在 Waiting。
#[test]
fn waiting_expires_without_pending() {
    let (mut queue, _) = queue_with(&["hello"], T0);
    let batch = take(&mut queue, T0 + 1.0);
    queue.fail(Failure::Server(503), &batch, T0 + 2.0);
    // 用户在等待期间清空了列表。
    queue.remove_items(None);
    assert_eq!(queue.next_attempt(), Some(T0 + 32.0));
    assert!(queue.take_batch(T0 + 32.0).is_none());
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    assert_eq!(queue.next_attempt(), None);
    // 没有活动角色时同样到时恢复。
    // 另一种情形：等待期间活动角色退出了（没有前台客户端）。
    let (mut other, _) = queue_with(&["hi"], T0);
    let first = take(&mut other, T0 + 1.0);
    other.fail(Failure::Network("offline".to_owned()), &first, T0 + 2.0);
    other.activate(None, T0 + 2.0);
    assert_eq!(other.next_attempt(), Some(T0 + 32.0));
    other.take_batch(T0 + 32.0);
    assert_eq!(other.status(), &TranslationStatus::Idle);
}

/// complete 带目标语言时，模型原样抄回的结果是 SameLanguage，其余是 Done；同缓存键的副本一并处理。
#[test]
fn complete_with_target_marks_echo() {
    let (mut queue, ids) = queue_with(&["Jita gate camp", "Jita  gate camp*", "hostiles"], T0);
    let batch = take(&mut queue, T0 + 1.0);
    let results = BTreeMap::from([
        (ids[0], result("Jita gate camp", Some("en"))),
        (ids[2], result("敌对", Some("en"))),
    ]);
    queue.complete(&results, &batch, Some(AppLanguage::Zh));
    // 模型原样抄回：两条副本都不当译文显示。
    let same = Phase::Skipped(SkipReason::SameLanguage, None);
    assert_eq!(phases(&queue), vec![same.clone(), same, done("敌对", Some("en"))]);
}

/// 旧请求的结果：reset 后才到，填上仍在等的消息，但不改状态、不把别的改成 Failed；旧的失败被忽略。
#[test]
fn stale_results_after_reset() {
    let (mut queue, ids) = queue_with(&["one", "two"], T0);
    let batch = take(&mut queue, T0 + 1.0);
    // 用户改了设置：在途的这一批作废，消息回到 Pending。
    queue.reset(T0 + 2.0);
    queue.fail(Failure::Server(500), &batch, T0 + 2.0);
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    // 作废的请求后来还是答了：结果照样填上，免得白付钱，但不释放新的在途位置。
    queue.complete(&BTreeMap::from([(ids[0], result("壹", None))]), &batch, None);
    assert_eq!(phases(&queue), vec![done("壹", None), Phase::Pending]);
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    assert!(!queue.has_batch_in_flight());
}

/// 清空缓冲不解除暂停；clear 清空一切，编号不复用；超过容量丢最早的；set_item_phase 改单条。
#[test]
fn clearing_and_capacity() {
    let (mut queue, ids) = queue_with(&["one"], T0);
    queue.fail(Failure::MissingKey, &[], T0);
    // 清空列表不解除暂停：Key 的问题还在。
    queue.remove_items(Some(ALPHA));
    assert!(queue.items(ALPHA).is_empty());
    assert_eq!(queue.status(), &TranslationStatus::Blocked(Failure::MissingKey));
    queue.clear();
    assert_eq!(queue.status(), &TranslationStatus::Idle);
    let next = queue.append(alpha("again"), Phase::Off, T0);
    assert!(next > ids[0]);
    // 总控重新判断后把这一条改成排队，时刻从这时算起。
    queue.set_item_phase(next, Phase::Pending, T0 + 3.0);
    assert_eq!(queue.next_attempt(), Some(T0 + 4.0));
    // 多放 5 条，最早的 5 条被丢掉（含前面那条 again）。
    for index in 0..CAPACITY_PER_CHARACTER + 5 {
        queue.append(alpha(&format!("m{index}")), Phase::Off, T0);
    }
    assert_eq!(queue.items(ALPHA).len(), CAPACITY_PER_CHARACTER);
    assert_eq!(queue.items(ALPHA)[0].message.text, "m5");
    assert_eq!(queue.all_items().len(), CAPACITY_PER_CHARACTER);
}
