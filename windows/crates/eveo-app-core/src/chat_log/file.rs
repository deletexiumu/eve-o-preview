// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志与游戏日志的只读操作，对应 macOS 的 FollowedLogFile.swift 与 LogTailReader.swift（设计文档 5.4 节、5.6 节）。
// - FollowedFile：跟踪服务里的一个文件，持有自己的句柄、已读偏移量与分行器。聊天日志与游戏日志共用，用 Role 区分。
// - 一次性读取：探测聊天日志的文件头、回头找位置线索（Local 的最后一条系统消息、游戏日志最后 20 条 (None) 行）。
// 约定：
// - 聊天日志是带 BOM 的 UTF-16 小端。起点与每次读取的终点都取偶数，偏移量永远是偶数；起点落在奇数字节上时
//   之后的每个字符都会错位。起点在文件中间时用指定了编码的分行器，并丢掉读到的第一行（可能是半行）。
// - 文件长度小于已读偏移量时视为被截断：偏移量改成 0，分行器重置。
// - 长度取自打开的句柄：Windows 上目录项里的长度对正在写的文件会滞后。
// - 只读：std::fs 打开时允许别人同时读、写、删除，不改、不删 EVE 目录下的任何内容。

use std::fs::File;
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::path::Path;

use eveo_core::chat_log::directory::{aligned_offset, backfill_start};
use eveo_core::chat_log::{ChatChannelKind, ChatLine, ChatLogHeader, location, parser};
use eveo_core::combat_log::directory::read_start;
use eveo_core::combat_log::framer::{LogLineFramer, LogTextEncoding};

/// 每次读取的块大小：64 KiB（偶数）。
const CHUNK_SIZE: usize = 65_536;
/// 一次读取至多读这么多字节：1 MiB（偶数）。还有剩余时调用方接着再读。
pub(super) const MAX_BYTES_PER_READ: u64 = 1_048_576;
/// 探测聊天日志文件头时至多读的字节数。
pub(super) const HEADER_PROBE_BYTES: u64 = 4_096;
/// 回头找 Local 系统消息时读文件末尾的字节数：4 MiB。
pub(super) const LOCAL_LOOKBACK_BYTES: u64 = 4_194_304;
/// 末尾没有系统消息时改读文件开头的字节数。
pub(super) const LOCAL_HEAD_BYTES: u64 = 8_192;
/// 回头找游戏日志 (None) 行时读文件末尾的字节数：2 MiB。
pub(super) const GAME_LOOKBACK_BYTES: u64 = 2_097_152;
/// 游戏日志的回读至多给出的线索条数。
pub(super) const GAME_LOOKBACK_LIMIT: usize = 20;

/// 聊天日志文件头的探测结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ChatHeaderProbe {
    /// 文件头完整（读满 4,096 字节仍没有第二条分隔线时也算完整，各字段为 `None`）。
    Complete(ChatLogHeader),
    /// 文件头还没写完（文件刚建出来），稍后重读。
    Incomplete,
    /// 打不开或读不了。
    Unreadable,
}

/// 被跟踪文件的角色。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Role {
    /// 聊天日志：文件头、频道种类，以及它是否与请求里的某个频道匹配（只为位置线索跟踪的 Local 文件为假）。
    Chat {
        /// 文件头。
        header: ChatLogHeader,
        /// 频道种类。
        kind: ChatChannelKind,
        /// 频道是否在请求里。
        requested: bool,
    },
    /// 游戏日志：只取类别是 None 的行作位置线索。
    Game,
}

/// 被跟踪的一个日志文件。只在跟踪服务的后台线程上使用。
#[derive(Debug)]
pub(super) struct FollowedFile {
    /// 文件名（不含目录）。
    pub name: String,
    /// 文件头里的收听者。
    pub listener: String,
    /// 文件的角色。
    pub role: Role,
    /// 打开的句柄。
    file: File,
    /// 文件的编码；从文件中间读起时用它建分行器。
    encoding: LogTextEncoding,
    /// 已读到的字节偏移量。
    offset: u64,
    /// 分行器。
    framer: LogLineFramer,
    /// 下一次切出的第一行要丢掉（起点在文件中间）。
    drops_first_line: bool,
    /// 读取用的缓冲，跨读取复用。
    buffer: Vec<u8>,
}

