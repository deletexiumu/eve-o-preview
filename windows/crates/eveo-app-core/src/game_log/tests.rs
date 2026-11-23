// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跟踪服务的用例：在临时目录里写假的 Gamelogs 文件，按给定的时刻逐步调 Worker::step，核对状态与事件。
// 对应 macOS 的 GameLogProbe 与 CombatLogTailer 的手工验证项：目录出现与消失、启动前已有的文件从末尾读、
// 启动后新建的文件从头读并丢掉旧行、登录界面阶段的文件、同一角色只跟最新文件、文件头没写完、截断与 UTF-16。
// 文件的修改时间是真实时间，而 step 的时刻用固定的 NOON：真实时间晚于 NOON，判断「48 小时内」时算作最近。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use eveo_core::combat_log::CombatLineKind::{IncomingDamage, IncomingMiss};
use eveo_core::combat_log::{CombatLineKind, CombatLogEvent, CombatLogStatus};

use super::worker::{PENDING_RESCAN_INTERVAL, RESCAN_INTERVAL, RETRY_INTERVAL, Worker};
use super::{GameLogMessage, GameLogTailer};

/// 2026-11-20 12:34:56 UTC。
const NOON: f64 = 1_795_178_096.0;
/// 文件头的分隔线。
const SEPARATOR: &str = "------------------------------------------------------------";

/// 每个用例自己的空目录。
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("eveo-game-log-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("建临时目录");
    dir
}

/// 文件头；`listener` 为 `None` 时是登录界面阶段的文件（分隔线之间只有两行）。
fn header(listener: Option<&str>) -> String {
    let middle = match listener {
        Some(name) => format!("  Game Log\n  Listener: {name}\n  Session Started: 2026.11.20 09:51:41\n"),
        None => "  Game Log\n  Session Started: 2026.11.20 09:51:41\n".to_owned(),
    };
    format!("{SEPARATOR}\n{middle}{SEPARATOR}\n")
}

/// 一行受到伤害。
fn hit(time: &str, amount: i64) -> String {
    format!(
        "[ {time} ] (combat) <color=0xffcc0000><b>{amount}</b> <color=0x77ffffff><font size=10>from</font> Sample Pilot\n"
    )
}

/// 一行对方未命中。
fn miss(time: &str) -> String {
    format!("[ {time} ] (combat) Sample Pilot misses you completely\n")
}

/// 在文件末尾追加文字。
fn append(path: &Path, text: &str) {
    let mut file = OpenOptions::new().append(true).open(path).expect("打开日志文件");
    file.write_all(text.as_bytes()).expect("写日志文件");
}

/// 走一步，返回这一步的消息。
fn step(worker: &mut Worker, now: f64) -> Vec<GameLogMessage> {
    let mut out = Vec::new();
    worker.step(now, &mut out);
    out
}

/// 角色 Aurora Vale 的一批事件。
fn events(kinds: &[CombatLineKind]) -> GameLogMessage {
    let events = kinds
        .iter()
        .map(|&kind| CombatLogEvent {
            character: "Aurora Vale".into(),
            kind,
        })
        .collect();
    GameLogMessage::Events(events)
}

/// 监视中的状态。
fn watching(dir: &Path, followed_files: usize) -> GameLogMessage {
    let directory = dir.to_str().expect("UTF-8 路径").to_owned();
    GameLogMessage::Status(CombatLogStatus::Watching {
        directory,
        followed_files,
    })
}

