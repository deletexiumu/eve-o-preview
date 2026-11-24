// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对服务与缓存文件的用例。发请求的函数是假的（立即答复，或等测试放行），不联网；
// 缓存文件写在系统临时目录下各用例自己的子目录里。人名都是虚构的。

use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use eveo_core::intel::pilots::{
    PilotLookupAnswer, PilotLookupFailure, PilotLookupOutcome, PilotLookupStatus, PilotNameCacheEntry, key,
};
use eveo_core::intel::{IntelReport, IntelSegment, IntelSegmentKind};

use super::{PilotLookupService, PilotNameStore, Resolver};

/// 各用例自己的临时目录（先清空）。
fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("eveo-pilots-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// 一条缓存条目。
fn entry(name: &str, id: i64, time: f64) -> PilotNameCacheEntry {
    PilotNameCacheEntry {
        key: key(name),
        character_id: id,
        name: name.into(),
        time,
    }
}

/// 一条认作情报的消息：一个星系（让它算情报）加一个人名段。
fn report(pilot: &str) -> IntelReport {
    IntelReport {
        segments: vec![
            IntelSegment::new("Jita", IntelSegmentKind::System(30_000_142)),
            IntelSegment::new(" ", IntelSegmentKind::Plain),
            IntelSegment::new(pilot, IntelSegmentKind::Pilot),
        ],
        system_ids: vec![30_000_142],
        pilots: vec![pilot.into()],
        ..IntelReport::default()
    }
}

/// 假的发请求函数：把每个名字都答成查到（ID 按收到的顺序从 100 编），并记下收到的各批。
fn matching_resolver(log: Arc<Mutex<Vec<Vec<String>>>>) -> Resolver {
    Box::new(move |names: &[String]| {
        let mut batches = log.lock().unwrap();
        let base = 100 + batches.iter().map(Vec::len).sum::<usize>() as i64;
        batches.push(names.to_vec());
        let outcomes = names
            .iter()
            .enumerate()
            .map(|(i, name)| (key(name), PilotLookupOutcome::matched(base + i as i64, name)))
            .collect();
        Ok(PilotLookupAnswer::new(outcomes))
    })
}

/// 反复 tick 直到条件成立；2 秒内不成立时测试失败。每次 tick 的时刻是 now，用例里时间不往前走。
fn tick_until(service: &mut PilotLookupService, now: f64, mut done: impl FnMut(&PilotLookupService) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !done(service) {
        assert!(Instant::now() < deadline, "等待超时");
        service.tick(now);
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// 缓存文件：不存在时为空；写了能读回；格式版本不对或内容坏了时为空；目录不存在时自动创建。
#[test]
fn store_round_trip() {
    let dir = temp_dir("store");
    let store = PilotNameStore::in_dir(&dir.join("cache"));
    assert!(store.load().is_empty());
    let entries = vec![entry("Kael Doran", 7, 1_000.0), entry("Mira Voss", 8, 2_000.0)];
    store.save(&entries).unwrap();
    assert_eq!(store.load(), entries);
    // 将来的格式版本：不认识，按空缓存处理，不报错。
    std::fs::write(store.path(), r#"{"format": 2, "entries": []}"#).unwrap();
    assert!(store.load().is_empty());
    std::fs::write(store.path(), "not json").unwrap();
    assert!(store.load().is_empty());
    // 写入后目录里只剩缓存文件本身，临时文件已改名或删掉。
    store.save(&entries).unwrap();
    let names: Vec<String> = std::fs::read_dir(dir.join("cache"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["pilot-names.json"]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// 关着时：状态是 Off，目录为空，新消息不排，不读文件。
#[test]
fn disabled_service_is_inert() {
    let dir = temp_dir("disabled");
    // 记下发请求函数收到的各批，用来断言「一个请求也没发」。
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut service = PilotLookupService::new(PilotNameStore::in_dir(&dir), matching_resolver(log.clone()));
    assert_eq!(service.status(), PilotLookupStatus::Off);
    service.enqueue_report(&report("Kael Doran"), 0.0);
    assert_eq!(service.tick(10.0), super::PilotTick::default());
    assert!(service.directory().is_empty());
    assert!(!service.is_cache_loaded());
    assert!(log.lock().unwrap().is_empty());
}

/// 打开后在后台读缓存文件，读完时提示补排；文件里的角色马上能用；再开一次不重复提示。
#[test]
fn loads_cache_then_asks_for_backfill() {
    let dir = temp_dir("load");
    let store = PilotNameStore::in_dir(&dir);
    store.save(&[entry("Kael Doran", 7, 1_000.0)]).unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut service = PilotLookupService::new(store, matching_resolver(log));
    // 第一次打开：开始读文件，这时还不能补排（缓存里有什么还不知道）。
    // 读文件在后台线程，结果在之后的某次 tick 里收到。
    assert!(!service.set_enabled(true, 2_000.0));
    let deadline = Instant::now() + Duration::from_secs(2);
    let tick = loop {
        let tick = service.tick(2_000.0);
        if tick.wants_backfill || Instant::now() > deadline {
            break tick;
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    assert!(tick.wants_backfill && tick.changed);
    assert!(service.is_cache_loaded());
    assert_eq!(service.matched_count(), 1);
    assert_eq!(
        service.directory().outcome("kael doran"),
        Some(&PilotLookupOutcome::matched(7, "Kael Doran"))
    );
    assert_eq!(service.status(), PilotLookupStatus::Idle);
    // 已经开着时再设一次不提示补排；关了再开时提示。
    assert!(!service.set_enabled(true, 2_000.0));
    assert!(!service.set_enabled(false, 2_000.0));
    assert!(service.set_enabled(true, 2_000.0));
    let _ = std::fs::remove_dir_all(&dir);
}

/// 新消息的名字过了防抖后发出，结果进缓存、状态回到空闲；缓存里已有的名字不再查；退出时存盘。
#[test]
fn resolves_and_saves() {
    let dir = temp_dir("resolve");
    let store = PilotNameStore::in_dir(&dir);
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut service = PilotLookupService::new(store.clone(), matching_resolver(log.clone()));
    service.set_enabled(true, 0.0);
    tick_until(&mut service, 0.0, PilotLookupService::is_cache_loaded);
    service.enqueue_report(&report("Kael Doran"), 10.0);
    // 名字在 10.0 排进来。
    // 不足 0.5 秒的防抖：不发。
    assert!(!service.tick(10.2).changed);
    assert!(log.lock().unwrap().is_empty());
    assert!(service.tick(10.5).changed);
    assert_eq!(service.status(), PilotLookupStatus::Resolving);
    tick_until(&mut service, 11.0, |s| s.status() == PilotLookupStatus::Idle);
    // 「Kael Doran」一段两个词：3 个候选组合一起发出，都查到。
    assert_eq!(log.lock().unwrap()[0], ["Kael", "Kael Doran", "Doran"]);
    assert!(matches!(
        service.directory().outcome("Kael Doran"),
        Some(PilotLookupOutcome::Matched { .. })
    ));
    // 同一条消息再来一次：缓存里都有，不再排。
    service.enqueue_report(&report("Kael Doran"), 20.0);
    assert_eq!(service.next_attempt(), None);
    // 第一次存盘不等 30 秒；退出时等写入线程写完，文件里有 3 个角色。
    service.shutdown(21.0).unwrap();
    assert_eq!(store.load().len(), 3);
    let _ = std::fs::remove_dir_all(&dir);
}

/// 请求在途时关掉开关：迟到的结果丢掉，缓存不变；状态是 Off。再打开后照常工作。
#[test]
fn late_results_after_disable_are_dropped() {
    let dir = temp_dir("late");
    let (release, gate) = mpsc::channel::<()>();
    let gate = Mutex::new(gate);
    let resolver: Resolver = Box::new(move |names: &[String]| {
        // 等测试放行再答复，模拟慢请求。
        let _ = gate.lock().unwrap().recv();
        let outcomes = names
            .iter()
            .map(|name| (key(name), PilotLookupOutcome::matched(1, name)))
            .collect();
        Ok(PilotLookupAnswer::new(outcomes))
    });
    let mut service = PilotLookupService::new(PilotNameStore::in_dir(&dir), resolver);
    service.set_enabled(true, 0.0);
    tick_until(&mut service, 0.0, PilotLookupService::is_cache_loaded);
    service.enqueue_report(&report("Kael Doran"), 0.0);
    service.tick(1.0);
    assert_eq!(service.status(), PilotLookupStatus::Resolving);
    // 请求还卡在假的发请求函数里时关掉开关。
    service.set_enabled(false, 1.5);
    assert_eq!(service.status(), PilotLookupStatus::Off);
    release.send(()).unwrap();
    // 给后台线程时间交回结果，再 tick 几次：结果被丢掉。
    std::thread::sleep(Duration::from_millis(50));
    for _ in 0..5 {
        service.tick(2.0);
    }
    assert_eq!(service.matched_count(), 0);
    // 再打开：缓存已读完，提示补排；新的请求照常得到结果。
    assert!(service.set_enabled(true, 3.0));
    service.enqueue_report(&report("Mira Voss"), 3.0);
    release.send(()).unwrap();
    tick_until(&mut service, 4.0, |s| s.matched_count() == 3);
    let _ = std::fs::remove_dir_all(&dir);
}

/// 失败按种类退避：被限流时等 ESI 要求的秒数，名字回到待查。
#[test]
fn failures_back_off() {
    let dir = temp_dir("failure");
    // 每次都答「被限流，45 秒后再来」。
    let resolver: Resolver =
        Box::new(|_: &[String]| Err(PilotLookupFailure::RateLimited { retry_after: 45.0 }));
    let mut service = PilotLookupService::new(PilotNameStore::in_dir(&dir), resolver);
    service.set_enabled(true, 0.0);
    tick_until(&mut service, 0.0, PilotLookupService::is_cache_loaded);
    service.enqueue_report(&report("Kael Doran"), 0.0);
    service.tick(1.0);
    tick_until(&mut service, 1.0, |s| {
        matches!(s.status(), PilotLookupStatus::Waiting(_))
    });
    // 失败时刻是 1.0：等到 46.0。
    assert_eq!(service.status(), PilotLookupStatus::Waiting(46.0));
    assert_eq!(service.next_attempt(), Some(46.0));
    assert_eq!(service.matched_count(), 0);
}

/// 补排：从最新的消息往前收集，按比较键去重，缓存里已有的不排。
#[test]
fn backfill_collects_newest_first() {
    let dir = temp_dir("backfill");
    let store = PilotNameStore::in_dir(&dir);
    store.save(&[entry("Tarn Vex", 9, 0.0)]).unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut service = PilotLookupService::new(store, matching_resolver(log.clone()));
    service.set_enabled(true, 0.0);
    tick_until(&mut service, 0.0, PilotLookupService::is_cache_loaded);
    // 从最新到最旧：KAEL DORAN 与 Kael Doran 比较键相同，只排先出现的写法。
    let reports = [
        report("Mira Voss"),
        report("KAEL DORAN"),
        report("Kael Doran"),
        report("Tarn Vex"),
    ];
    // 只有 Tarn Vex 整串有结果；它的单词组合 Tarn、Vex 还没有，照样要查。
    service.enqueue_backfill(reports.iter(), 1.0);
    service.tick(2.0);
    tick_until(&mut service, 2.0, |s| s.status() == PilotLookupStatus::Idle);
    let batch = log.lock().unwrap()[0].clone();
    assert_eq!(
        batch,
        [
            "Mira",
            "Mira Voss",
            "Voss",
            "KAEL",
            "KAEL DORAN",
            "DORAN",
            "Tarn",
            "Vex"
        ]
    );
}

/// 清空：内存里的结果清掉，文件也写成空的。
#[test]
fn clear_empties_file() {
    let dir = temp_dir("clear");
    let store = PilotNameStore::in_dir(&dir);
    store.save(&[entry("Kael Doran", 7, 0.0)]).unwrap();
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut service = PilotLookupService::new(store.clone(), matching_resolver(log));
    service.set_enabled(true, 0.0);
    tick_until(&mut service, 0.0, PilotLookupService::is_cache_loaded);
    assert_eq!(service.matched_count(), 1);
    // 设置页的「清空已保存的角色名」。
    service.clear(1.0);
    assert_eq!(service.matched_count(), 0);
    assert!(service.directory().is_empty());
    service.shutdown(2.0).unwrap();
    assert!(store.load().is_empty());
    // 文件仍在，只是条目为空：下次启动读到的是空缓存，而不是读失败。
    assert!(store.path().exists());
    let _ = std::fs::remove_dir_all(&dir);
}
