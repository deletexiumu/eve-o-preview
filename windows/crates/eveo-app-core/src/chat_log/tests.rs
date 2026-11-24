// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志跟踪服务的用例：在临时目录里写假的 Chatlogs（UTF-16 小端，带 BOM）与 Gamelogs 文件，
// 按给定的时刻逐步调 Worker::step，核对上报的消息、位置线索、状态与覆盖情况。
// 对应 macOS 的 ChatLogProbe 与 ChatLogTailer 的手工验证项：启动前已有的文件补读、Local 与游戏日志的回读、
// 启动后新建的文件从头读、频道匹配与私聊、目录出现、文件头没写完、截断。
// 文件的修改时间是真实时间，而 step 的时刻用固定的 NOON：真实时间晚于 NOON，判断「48 小时内」时算作最近。
// 说话人、收听者与频道名都是虚构的；星系名是游戏的公开数据。

use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use eveo_core::chat_log::coverage::FollowedChatChannel;
use eveo_core::chat_log::request::ChatLogRequest;
use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus, ChatMessage, LocationHint, LocationHintSource};
use eveo_core::combat_log::framer::LogTextEncoding;
use eveo_core::model::ChannelRef;
use eveo_core::overlay::OverlayKind;

use super::file::{last_game_notes, lines};
use super::worker::{RETRY_INTERVAL, Worker};
use super::{ChatLogMessage, ChatLogTailer};

/// 2026-11-20 12:34:56 UTC。
const NOON: f64 = 1_795_178_096.0;
/// 虚构的收听者。
const PILOT: &str = "Kael Doran";
/// 虚构的说话人。
const SPEAKER: &str = "Mira Voss";
/// 虚构的玩家频道名与 ID。
const INTEL: (&str, &str) = ("intel.Demo", "player_0123456789abcdef0123456789abcdef");
/// 聊天日志文件头的分隔线（前面有缩进，与客户端写的一样）。
const CHAT_SEPARATOR: &str = "        ---------------------------------------------------------------";
/// 游戏日志文件头的分隔线。
const GAME_SEPARATOR: &str = "------------------------------------------------------------";

/// 每个用例自己的空目录，下面有 Chatlogs 与 Gamelogs。
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("eveo-chat-log-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("Chatlogs")).expect("建临时目录");
    fs::create_dir_all(dir.join("Gamelogs")).expect("建临时目录");
    dir
}

/// 路径的字符串形式。
fn text(path: &Path) -> String {
    path.to_str().expect("UTF-8 路径").to_owned()
}

/// 编成 UTF-16 小端的字节。
fn utf16(text: &str) -> Vec<u8> {
    text.encode_utf16().flat_map(u16::to_le_bytes).collect()
}

/// 聊天日志的文件头：U+FEFF 开头，两条分隔线之间是 4 个字段，各行以 LF 结尾。
fn chat_header(channel_id: &str, channel_name: &str) -> String {
    format!(
        "\u{FEFF}\n\n\n{CHAT_SEPARATOR}\n\n          Channel ID:      {channel_id}\n          Channel Name:    {channel_name}\n          Listener:        {PILOT}\n          Session started: 2026.11.20 11:33:40\n{CHAT_SEPARATOR}\n\n"
    )
}

/// 一行聊天消息：U+FEFF 开头，CRLF 结尾。
fn chat_line(time: &str, speaker: &str, body: &str) -> String {
    format!("\u{FEFF}[ {time} ] {speaker} > {body}\r\n")
}

/// 一行 Local 的系统消息。
fn system_line(time: &str, system: &str) -> String {
    chat_line(
        time,
        "EVE System",
        &format!("Channel changed to Local : {system}"),
    )
}

/// 游戏日志的文件头。
fn game_header() -> String {
    format!(
        "{GAME_SEPARATOR}\n  Game Log\n  Listener: {PILOT}\n  Session Started: 2026.11.20 09:51:41\n{GAME_SEPARATOR}\n"
    )
}

/// 游戏日志的一行 (None)。
fn game_note(time: &str, body: &str) -> String {
    format!("[ {time} ] (None) {body}\n")
}

/// 写一个 UTF-16 的聊天日志文件。
fn write_chat(path: &Path, text: &str) {
    fs::write(path, utf16(text)).expect("写聊天日志");
}

