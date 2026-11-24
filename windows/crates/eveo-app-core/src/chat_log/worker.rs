// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的跟踪逻辑，对应 macOS 的 ChatLogTailer.swift。macOS 靠 kqueue 的目录与文件事件驱动，
// 这里同游戏日志一样改成由后台线程每 250 毫秒调一次 step 的轮询（理由见 game_log/worker.rs）。
// 规则与 macOS 相同：
// - 两个目录：Chatlogs（聊天日志）与 Gamelogs（游戏日志，只在 follows_location 为真时读，取位置线索）。
//   各取候选里第一个能列出的目录。状态只反映聊天日志目录：不存在是 DirectoryNotFound，被拒绝是 AccessDenied；
//   任一目录不可用时每 10 秒重查。文件数含两种日志。
// - 扫描：接入时一次，之后每 3 秒一次；有文件头没写完的文件时 1 秒后再扫。
//   聊天日志按 5.4 节的 6 条规则取文件，至多 48 个；游戏日志每个收听者取文件名最大的一个，至多 16 个。
// - 起点：启动前已有的文件先补读再读新增；启动后才建的文件从 0 读起；同一个服务里再次跟踪的文件从末尾读起。
// - 补读：聊天日志读末尾至多 512 KiB，丢掉早于 backfill_seconds 的行；Local 文件另回读最后一条系统消息；
//   游戏日志回读末尾 2 MiB 里最后 20 条 (None) 行。一步里补读的事件按时间排好，合成一批上报，
//   浮窗的第一次内容更新就带着补读的内容。
// - 读取：每一步查每个文件的长度，有新内容就读；一次读取的事件合成一批。
// - 上报（5.5 节）：非系统消息在频道匹配、正文不空时上报 Message；Local 文件的系统消息在 follows_location
//   为真时上报 LocationHint；游戏日志的 (None) 行上报 LocationHint。其他系统消息丢弃。只上报原文，不查星图数据。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};

use eveo_core::chat_log::coverage::FollowedChatChannel;
use eveo_core::chat_log::directory::{
    self as chat_directory, MAX_FOLLOWED_FILES as MAX_CHAT_FILES, RECENT_SECONDS, backfill_start,
    parse_file_name,
};
use eveo_core::chat_log::request::ChatLogRequest;
use eveo_core::chat_log::{
    ChatChannelKind, ChatLine, ChatLogEvent, ChatLogHeader, ChatLogStatus, ChatMessage, LocationHint,
    LocationHintSource, location, parser,
};
use eveo_core::combat_log::directory::{
    self as game_directory, MAX_FOLLOWED_FILES as MAX_GAME_FILES, is_log_file_name, is_recent, starts_at_end,
};
use eveo_core::combat_log::framer::LogTextEncoding;

use super::ChatLogMessage;
use super::file::{
    ChatHeaderProbe, FollowedFile, Role, last_game_notes, last_local_system_line, probe_chat_header,
};
use crate::game_log::file::{Entry, HeaderProbe, Listing, list, probe_header};

/// 两次扫描之间的间隔（秒）。
pub(super) const RESCAN_INTERVAL: f64 = 3.0;
/// 有文件头没写完的文件时，下次扫描的间隔（秒）。
pub(super) const PENDING_RESCAN_INTERVAL: f64 = 1.0;
/// 目录不存在或被拒绝时重查的间隔（秒）。
pub(super) const RETRY_INTERVAL: f64 = 10.0;
/// 聊天日志补读的字节数：512 KiB。
pub(super) const BACKFILL_BYTES: u64 = 524_288;

/// 两个目录之一。文件的键是前缀加文件名，两种日志的文件名不会冲突。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Side {
    /// Chatlogs。
    Chat,
    /// Gamelogs（位置线索）。
    Game,
}

impl Side {
    /// 这一侧的文件键的前缀。
    fn prefix(self) -> &'static str {
        match self {
            Side::Chat => "chat/",
            Side::Game => "game/",
        }
    }
}