/// 启动后新建的文件（启动时刻取 0）：已有的旧行被丢掉，接入时刻附近的行与之后追加的行都上报。
#[test]
fn new_file_reads_from_start_and_drops_old_lines() {
    let dir = scratch("new-file");
    let log = dir.join("20261120_123400_1.txt");
    let text =
        header(Some("Aurora Vale")) + &hit("2026.11.20 11:00:00", 500) + &hit("2026.11.20 12:34:55", 42);
    fs::write(&log, text).expect("写日志文件");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], 0.0);
    assert_eq!(
        step(&mut worker, NOON),
        [watching(&dir, 1), events(&[IncomingDamage(42)])]
    );
    // 之后追加的行不再按时间过滤；一次读取里合并成「最大伤害 + 未命中」。
    append(
        &log,
        &(hit("2026.11.20 12:30:00", 7) + &miss("2026.11.20 12:35:01") + &hit("2026.11.20 12:35:02", 9)),
    );
    assert_eq!(
        step(&mut worker, NOON + 0.25),
        [events(&[IncomingDamage(9), IncomingMiss])]
    );
    assert!(step(&mut worker, NOON + 0.5).is_empty());
}

/// 启动前已有的文件（启动时刻在很久以后）从末尾读起：已有内容不上报，之后追加的才上报。
#[test]
fn existing_file_starts_at_end() {
    let dir = scratch("existing");
    let log = dir.join("20261120_095141_1.txt");
    fs::write(
        &log,
        header(Some("Aurora Vale")) + &hit("2026.11.20 12:34:56", 100),
    )
    .expect("写日志文件");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], f64::MAX);
    assert_eq!(step(&mut worker, NOON), [watching(&dir, 1)]);
    append(&log, &hit("2026.11.20 12:35:00", 77));
    assert_eq!(step(&mut worker, NOON + 0.25), [events(&[IncomingDamage(77)])]);
}

/// 登录界面阶段的文件不跟踪；同一角色只跟文件名最大的文件；不是 .txt 的文件不看。
#[test]
fn login_files_ignored_and_newest_per_listener() {
    let dir = scratch("select");
    fs::write(dir.join("20261120_090000_0.txt"), header(None)).expect("写");
    fs::write(dir.join("20261120_090000_1.txt"), header(Some("Aurora Vale"))).expect("写");
    fs::write(dir.join("20261120_100000_1.txt"), header(Some("Aurora Vale"))).expect("写");
    fs::write(dir.join("20261120_100000_2.txt"), header(Some("Borealis Kade"))).expect("写");
    fs::write(dir.join("notes.log"), header(Some("Cygnus Ward"))).expect("写");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], f64::MAX);
    assert_eq!(step(&mut worker, NOON), [watching(&dir, 2)]);
    assert_eq!(worker.followed(), 2);
}

/// 文件头还没写完时先不跟踪，1 秒后再扫；写完后开始跟踪。
#[test]
fn incomplete_header_rescanned_sooner() {
    let dir = scratch("pending");
    let log = dir.join("20261120_123456_1.txt");
    fs::write(&log, format!("{SEPARATOR}\n  Game Log\n")).expect("写");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], 0.0);
    assert_eq!(step(&mut worker, NOON), [watching(&dir, 0)]);
    append(
        &log,
        &format!("  Listener: Aurora Vale\n  Session Started: 2026.11.20 12:34:56\n{SEPARATOR}\n"),
    );
    assert!(step(&mut worker, NOON + PENDING_RESCAN_INTERVAL - 0.1).is_empty());
    assert_eq!(
        step(&mut worker, NOON + PENDING_RESCAN_INTERVAL),
        [watching(&dir, 1)]
    );
}

/// 新文件出现在下一次扫描时被跟踪；同一角色的新文件取代旧文件。
#[test]
fn new_file_picked_up_on_rescan() {
    let dir = scratch("rescan");
    fs::write(dir.join("20261120_090000_1.txt"), header(Some("Aurora Vale"))).expect("写");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], 0.0);
    assert_eq!(step(&mut worker, NOON), [watching(&dir, 1)]);
    let newer = dir.join("20261120_123500_1.txt");
    fs::write(
        &newer,
        header(Some("Aurora Vale")) + &hit("2026.11.20 12:35:00", 5),
    )
    .expect("写");
    fs::write(dir.join("20261120_123500_2.txt"), header(Some("Borealis Kade"))).expect("写");
    assert!(step(&mut worker, NOON + 1.0).is_empty());
    let messages = step(&mut worker, NOON + RESCAN_INTERVAL);
    assert_eq!(messages, [watching(&dir, 2), events(&[IncomingDamage(5)])]);
}