/// 在聊天日志末尾追加文字（UTF-16）。
fn append_chat(path: &Path, text: &str) {
    let mut file = OpenOptions::new().append(true).open(path).expect("打开聊天日志");
    file.write_all(&utf16(text)).expect("写聊天日志");
}

/// 在游戏日志末尾追加文字（UTF-8）。
fn append_game(path: &Path, text: &str) {
    let mut file = OpenOptions::new().append(true).open(path).expect("打开游戏日志");
    file.write_all(text.as_bytes()).expect("写游戏日志");
}

/// 跟踪玩家频道的请求；`follows_location` 为真时预警打开（另读位置线索）。
fn request(follows_location: bool) -> ChatLogRequest {
    ChatLogRequest {
        log_directory: None,
        channels: vec![ChannelRef::new(INTEL.0, None)],
        follows_location,
        backfill_seconds: 1_800.0,
        enabled_features: BTreeSet::from([OverlayKind::Intel]),
    }
}

/// 用临时目录建跟踪状态。
fn worker(dir: &Path, request: ChatLogRequest, started_at: f64) -> Worker {
    let chat = vec![text(&dir.join("Chatlogs"))];
    let game = vec![text(&dir.join("Gamelogs"))];
    Worker::with_candidates(request, chat, game, started_at)
}

/// 走一步，返回这一步的消息。
fn step(worker: &mut Worker, now: f64) -> Vec<ChatLogMessage> {
    let mut out = Vec::new();
    worker.step(now, &mut out);
    out
}

/// 监视中的状态。
fn watching(dir: &Path, followed_files: usize) -> ChatLogMessage {
    ChatLogMessage::Status(ChatLogStatus::Watching {
        directory: text(&dir.join("Chatlogs")),
        followed_files,
    })
}

/// 2026.11.20 某个时刻的 UTC 秒数（`hh:mm:ss`）。
fn at(clock: &str) -> f64 {
    let parts: Vec<f64> = clock.split(':').map(|p| p.parse().expect("数字")).collect();
    NOON - (12.0 * 3_600.0 + 34.0 * 60.0 + 56.0) + parts[0] * 3_600.0 + parts[1] * 60.0 + parts[2]
}

/// 玩家频道里的一条消息。
fn intel(clock: &str, body: &str, is_backfill: bool) -> ChatLogEvent {
    ChatLogEvent::Message(ChatMessage {
        listener: PILOT.into(),
        channel_id: INTEL.1.into(),
        channel_name: INTEL.0.into(),
        time: at(clock),
        speaker: SPEAKER.into(),
        text: body.into(),
        is_backfill,
    })
}

/// 一条位置线索。
fn hint(clock: &str, source: LocationHintSource, body: &str, is_backfill: bool) -> ChatLogEvent {
    ChatLogEvent::LocationHint(LocationHint {
        character: PILOT.into(),
        time: at(clock),
        source,
        text: body.into(),
        is_backfill,
    })
}

/// 覆盖情况里的一项。
fn followed(channel_id: &str, channel_name: &str) -> FollowedChatChannel {
    FollowedChatChannel {
        listener: PILOT.into(),
        channel_id: channel_id.into(),
        channel_name: Some(channel_name.into()),
    }
}