/// 被监视的一个目录。
#[derive(Debug)]
struct Watch {
    /// 按优先顺序排列的候选目录。
    candidates: Vec<String>,
    /// 正在监视的目录；`None` 表示还没找到或已断开。
    path: Option<String>,
    /// 下次扫描的时刻。
    next_rescan: f64,
    /// 下次重查目录的时刻（没有目录时才用）。
    next_retry: f64,
}

impl Watch {
    /// 用候选目录建；第一步立即查找，与启动时刻无关。
    fn new(candidates: Vec<String>) -> Self {
        Self {
            candidates,
            path: None,
            next_rescan: f64::NEG_INFINITY,
            next_retry: f64::NEG_INFINITY,
        }
    }
}

/// 缓存的游戏日志文件头：收听者（`None` 表示忽略，登录界面阶段的文件）与编码。
#[derive(Debug, Clone)]
struct GameHeader {
    /// 收听者。
    listener: Option<String>,
    /// 编码。
    encoding: Option<LogTextEncoding>,
}

/// 一个文件的起点。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StartPoint {
    /// 同一个服务里再次跟踪（目录恢复、文件重新被选中）：从末尾读起，不再补读，免得重复上报。
    Refollow,
    /// 启动前已有：先补读，再从末尾读新增。
    PreExisting,
    /// 启动后才建：从 0 读起。
    Created,
}

/// 跟踪的全部状态。只在后台线程上使用。
#[derive(Debug)]
pub(super) struct Worker {
    /// 跟踪请求。
    request: ChatLogRequest,
    /// 开始跟踪的时刻，用来判断文件是启动前已有的还是启动后新建的。
    started_at: f64,
    /// 聊天日志目录。
    chat: Watch,
    /// 游戏日志目录；follows_location 为假时为 `None`。
    game: Option<Watch>,
    /// 正在跟踪的文件，键是 `chat/` 或 `game/` 加文件名。
    files: BTreeMap<String, FollowedFile>,
    /// 聊天日志的文件头，按文件名缓存；只缓存完整的文件头，只保留目录里还在的文件。
    chat_headers: HashMap<String, ChatLogHeader>,
    /// 游戏日志的文件头，按文件名缓存。
    game_headers: HashMap<String, GameHeader>,
    /// 跟踪过的文件的键，只保留目录里还在的文件。
    ever_followed: HashSet<String>,
    /// 这一步里补读到的事件，步末按时间排好合成一批上报。
    backfill: Vec<ChatLogEvent>,
    /// 当前对外报告的状态；只在变化时发消息。
    status: ChatLogStatus,
    /// 最近一次上报的覆盖情况；`None` 表示还没上报过。只在变化时发消息。
    reported_followed: Option<Vec<FollowedChatChannel>>,
}

impl Worker {
    /// 按请求建跟踪状态。`automatic` 是自动查找的 logs 目录；第一次 `step` 立即查找目录。
    pub fn new(request: ChatLogRequest, automatic: &str, started_at: f64) -> Self {
        let configured = request.log_directory.as_deref();
        let chat = chat_directory::candidates(configured, automatic);
        let game = chat_directory::game_log_candidates(configured, automatic);
        Self::with_candidates(request, chat, game, started_at)
    }

    /// 用给定的候选目录建跟踪状态；游戏日志的候选只在 follows_location 为真时用。
    /// 测试直接给临时目录（候选目录的拼接用 Windows 的分隔符）。
    pub fn with_candidates(
        request: ChatLogRequest,
        chat: Vec<String>,
        game: Vec<String>,
        started_at: f64,
    ) -> Self {
        let game = request.follows_location.then(|| Watch::new(game));
        Self {
            request,
            started_at,
            chat: Watch::new(chat),
            game,
            files: BTreeMap::new(),
            chat_headers: HashMap::new(),
            game_headers: HashMap::new(),
            ever_followed: HashSet::new(),
            backfill: Vec::new(),
            status: ChatLogStatus::Stopped,
            reported_followed: None,
        }
    }