/// 文件被截断后从头读起，新内容照常上报（不再按积压过滤）。
#[test]
fn truncated_file_read_from_start() {
    let dir = scratch("truncate");
    let log = dir.join("20261120_123400_1.txt");
    fs::write(
        &log,
        header(Some("Aurora Vale")) + &hit("2026.11.20 12:34:56", 10),
    )
    .expect("写");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], 0.0);
    assert_eq!(
        step(&mut worker, NOON),
        [watching(&dir, 1), events(&[IncomingDamage(10)])]
    );
    fs::write(&log, hit("2026.11.20 08:00:00", 3)).expect("截断");
    assert_eq!(step(&mut worker, NOON + 0.25), [events(&[IncomingDamage(3)])]);
}

/// UTF-16 小端带 BOM 的文件照常读取。
#[test]
fn utf16_file() {
    let dir = scratch("utf16");
    let text = header(Some("Aurora Vale")).replace('\n', "\r\n")
        + &hit("2026.11.20 12:34:56", 64).replace('\n', "\r\n");
    let mut data = vec![0xFF, 0xFE];
    for unit in text.encode_utf16() {
        data.extend_from_slice(&unit.to_le_bytes());
    }
    fs::write(dir.join("20261120_123400_1.txt"), data).expect("写");
    let mut worker = Worker::new(vec![dir.to_str().expect("UTF-8").to_owned()], 0.0);
    assert_eq!(
        step(&mut worker, NOON),
        [watching(&dir, 1), events(&[IncomingDamage(64)])]
    );
}

/// 目录不存在时报告第一个候选，10 秒后重查；目录出现后开始监视，消失后又回到「找不到」。
#[test]
fn directory_appears_and_disappears() {
    let root = scratch("appear");
    let gamelogs = root.join("Gamelogs");
    let path = gamelogs.to_str().expect("UTF-8").to_owned();
    let mut worker = Worker::new(vec![path.clone()], 0.0);
    let not_found = GameLogMessage::Status(CombatLogStatus::DirectoryNotFound(path));
    assert_eq!(step(&mut worker, NOON), std::slice::from_ref(&not_found));
    fs::create_dir(&gamelogs).expect("建目录");
    assert!(step(&mut worker, NOON + 1.0).is_empty());
    assert_eq!(step(&mut worker, NOON + RETRY_INTERVAL), [watching(&gamelogs, 0)]);
    fs::remove_dir(&gamelogs).expect("删目录");
    assert_eq!(
        step(&mut worker, NOON + RETRY_INTERVAL + RESCAN_INTERVAL),
        [not_found]
    );
}

/// 第一个候选不存在时用第二个（设置的 logs 目录本身就放着日志文件的情况）。
#[test]
fn falls_back_to_second_candidate() {
    let root = scratch("fallback");
    let first = root.join("Gamelogs").to_str().expect("UTF-8").to_owned();
    let mut worker = Worker::new(vec![first, root.to_str().expect("UTF-8").to_owned()], 0.0);
    assert_eq!(step(&mut worker, NOON), [watching(&root, 0)]);
}

/// 后台线程：启动后很快报告「监视中」，丢掉服务后线程退出。
#[test]
fn tailer_thread_reports_status() {
    let dir = scratch("thread");
    let tailer = GameLogTailer::start(vec![dir.to_str().expect("UTF-8").to_owned()]).expect("开线程");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut messages = Vec::new();
    while messages.is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
        messages = tailer.drain();
    }
    assert_eq!(messages, [watching(&dir, 0)]);
    drop(tailer);
}