/// 启动前已有的文件：玩家频道补读窗口内的消息，Local 回读最后一条系统消息，游戏日志回读 (None) 行，
/// 合成一批按时间排好；之后追加的内容逐批上报。不在请求里的频道与私聊不跟踪。
#[test]
fn existing_files_backfill_then_tail() {
    let dir = scratch("existing");
    let chat = dir.join("Chatlogs");
    let intel_log = chat.join("intel.Demo_20261120_113340_123456789.txt");
    let local_log = chat.join("Local_20261120_113340_123456789.txt");
    let game_log = dir.join("Gamelogs").join("20261120_095141_123456789.txt");
    write_chat(
        &intel_log,
        &(chat_header(INTEL.1, INTEL.0)
            + &chat_line("2026.11.20 11:00:00", SPEAKER, "too old")
            + &chat_line("2026.11.20 12:30:00", SPEAKER, "1DQ1-A  Tarn Vex  Sabre nv")
            + &chat_line("2026.11.20 12:31:00", SPEAKER, "<br>")),
    );
    write_chat(
        &local_log,
        &(chat_header("local", "Local")
            + &system_line("2026.11.20 11:33:41", "Jita")
            + &chat_line("2026.11.20 12:32:00", SPEAKER, "o7")),
    );
    write_chat(
        &chat.join("Corp_20261120_113340_123456789.txt"),
        &chat_header("corp", "Corp"),
    );
    write_chat(
        &chat.join("Private Chat (Mira Voss)_20261120_113340_123456789.txt"),
        &chat_header("private_42", INTEL.0),
    );
    fs::write(
        &game_log,
        game_header()
            + &game_note("2026.11.20 12:20:00", "Jumping from Jita to Perimeter")
            + "[ 2026.11.20 12:21:00 ] (combat) ignored\n",
    )
    .expect("写游戏日志");

    let mut worker = worker(&dir, request(true), f64::MAX);
    let local = LocationHintSource::LocalChannel;
    let game = LocationHintSource::GameLog;
    assert_eq!(
        step(&mut worker, NOON),
        [
            ChatLogMessage::Followed(vec![followed("local", "Local"), followed(INTEL.1, INTEL.0)]),
            watching(&dir, 3),
            ChatLogMessage::Events(vec![
                hint("11:33:41", local, "Channel changed to Local : Jita", true),
                hint("12:20:00", game, "Jumping from Jita to Perimeter", true),
                intel("12:30:00", "1DQ1-A  Tarn Vex  Sabre nv", true),
            ]),
        ]
    );
    assert_eq!(worker.followed().len(), 3);

    // 之后追加的内容：玩家频道的消息、Local 的系统消息（Local 的普通消息不报）、游戏日志的 (None) 行。
    // 每个文件一批，按文件的键排序（chat/Local… 在 chat/intel… 前，聊天日志在游戏日志前）。
    append_chat(&intel_log, &chat_line("2026.11.20 12:35:00", SPEAKER, "clr"));
    append_chat(
        &local_log,
        &(system_line("2026.11.20 12:35:01", "Perimeter") + &chat_line("2026.11.20 12:35:02", SPEAKER, "hi")),
    );
    append_game(
        &game_log,
        &game_note("2026.11.20 12:35:03", "Undocking from Perimeter"),
    );
    assert_eq!(
        step(&mut worker, NOON + 0.25),
        [
            ChatLogMessage::Events(vec![hint(
                "12:35:01",
                local,
                "Channel changed to Local : Perimeter",
                false
            )]),
            ChatLogMessage::Events(vec![intel("12:35:00", "clr", false)]),
            ChatLogMessage::Events(vec![hint("12:35:03", game, "Undocking from Perimeter", false)]),
        ]
    );
    assert!(step(&mut worker, NOON + 0.5).is_empty());
}

/// 预警关着（只翻译）：不读 Local 与游戏日志；启动后新建的文件从头读，消息不算补读。
#[test]
fn new_file_without_location() {
    let dir = scratch("new-file");
    let chat = dir.join("Chatlogs");
    write_chat(
        &chat.join("Local_20261120_113340_123456789.txt"),
        &(chat_header("local", "Local") + &system_line("2026.11.20 12:34:00", "Jita")),
    );
    fs::write(
        dir.join("Gamelogs").join("20261120_095141_1.txt"),
        game_header() + &game_note("2026.11.20 12:20:00", "Jumping from Jita to Perimeter"),
    )
    .expect("写游戏日志");
    let intel_log = chat.join("intel.Demo_20261120_123400_123456789.txt");
    write_chat(
        &intel_log,
        &(chat_header(INTEL.1, INTEL.0) + &chat_line("2026.11.20 12:34:50", SPEAKER, "Jita +1")),
    );
    let mut worker = worker(&dir, request(false), 0.0);
    assert_eq!(
        step(&mut worker, NOON),
        [
            ChatLogMessage::Followed(vec![followed(INTEL.1, INTEL.0)]),
            watching(&dir, 1),
            ChatLogMessage::Events(vec![intel("12:34:50", "Jita +1", false)]),
        ]
    );
    // 文件被截断（客户端重写）后从头读起：文件头被丢掉，消息照常上报。
    write_chat(
        &intel_log,
        &(chat_header(INTEL.1, INTEL.0) + &chat_line("2026.11.20 12:36:00", SPEAKER, "again")),
    );
    assert_eq!(
        step(&mut worker, NOON + 0.25),
        [ChatLogMessage::Events(vec![intel("12:36:00", "again", false)])]
    );
}