    /// 走一步：两个目录各自到点时查找或扫描，补读的事件合成一批，然后读全部被跟踪文件的新内容。
    pub fn step(&mut self, now: f64, out: &mut Vec<ChatLogMessage>) {
        for side in [Side::Chat, Side::Game] {
            let Some(watch) = self.watch(side) else {
                continue;
            };
            if watch.path.is_none() && now >= watch.next_retry {
                self.resolve(side, now, out);
            } else if watch.path.is_some() && now >= watch.next_rescan {
                self.rescan(side, now, out);
            }
        }
        // 状态只反映聊天日志目录；两侧都扫描完再报，文件数含两种日志，第一步不会先报一半。
        if let Some(directory) = self.chat.path.clone() {
            let followed_files = self.files.len();
            self.set_status(
                ChatLogStatus::Watching {
                    directory,
                    followed_files,
                },
                out,
            );
        }
        self.flush_backfill(out);
        self.read_all(out);
    }

    /// 正在跟踪的文件的键（测试用）。
    #[cfg(test)]
    pub fn followed(&self) -> Vec<String> {
        self.files.keys().cloned().collect()
    }

    /// 一侧的目录；游戏日志在不读位置线索时为 `None`。
    fn watch(&self, side: Side) -> Option<&Watch> {
        match side {
            Side::Chat => Some(&self.chat),
            Side::Game => self.game.as_ref(),
        }
    }

    /// 一侧的目录（可变）。
    fn watch_mut(&mut self, side: Side) -> Option<&mut Watch> {
        match side {
            Side::Chat => Some(&mut self.chat),
            Side::Game => self.game.as_mut(),
        }
    }

    // MARK: 目录

    /// 取候选里第一个能列出的目录并扫描；都不行时（聊天日志目录）设状态，10 秒后重查。
    fn resolve(&mut self, side: Side, now: f64, out: &mut Vec<ChatLogMessage>) {
        let candidates = self.watch(side).map(|w| w.candidates.clone()).unwrap_or_default();
        for path in &candidates {
            match list(Path::new(path)) {
                Listing::Entries(entries) => {
                    if let Some(watch) = self.watch_mut(side) {
                        watch.path = Some(path.clone());
                    }
                    self.scan(side, &entries, now, out);
                    return;
                }
                Listing::Denied => {
                    self.enter_retry(side, ChatLogStatus::AccessDenied(path.clone()), now, out);
                    return;
                }
                Listing::Missing => {}
            }
        }
        let first = candidates.first().cloned().unwrap_or_default();
        self.enter_retry(side, ChatLogStatus::DirectoryNotFound(first), now, out);
    }

    /// 进入重查：记下重查时刻；聊天日志目录还要设状态（游戏日志目录不可用时不改对外的状态）。
    fn enter_retry(&mut self, side: Side, status: ChatLogStatus, now: f64, out: &mut Vec<ChatLogMessage>) {
        if let Some(watch) = self.watch_mut(side) {
            watch.next_retry = now + RETRY_INTERVAL;
        }
        if side == Side::Chat {
            self.set_status(status, out);
        }
    }

    /// 停止监视一侧的目录：关闭这一侧的全部文件，清掉这一侧的文件头缓存。跟踪过的名单保留。
    fn detach(&mut self, side: Side) {
        self.files.retain(|key, _| !key.starts_with(side.prefix()));
        match side {
            Side::Chat => self.chat_headers.clear(),
            Side::Game => self.game_headers.clear(),
        }
        if let Some(watch) = self.watch_mut(side) {
            watch.path = None;
        }
    }

    /// 重新列目录并扫描。目录不见了时立即重新查找，被拒绝时转入重查。
    fn rescan(&mut self, side: Side, now: f64, out: &mut Vec<ChatLogMessage>) {
        let Some(path) = self.watch(side).and_then(|w| w.path.clone()) else {
            return;
        };
        match list(Path::new(&path)) {
            Listing::Entries(entries) => self.scan(side, &entries, now, out),
            Listing::Denied => {
                self.detach(side);
                self.enter_retry(side, ChatLogStatus::AccessDenied(path), now, out);
            }
            Listing::Missing => {
                self.detach(side);
                self.resolve(side, now, out);
            }
        }
    }

