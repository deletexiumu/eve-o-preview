// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的跟踪逻辑，对应 macOS 的 CombatLogTailer.swift。macOS 靠 kqueue 的目录与文件事件驱动，
// 这里改成由后台线程每 250 毫秒调一次 step 的轮询：
// - Windows 上正在写的文件，目录项里的长度与修改时间会滞后，文件事件也不可靠；查打开的句柄上的长度最准。
// - 轮询把全部状态放在一个线程里，step 接受外部给的时刻，能在 Linux 上用临时目录逐步测试。
// 规则与 macOS 相同：
// - 目录：取候选里第一个能列出的目录。都不存在时状态是 DirectoryNotFound，被拒绝时是 AccessDenied，每 10 秒重查。
// - 扫描：接入时一次，之后每 3 秒一次；有文件头没写完的文件时 1 秒后再扫。只看 48 小时内修改过的 .txt，
//   按文件头的收听者取每个角色文件名最大的文件，至多 16 个。目录不见了或被拒绝时转入重查。
// - 读取：每一步查每个文件的长度，有新内容就读；一次读取里每个文件至多产生两条受击事件。
// - 只有第一次跟踪的文件可能从头读起（启动后新建的）；之后再跟踪（目录恢复、重新出现）一律从末尾读起。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use eveo_core::combat_log::directory::{
    Candidate, MAX_FOLLOWED_FILES, is_log_file_name, is_recent, select_followed, starts_at_end,
};
use eveo_core::combat_log::framer::LogTextEncoding;
use eveo_core::combat_log::{CombatLogEvent, CombatLogStatus, parser, rules};

use super::GameLogMessage;
use super::file::{Entry, HeaderProbe, Listing, TailedFile, list, probe_header};

/// 两次扫描之间的间隔（秒）。
pub(super) const RESCAN_INTERVAL: f64 = 3.0;
/// 有文件头没写完的文件时，下次扫描的间隔（秒）。
pub(super) const PENDING_RESCAN_INTERVAL: f64 = 1.0;
/// 目录不存在或被拒绝时重查的间隔（秒）。
pub(super) const RETRY_INTERVAL: f64 = 10.0;

/// 缓存的文件头：收听者（`None` 表示忽略，登录界面阶段的文件）与编码。
#[derive(Debug, Clone)]
struct CachedHeader {
    /// 收听者。
    listener: Option<String>,
    /// 编码。
    encoding: Option<LogTextEncoding>,
}

/// 跟踪的全部状态。只在后台线程上使用。
#[derive(Debug)]
pub(super) struct Worker {
    /// 按优先顺序排列的候选目录。
    candidates: Vec<String>,
    /// 开始跟踪的时刻，用来判断文件是启动前已有的还是启动后新建的。
    started_at: f64,
    /// 正在监视的目录；`None` 表示还没找到或已断开。
    directory: Option<String>,
    /// 正在跟踪的文件，键是文件名。
    files: BTreeMap<String, TailedFile>,
    /// 文件头的探测结果，按文件名缓存；只保留目录里还在的文件。
    headers: HashMap<String, CachedHeader>,
    /// 跟踪过的文件名，只保留目录里还在的。
    ever_followed: HashSet<String>,
    /// 下次扫描的时刻。
    next_rescan: f64,
    /// 下次重查目录的时刻（没有目录时才用）。
    next_retry: f64,
    /// 当前对外报告的状态；只在变化时发消息。
    status: CombatLogStatus,
}

impl Worker {
    /// 建跟踪状态；第一次 `step` 立即查找目录。
    pub fn new(candidates: Vec<String>, started_at: f64) -> Self {
        Self {
            candidates,
            started_at,
            directory: None,
            files: BTreeMap::new(),
            headers: HashMap::new(),
            ever_followed: HashSet::new(),
            // 第一步立即查找目录，与启动时刻无关。
            next_rescan: f64::NEG_INFINITY,
            next_retry: f64::NEG_INFINITY,
            status: CombatLogStatus::Stopped,
        }
    }

    /// 走一步：到点时查找目录或扫描，然后读全部被跟踪文件的新内容。产生的消息追加到 `out`。
    pub fn step(&mut self, now: f64, out: &mut Vec<GameLogMessage>) {
        if self.directory.is_none() && now >= self.next_retry {
            self.resolve(now, out);
        } else if self.directory.is_some() && now >= self.next_rescan {
            self.rescan(now, out);
        }
        self.read_all(out);
    }

    /// 正在跟踪的文件数。
    #[cfg(test)]
    pub fn followed(&self) -> usize {
        self.files.len()
    }

    // MARK: 目录

    /// 取候选里第一个能列出的目录并扫描；都不行时设状态，10 秒后重查。
    fn resolve(&mut self, now: f64, out: &mut Vec<GameLogMessage>) {
        for path in self.candidates.clone() {
            match list(Path::new(&path)) {
                Listing::Entries(entries) => {
                    self.directory = Some(path);
                    self.scan(&entries, now, out);
                    return;
                }
                Listing::Denied => {
                    self.enter_retry(CombatLogStatus::AccessDenied(path), now, out);
                    return;
                }
                Listing::Missing => {}
            }
        }
        let first = self.candidates.first().cloned().unwrap_or_default();
        self.enter_retry(CombatLogStatus::DirectoryNotFound(first), now, out);
    }