impl FollowedFile {
    /// 打开文件，偏移量停在 0；之后由 [`Self::seek`] 定起点。打不开时返回 `None`。
    pub fn open(
        path: &Path,
        name: &str,
        listener: &str,
        role: Role,
        encoding: LogTextEncoding,
    ) -> Option<Self> {
        Some(Self {
            name: name.to_owned(),
            listener: listener.to_owned(),
            role,
            file: File::open(path).ok()?,
            encoding,
            offset: 0,
            framer: LogLineFramer::default(),
            drops_first_line: false,
            buffer: vec![0; CHUNK_SIZE],
        })
    }

    /// 是否按 UTF-16 读（偏移量取偶数）。
    fn is_utf16(&self) -> bool {
        self.encoding != LogTextEncoding::Utf8
    }

    /// 打开的句柄（一次性读取用）。
    pub fn handle(&self) -> &File {
        &self.file
    }

    /// 文件的编码。
    pub fn encoding(&self) -> LogTextEncoding {
        self.encoding
    }

    /// 当前的文件长度；UTF-16 的文件取偶数。读不到时返回 `None`。
    pub fn current_size(&self) -> Option<u64> {
        let size = self.file.metadata().ok()?.len();
        Some(if self.is_utf16() {
            aligned_offset(size)
        } else {
            size
        })
    }

    /// 定起点并重建分行器。0 表示从头读（按 BOM 判断编码）；其余用文件的编码从中间读。
    ///
    /// `drops_first_line` 为真时丢掉读到的第一行：补读的起点可能落在一行中间，应为真；
    /// 从文件末尾读起时末尾是行的边界（EVE 整行写入），应为假，否则会丢掉之后的第一条消息。
    pub fn seek(&mut self, start: u64, drops_first_line: bool) {
        let aligned = if self.is_utf16() {
            aligned_offset(start)
        } else {
            start
        };
        self.offset = aligned;
        self.framer = if aligned == 0 {
            LogLineFramer::default()
        } else {
            LogLineFramer::with_encoding(self.encoding)
        };
        self.drops_first_line = aligned > 0 && drops_first_line;
    }

    /// 读到 `limit`（不含）或当前末尾为止的新内容，切成完整的行，一次至多 1 MiB。
    /// 返回这次的行，以及到 `limit` 或末尾前是否还有没读的内容。
    ///
    /// 最后一行没有换行符时留在分行器里，下一次读取凑齐。读取出错或意外读到 0 字节时「还有」为假，
    /// 由下一轮轮询重试，不会在这里死循环。
    pub fn read_lines(&mut self, limit: Option<u64>) -> (Vec<String>, bool) {
        let Some(size) = self.current_size() else {
            return (Vec::new(), false);
        };
        let (start, truncated) = read_start(self.offset, size);
        if truncated {
            self.offset = start;
            self.framer = LogLineFramer::default();
            self.drops_first_line = false;
        }
        let stop = limit.map_or(size, |limit| limit.min(size));
        let end = stop.min(self.offset + MAX_BYTES_PER_READ);
        let mut lines = Vec::new();
        let mut failed = false;
        while self.offset < end {
            let want = (CHUNK_SIZE as u64).min(end - self.offset) as usize;
            match read_at(&self.file, self.offset, &mut self.buffer[..want]) {
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                // 出错，或长度说有内容却读到 0 字节（在取长度与读之间被截断）：交给下一轮。
                Err(_) | Ok(0) => {
                    failed = true;
                    break;
                }
                Ok(count) => {
                    self.offset += count as u64;
                    lines.extend(self.framer.append(&self.buffer[..count]));
                }
            }
        }
        if self.drops_first_line && !lines.is_empty() {
            lines.remove(0);
            self.drops_first_line = false;
        }
        (lines, !failed && self.offset < stop)
    }
}

/// 从 `offset` 读一块。`&File` 自己实现了 Seek 与 Read，读取不需要可变借用整个文件。
fn read_at(mut file: &File, offset: u64, buffer: &mut [u8]) -> std::io::Result<usize> {
    file.seek(SeekFrom::Start(offset))?;
    file.read(buffer)
}

/// 读 [from, to) 的字节；出错或提前读到文件末尾时返回已读到的部分。
fn read_range(file: &File, from: u64, to: u64) -> Vec<u8> {
    let mut data = vec![0; to.saturating_sub(from) as usize];
    let mut done = 0;
    while done < data.len() {
        match read_at(file, from + done as u64, &mut data[done..]) {
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) | Ok(0) => break,
            Ok(count) => done += count,
        }
    }
    data.truncate(done);
    data
}