    // MARK: 扫描

    /// 按目录条目决定跟踪哪些文件，并排下一次扫描。
    fn scan(&mut self, side: Side, entries: &[Entry], now: f64, out: &mut Vec<ChatLogMessage>) {
        let Some(directory) = self.watch(side).and_then(|w| w.path.clone()) else {
            return;
        };
        let pending = match side {
            Side::Chat => self.scan_chat(&directory, entries, now, out),
            Side::Game => self.scan_game(&directory, entries, now),
        };
        if let Some(watch) = self.watch_mut(side) {
            watch.next_rescan = now
                + if pending {
                    PENDING_RESCAN_INTERVAL
                } else {
                    RESCAN_INTERVAL
                };
        }
    }

    /// 聊天日志的扫描（5.4 节的 6 条规则）。返回是否有文件头没写完的文件。
    fn scan_chat(
        &mut self,
        directory: &str,
        entries: &[Entry],
        now: f64,
        out: &mut Vec<ChatLogMessage>,
    ) -> bool {
        let mut candidates = Vec::new();
        let mut created = HashMap::new();
        let mut present = HashSet::new();
        let mut pending = false;
        for entry in entries {
            // 规则 1：文件名合法，48 小时内修改过。
            let Some(file_name) = parse_file_name(&entry.name) else {
                continue;
            };
            present.insert(entry.name.clone());
            if now - entry.modified_at > RECENT_SECONDS {
                continue;
            }
            // 规则 2：读文件头并按文件名缓存；不完整的不缓存，1 秒后的扫描重读。
            if !self.chat_headers.contains_key(&entry.name) {
                match probe_chat_header(&path(directory, &entry.name)) {
                    ChatHeaderProbe::Complete(header) => {
                        self.chat_headers.insert(entry.name.clone(), header);
                    }
                    ChatHeaderProbe::Incomplete => pending = true,
                    ChatHeaderProbe::Unreadable => {}
                }
            }
            let Some(header) = self.chat_headers.get(&entry.name) else {
                continue;
            };
            // 规则 3、4：要有收听者与 Channel ID，不是私聊；与请求的频道匹配，或是读位置线索用的 Local。
            let (Some(listener), Some(channel_id)) = (&header.listener, &header.channel_id) else {
                continue;
            };
            let kind = header.kind();
            let wanted = self
                .request
                .is_requested(Some(channel_id), header.channel_name.as_deref())
                || (self.request.follows_location && kind == ChatChannelKind::Local);
            if kind == ChatChannelKind::PrivateChat || !wanted {
                continue;
            }
            candidates.push(chat_directory::Candidate {
                name: entry.name.clone(),
                stamp: file_name.stamp,
                listener: listener.clone(),
                channel_id: channel_id.clone(),
            });
            created.insert(entry.name.clone(), entry.created_at);
        }
        // 已不在目录里的文件不再缓存，缓存的大小随目录变化而不是一直增长。
        self.chat_headers.retain(|name, _| present.contains(name));
        self.forget_missing(Side::Chat, &present);
        // 规则 5、6：每个（收听者，频道 ID）最新的一个，至多 48 个；不再被选中的停止跟踪。
        let selected = chat_directory::select_followed(&candidates, MAX_CHAT_FILES);
        self.files
            .retain(|key, file| !key.starts_with(Side::Chat.prefix()) || selected.contains(&file.name));
        for name in &selected {
            if !self.files.contains_key(&key(Side::Chat, name)) {
                let created_at = created.get(name).copied().flatten();
                self.follow_chat(directory, name, created_at, now);
            }
        }
        // 用 48 个上限之前的候选：被上限挤掉的文件仍然存在，提示「EVE 没有写日志」不对。
        // 第一次上报前若还有文件头没写完的文件，先不报，免得启动时闪一下提示（1 秒后的扫描会再报）。
        if !pending || self.reported_followed.is_some() {
            self.report_followed(&candidates, out);
        }
        pending
    }