/// 目录不存在时报 DirectoryNotFound，10 秒后重查；出现后开始监视。游戏日志目录不存在不改状态。
#[test]
fn directory_appears_later() {
    let dir = scratch("appears");
    fs::remove_dir_all(dir.join("Chatlogs")).expect("删临时目录");
    fs::remove_dir_all(dir.join("Gamelogs")).expect("删临时目录");
    let mut worker = worker(&dir, request(true), f64::MAX);
    let missing = text(&dir.join("Chatlogs"));
    assert_eq!(
        step(&mut worker, NOON),
        [ChatLogMessage::Status(ChatLogStatus::DirectoryNotFound(missing))]
    );
    fs::create_dir_all(dir.join("Chatlogs")).expect("建临时目录");
    assert!(step(&mut worker, NOON + 1.0).is_empty());
    assert_eq!(
        step(&mut worker, NOON + RETRY_INTERVAL),
        [ChatLogMessage::Followed(Vec::new()), watching(&dir, 0)]
    );
}

/// 文件头没写完时第一次不报覆盖情况，1 秒后再扫；写完后开始跟踪并补读。
#[test]
fn pending_header_waits() {
    let dir = scratch("pending");
    let intel_log = dir
        .join("Chatlogs")
        .join("intel.Demo_20261120_113340_123456789.txt");
    write_chat(&intel_log, &format!("\u{FEFF}\n\n\n{CHAT_SEPARATOR}\n"));
    let mut worker = worker(&dir, request(false), f64::MAX);
    assert_eq!(step(&mut worker, NOON), [watching(&dir, 0)]);
    write_chat(
        &intel_log,
        &(chat_header(INTEL.1, INTEL.0) + &chat_line("2026.11.20 12:34:00", SPEAKER, "nv")),
    );
    assert!(step(&mut worker, NOON + 0.5).is_empty());
    assert_eq!(
        step(&mut worker, NOON + 1.0),
        [
            ChatLogMessage::Followed(vec![followed(INTEL.1, INTEL.0)]),
            watching(&dir, 1),
            ChatLogMessage::Events(vec![intel("12:34:00", "nv", true)]),
        ]
    );
}

/// 一次性读取：起点在文件中间时丢掉第一行（可能是半行），最后一行没有换行也算；游戏日志至多回读 20 条。
#[test]
fn one_shot_reads() {
    let dir = scratch("reads");
    let path = dir.join("Chatlogs").join("sample.txt");
    let body =
        chat_line("2026.11.20 12:00:00", SPEAKER, "first") + "\u{FEFF}[ 2026.11.20 12:00:01 ] tail > x";
    write_chat(&path, &body);
    let file = fs::File::open(&path).expect("打开");
    let size = fs::metadata(&path).expect("长度").len();
    let utf16 = LogTextEncoding::Utf16LittleEndian;
    assert_eq!(lines(&file, 0, size, utf16).len(), 2);
    assert_eq!(
        lines(&file, 4, size, utf16),
        ["\u{FEFF}[ 2026.11.20 12:00:01 ] tail > x"]
    );

    let game = dir.join("Gamelogs").join("notes.txt");
    let notes: String = (0..25)
        .map(|i| game_note(&format!("2026.11.20 12:00:{i:02}"), &format!("note {i}")))
        .collect();
    fs::write(&game, game_header() + &notes).expect("写游戏日志");
    let file = fs::File::open(&game).expect("打开");
    let size = fs::metadata(&game).expect("长度").len();
    let found = last_game_notes(&file, size, LogTextEncoding::Utf8);
    assert_eq!(found.len(), 20);
    assert_eq!(found[0].1, "note 5");
    assert_eq!(found[19].1, "note 24");
}

/// 后台线程：开始后很快报出状态；丢掉服务后线程退出。
#[test]
fn tailer_reports_status() {
    let dir = scratch("tailer");
    let mut request = request(false);
    request.log_directory = Some(text(&dir.join("Chatlogs")));
    let tailer = ChatLogTailer::start(request.clone(), r"C:\Unused").expect("开线程");
    assert_eq!(tailer.request(), &request);
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen = Vec::new();
    while Instant::now() < deadline && !seen.iter().any(|m| matches!(m, ChatLogMessage::Status(_))) {
        seen.extend(tailer.drain());
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(seen.contains(&watching(&dir, 0)));
    drop(tailer);
}