/// 读 [from, to) 并切成完整的行，最后一行没有换行符时也算一行（一次性读取，不留半行给之后）。
///
/// `from` 为 0 时由分行器按 BOM 判断编码；否则用 `encoding` 建分行器，并丢掉第一行（可能是半行）。
pub(super) fn lines(file: &File, from: u64, to: u64, encoding: LogTextEncoding) -> Vec<String> {
    let mut framer = if from == 0 {
        LogLineFramer::default()
    } else {
        LogLineFramer::with_encoding(encoding)
    };
    let mut result = framer.append(&read_range(file, from, to));
    // 补一个换行，让最后一行也被切出来。
    let newline: &[u8] = match framer.encoding().unwrap_or(encoding) {
        LogTextEncoding::Utf8 => b"\n",
        LogTextEncoding::Utf16LittleEndian => b"\n\0",
        LogTextEncoding::Utf16BigEndian => b"\0\n",
    };
    result.extend(framer.append(newline));
    if from > 0 && !result.is_empty() {
        result.remove(0);
    }
    result
}

/// 读文件开头至多 4,096 字节，取聊天日志的文件头（5.4 节扫描规则第 2 条）。
pub(super) fn probe_chat_header(path: &Path) -> ChatHeaderProbe {
    let Ok(file) = File::open(path) else {
        return ChatHeaderProbe::Unreadable;
    };
    let mut bytes = Vec::new();
    if file.take(HEADER_PROBE_BYTES).read_to_end(&mut bytes).is_err() {
        return ChatHeaderProbe::Unreadable;
    }
    let header = parser::parse_header(&LogLineFramer::default().append(&bytes));
    if header.is_complete {
        return ChatHeaderProbe::Complete(header);
    }
    // 读满了仍没有第二条分隔线：文件头不是预期的形式，按「完整、没有字段」处理，之后被忽略。
    if bytes.len() as u64 >= HEADER_PROBE_BYTES {
        return ChatHeaderProbe::Complete(ChatLogHeader {
            channel_id: None,
            channel_name: None,
            listener: None,
            is_complete: true,
        });
    }
    ChatHeaderProbe::Incomplete
}

/// Local 文件里最近的一条系统消息（5.6 节来源一）。
///
/// 读末尾至多 4 MiB，取最后一条系统消息；没有时改读开头的 8,192 字节，取第一条（会话开始时写入的那一条）。
/// 不按补读的秒数过滤：Local 文件常常只有会话开始时的一行，按时间过滤会把它丢掉。
/// `end` 是已经取成偶数的文件长度。都没有时返回 `None`。
pub(super) fn last_local_system_line(file: &File, end: u64) -> Option<ChatLine> {
    let start = backfill_start(end, LOCAL_LOOKBACK_BYTES);
    let utf16 = LogTextEncoding::Utf16LittleEndian;
    let tail = lines(file, start, end, utf16);
    // 从后往前找，最后一条系统消息就是最近的那条。
    if let Some(last) = tail
        .iter()
        .rev()
        .filter_map(|line| parser::parse_line(line))
        .find(|line| line.is_system)
    {
        return Some(last);
    }
    if start == 0 {
        return None;
    }
    let head = lines(file, 0, aligned_offset(end.min(LOCAL_HEAD_BYTES)), utf16);
    head.iter()
        .filter_map(|line| parser::parse_line(line))
        .find(|line| line.is_system)
}

/// 游戏日志末尾至多 2 MiB 里类别是 None 的行，至多最后 20 条，按先后顺序（5.6 节来源二）。
pub(super) fn last_game_notes(file: &File, end: u64, encoding: LogTextEncoding) -> Vec<(f64, String)> {
    let mut start = end.saturating_sub(GAME_LOOKBACK_BYTES);
    // 游戏日志多是 UTF-8；万一是 UTF-16，起点同样取偶数。
    if encoding != LogTextEncoding::Utf8 {
        start = aligned_offset(start);
    }
    let notes: Vec<_> = lines(file, start, end, encoding)
        .iter()
        .filter_map(|line| location::game_note(line))
        .collect();
    let skip = notes.len().saturating_sub(GAME_LOOKBACK_LIMIT);
    notes.into_iter().skip(skip).collect()
}