    /// 上报候选文件（48 小时内、频道匹配）的收听者与频道；去重、排序后与上次相同时不报。
    /// 没被选中或没打开成功的文件也算：文件在，提示「没有日志文件」反而误导。
    fn report_followed(&mut self, candidates: &[chat_directory::Candidate], out: &mut Vec<ChatLogMessage>) {
        let seen: BTreeSet<(String, String, Option<String>)> = candidates
            .iter()
            .map(|c| {
                let name = self
                    .chat_headers
                    .get(&c.name)
                    .and_then(|h| h.channel_name.clone());
                (c.listener.clone(), c.channel_id.clone(), name)
            })
            .collect();
        // BTreeSet 已按（收听者，频道 ID，频道名）排好，结果稳定，只在内容真的变了时上报。
        let followed: Vec<_> = seen
            .into_iter()
            .map(|(listener, channel_id, channel_name)| FollowedChatChannel {
                listener,
                channel_id,
                channel_name,
            })
            .collect();
        if self.reported_followed.as_ref() != Some(&followed) {
            self.reported_followed = Some(followed.clone());
            out.push(ChatLogMessage::Followed(followed));
        }
    }

    /// 游戏日志的扫描：48 小时内修改过、有收听者的文件，每个收听者取文件名最大的一个，至多 16 个。
    /// 返回是否有文件头没写完的文件。
    fn scan_game(&mut self, directory: &str, entries: &[Entry], now: f64) -> bool {
        let mut candidates = Vec::new();
        let mut created = HashMap::new();
        let mut present = HashSet::new();
        let mut pending = false;
        for entry in entries.iter().filter(|e| is_log_file_name(&e.name)) {
            present.insert(entry.name.clone());
            if !is_recent(entry.modified_at, now) {
                continue;
            }
            if !self.game_headers.contains_key(&entry.name) {
                match probe_header(&path(directory, &entry.name)) {
                    HeaderProbe::Complete { listener, encoding } => {
                        self.game_headers
                            .insert(entry.name.clone(), GameHeader { listener, encoding });
                    }
                    HeaderProbe::Incomplete => pending = true,
                    HeaderProbe::Unreadable => {}
                }
            }
            if let Some(listener) = self
                .game_headers
                .get(&entry.name)
                .and_then(|h| h.listener.clone())
            {
                candidates.push(game_directory::Candidate {
                    name: entry.name.clone(),
                    listener,
                });
                created.insert(entry.name.clone(), entry.created_at);
            }
        }
        self.game_headers.retain(|name, _| present.contains(name));
        self.forget_missing(Side::Game, &present);
        // 与受击提醒相同的取舍规则：每个收听者取文件名最大的一个，至多 16 个。
        let selected = game_directory::select_followed(&candidates, MAX_GAME_FILES);
        self.files
            .retain(|key, file| !key.starts_with(Side::Game.prefix()) || selected.contains(&file.name));
        for name in &selected {
            if !self.files.contains_key(&key(Side::Game, name)) {
                self.follow_game(directory, name, created.get(name).copied().flatten());
            }
        }
        pending
    }

    /// 跟踪过的名单只保留目录里还在的文件。
    fn forget_missing(&mut self, side: Side, present: &HashSet<String>) {
        let prefix = side.prefix();
        self.ever_followed
            .retain(|key| key.strip_prefix(prefix).is_none_or(|name| present.contains(name)));
    }

    // MARK: 开始跟踪

    /// 判断起点，并把键记进跟踪过的名单。
    fn start_point(&mut self, key: &str, created_at: Option<f64>) -> StartPoint {
        if !self.ever_followed.insert(key.to_owned()) {
            StartPoint::Refollow
        } else if starts_at_end(created_at, self.started_at) {
            StartPoint::PreExisting
        } else {
            StartPoint::Created
        }
    }