    /// 进入重查：设状态，记下重查时刻。
    fn enter_retry(&mut self, status: CombatLogStatus, now: f64, out: &mut Vec<GameLogMessage>) {
        self.next_retry = now + RETRY_INTERVAL;
        self.set_status(status, out);
    }

    /// 停止监视当前目录：关闭全部文件，清掉文件头缓存。跟踪过的名单保留。
    fn detach(&mut self) {
        self.files.clear();
        self.headers.clear();
        self.directory = None;
    }

    /// 重新列目录并扫描。目录不见了时立即重新查找，被拒绝时转入重查。
    fn rescan(&mut self, now: f64, out: &mut Vec<GameLogMessage>) {
        let Some(directory) = self.directory.clone() else {
            return;
        };
        match list(Path::new(&directory)) {
            Listing::Entries(entries) => self.scan(&entries, now, out),
            Listing::Denied => {
                self.detach();
                self.enter_retry(CombatLogStatus::AccessDenied(directory), now, out);
            }
            Listing::Missing => {
                self.detach();
                self.resolve(now, out);
            }
        }
    }

    // MARK: 扫描

    /// 按目录条目决定跟踪哪些文件。
    fn scan(&mut self, entries: &[Entry], now: f64, out: &mut Vec<GameLogMessage>) {
        let Some(directory) = self.directory.clone() else {
            return;
        };
        let mut candidates = Vec::new();
        let mut created = HashMap::new();
        let mut pending = false;
        let mut present = HashSet::new();
        for entry in entries.iter().filter(|e| is_log_file_name(&e.name)) {
            present.insert(entry.name.clone());
            if !is_recent(entry.modified_at, now) {
                continue;
            }
            if !self.headers.contains_key(&entry.name) {
                match probe_header(&path(&directory, &entry.name)) {
                    HeaderProbe::Complete { listener, encoding } => {
                        self.headers
                            .insert(entry.name.clone(), CachedHeader { listener, encoding });
                    }
                    HeaderProbe::Incomplete => pending = true,
                    HeaderProbe::Unreadable => {}
                }
            }
            if let Some(listener) = self.headers.get(&entry.name).and_then(|h| h.listener.clone()) {
                candidates.push(Candidate {
                    name: entry.name.clone(),
                    listener,
                });
                created.insert(entry.name.clone(), entry.created_at);
            }
        }
        // 已不在目录里的文件不再缓存，缓存的大小随目录变化而不是一直增长。
        self.headers.retain(|name, _| present.contains(name));
        self.ever_followed.retain(|name| present.contains(name));
        let selected = select_followed(&candidates, MAX_FOLLOWED_FILES);
        self.files.retain(|name, _| selected.contains(name));
        for name in &selected {
            if !self.files.contains_key(name) {
                self.follow(&directory, name, created.get(name).copied().flatten(), now);
            }
        }
        self.next_rescan = now
            + if pending {
                PENDING_RESCAN_INTERVAL
            } else {
                RESCAN_INTERVAL
            };
        let followed_files = self.files.len();
        self.set_status(
            CombatLogStatus::Watching {
                directory,
                followed_files,
            },
            out,
        );
    }

    /// 开始跟踪一个文件。只有第一次跟踪、且是启动后新建的文件才从头读起。
    fn follow(&mut self, directory: &str, name: &str, created_at: Option<f64>, now: f64) {
        let Some(header) = self.headers.get(name) else {
            return;
        };
        let Some(listener) = header.listener.clone() else {
            return;
        };
        let start_at_end = self.ever_followed.contains(name) || starts_at_end(created_at, self.started_at);
        if let Some(file) = TailedFile::open(
            &path(directory, name),
            listener,
            start_at_end,
            header.encoding,
            now,
        ) {
            self.files.insert(name.to_owned(), file);
            self.ever_followed.insert(name.to_owned());
        }
    }

    // MARK: 读取

    /// 读每个文件的新内容，按每次读取合并成事件；一步里的全部事件放进一条消息。
    fn read_all(&mut self, out: &mut Vec<GameLogMessage>) {
        let mut events: Vec<CombatLogEvent> = Vec::new();
        for file in self.files.values_mut() {
            loop {
                let (lines, more) = file.read_new_lines();
                let kinds: Vec<_> = lines
                    .iter()
                    .filter_map(|line| parser::parse(line))
                    .map(|line| line.kind)
                    .collect();
                events.extend(rules::events(&file.listener, &kinds));
                if !more {
                    break;
                }
            }
        }
        if !events.is_empty() {
            out.push(GameLogMessage::Events(events));
        }
    }

    /// 状态变了时发消息。
    fn set_status(&mut self, status: CombatLogStatus, out: &mut Vec<GameLogMessage>) {
        if status != self.status {
            self.status = status.clone();
            out.push(GameLogMessage::Status(status));
        }
    }
}

/// 目录下的文件路径。
fn path(directory: &str, name: &str) -> PathBuf {
    Path::new(directory).join(name)
}