    /// 开始跟踪一个聊天日志文件，按起点补读或从头读。
    fn follow_chat(&mut self, directory: &str, name: &str, created_at: Option<f64>, now: f64) {
        let Some(header) = self.chat_headers.get(name).cloned() else {
            return;
        };
        let Some(listener) = header.listener.clone() else {
            return;
        };
        let requested = self
            .request
            .is_requested(header.channel_id.as_deref(), header.channel_name.as_deref());
        let kind = header.kind();
        let role = Role::Chat {
            header,
            kind,
            requested,
        };
        let utf16 = LogTextEncoding::Utf16LittleEndian;
        let Some(mut file) = FollowedFile::open(&path(directory, name), name, &listener, role, utf16) else {
            return;
        };
        // 读不到长度时不登记，免得它停在偏移量 0、把旧内容当成新内容读出来。
        let Some(end) = file.current_size() else {
            return;
        };
        let key = key(Side::Chat, name);
        match self.start_point(&key, created_at) {
            StartPoint::Refollow => file.seek(end, false),
            StartPoint::Created => file.seek(0, false),
            StartPoint::PreExisting => {
                // 先回读位置线索：不按时间过滤，取 Local 文件里最近的一条系统消息（5.6 节来源一）。
                if kind == ChatChannelKind::Local
                    && self.request.follows_location
                    && let Some(line) = last_local_system_line(file.handle(), end)
                {
                    let source = LocationHintSource::LocalChannel;
                    self.backfill
                        .push(hint(&listener, line.time, source, line.text, true));
                }
                if requested {
                    self.backfill_messages(&mut file, end, now);
                } else {
                    file.seek(end, false);
                }
            }
        }
        self.files.insert(key, file);
    }

    /// 补读聊天日志末尾至多 512 KiB 的消息（5.4 节「补读的做法」），之后从 `end` 读新增内容。
    ///
    /// 系统消息不在这里上报位置线索：Local 文件的线索由回读给出，避免重复。
    fn backfill_messages(&mut self, file: &mut FollowedFile, end: u64, now: f64) {
        file.seek(backfill_start(end, BACKFILL_BYTES), true);
        let mut lines = Vec::new();
        // 512 KiB 小于一次读取的上限，通常一轮就读完；读到 end 为止，end 之后的内容留给之后的读取。
        loop {
            let (more_lines, more) = file.read_lines(Some(end));
            lines.extend(more_lines);
            if !more {
                break;
            }
        }
        // 日志里的时间是 UTC（EVE 时间），与墙上时钟同一基准。
        let cutoff = now - self.request.backfill_seconds;
        let events = lines
            .iter()
            .filter_map(|raw| parser::parse_line(raw))
            .filter(|line| !line.is_system && line.time >= cutoff)
            .filter_map(|line| message(line, file, true));
        self.backfill.extend(events);
    }

    /// 开始跟踪一个游戏日志文件。启动前已有的文件回读最后 20 条 (None) 行（5.6 节来源二）。
    fn follow_game(&mut self, directory: &str, name: &str, created_at: Option<f64>) {
        let Some(header) = self.game_headers.get(name).cloned() else {
            return;
        };
        let Some(listener) = header.listener else {
            return;
        };
        let encoding = header.encoding.unwrap_or(LogTextEncoding::Utf8);
        let Some(mut file) =
            FollowedFile::open(&path(directory, name), name, &listener, Role::Game, encoding)
        else {
            return;
        };
        let Some(end) = file.current_size() else {
            return;
        };
        let key = key(Side::Game, name);
        match self.start_point(&key, created_at) {
            StartPoint::Refollow => file.seek(end, false),
            StartPoint::Created => file.seek(0, false),
            StartPoint::PreExisting => {
                let source = LocationHintSource::GameLog;
                for (time, text) in last_game_notes(file.handle(), end, file.encoding()) {
                    self.backfill.push(hint(&listener, time, source, text, true));
                }
                file.seek(end, false);
            }
        }
        self.files.insert(key, file);
    }

    // MARK: 读取与上报

    /// 读每个文件的新内容；每次读取的事件合成一批。
    fn read_all(&mut self, out: &mut Vec<ChatLogMessage>) {
        let follows_location = self.request.follows_location;
        for file in self.files.values_mut() {
            loop {
                let (lines, more) = file.read_lines(None);
                let events: Vec<_> = lines
                    .iter()
                    .filter_map(|raw| event_from(raw, file, follows_location))
                    .collect();
                if !events.is_empty() {
                    out.push(ChatLogMessage::Events(events));
                }
                if !more {
                    break;
                }
            }
        }
    }

    /// 把这一步补读到的事件按时间排好（时间相同的保持原顺序），合成一批上报。
    fn flush_backfill(&mut self, out: &mut Vec<ChatLogMessage>) {
        if self.backfill.is_empty() {
            return;
        }
        let mut events = std::mem::take(&mut self.backfill);
        // sort_by 是稳定排序。
        events.sort_by(|a, b| time_of(a).total_cmp(&time_of(b)));
        out.push(ChatLogMessage::Events(events));
    }

    /// 状态变了时发消息。
    fn set_status(&mut self, status: ChatLogStatus, out: &mut Vec<ChatLogMessage>) {
        if status != self.status {
            self.status = status.clone();
            out.push(ChatLogMessage::Status(status));
        }
    }
}

/// 把一行新内容转成事件（5.5 节）；不上报的行返回 `None`。
fn event_from(raw: &str, file: &FollowedFile, follows_location: bool) -> Option<ChatLogEvent> {
    match &file.role {
        Role::Chat { kind, .. } => {
            // 文件头的各行与不是「[ 时间 ] 说话人 > 正文」形式的行在这里被丢掉。
            let line = parser::parse_line(raw)?;
            if !line.is_system {
                return message(line, file, false);
            }
            (*kind == ChatChannelKind::Local && follows_location).then(|| {
                let source = LocationHintSource::LocalChannel;
                hint(&file.listener, line.time, source, line.text, false)
            })
        }
        Role::Game => {
            let (time, text) = location::game_note(raw)?;
            Some(hint(
                &file.listener,
                time,
                LocationHintSource::GameLog,
                text,
                false,
            ))
        }
    }
}

/// 一条非系统消息：频道与请求匹配、正文不空时才上报。
fn message(line: ChatLine, file: &FollowedFile, is_backfill: bool) -> Option<ChatLogEvent> {
    let Role::Chat {
        header,
        requested: true,
        ..
    } = &file.role
    else {
        return None;
    };
    let channel_id = header.channel_id.clone()?;
    if line.text.is_empty() {
        return None;
    }
    Some(ChatLogEvent::Message(ChatMessage {
        listener: file.listener.clone(),
        channel_name: header.channel_name.clone().unwrap_or_else(|| channel_id.clone()),
        channel_id,
        time: line.time,
        speaker: line.speaker,
        text: line.text,
        is_backfill,
    }))
}

/// 一条位置线索。
fn hint(
    character: &str,
    time: f64,
    source: LocationHintSource,
    text: String,
    is_backfill: bool,
) -> ChatLogEvent {
    ChatLogEvent::LocationHint(LocationHint {
        character: character.to_owned(),
        time,
        source,
        text,
        is_backfill,
    })
}

/// 事件里的日志时间。
fn time_of(event: &ChatLogEvent) -> f64 {
    match event {
        ChatLogEvent::Message(message) => message.time,
        ChatLogEvent::LocationHint(hint) => hint.time,
    }
}

/// 文件在跟踪服务里的键。
fn key(side: Side, name: &str) -> String {
    format!("{}{name}", side.prefix())
}

/// 目录下的文件路径。
fn path(directory: &str, name: &str) -> PathBuf {
    Path::new(directory).join(name)
}
