// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志目录与文件的只读操作，对应 macOS 的 TailedLogFile.swift 与 GameLogFileSystem。
// - 只用标准库：Windows 上 std::fs 打开文件时允许别人同时读、写、删除，不妨碍 EVE 写日志与轮换文件。
// - 一个被跟踪的文件持有自己的句柄与已读偏移量；文件变短时视为被截断，从头读起。
// - 从头读起的文件，接入时已有的内容是「积压」：丢掉时间早于接入时刻减容差的行（防重放）。
// - 只读不写：不改、不删 EVE 目录下的任何内容。
// 时间都是 1970 年以来的秒数（墙上时钟），与日志行里的 UTC 时间比较。

use std::fs::{self, File};
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use eveo_core::combat_log::directory::read_start;
use eveo_core::combat_log::framer::{LogLineFramer, LogTextEncoding};
use eveo_core::combat_log::header;
use eveo_core::combat_log::replay::{TOLERANCE, should_keep};

/// 每次读取的块大小：64 KiB。
const CHUNK_SIZE: usize = 65_536;
/// 一次读取至多读这么多字节：1 MiB。还有剩余时调用方接着再读。
pub(super) const MAX_BYTES_PER_READ: u64 = 1_048_576;
/// 读文件头时至多读的字节数。
pub(super) const HEADER_PROBE_BYTES: u64 = 2_048;

/// 目录里的一个普通文件。
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Entry {
    /// 文件名（不含目录）。
    pub name: String,
    /// 修改时间。
    pub modified_at: f64,
    /// 创建时间；文件系统不提供时为 `None`。
    pub created_at: Option<f64>,
}

/// 列目录的结果。
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Listing {
    /// 目录下的普通文件。
    Entries(Vec<Entry>),
    /// 被系统拒绝。
    Denied,
    /// 不存在或不是目录。
    Missing,
}

/// 文件头的探测结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum HeaderProbe {
    /// 文件头完整：收听者（登录界面阶段的文件没有）与分行器判断出的编码。
    Complete {
        /// 收听者。
        listener: Option<String>,
        /// 编码；文件太短判断不出时为 `None`。
        encoding: Option<LogTextEncoding>,
    },
    /// 文件头还没写完（文件刚建出来）。
    Incomplete,
    /// 打不开或读不了。
    Unreadable,
}

/// 系统时间换成 1970 年以来的秒数；早于 1970 年的按 0。
pub(super) fn seconds(time: SystemTime) -> f64 {
    time.duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// 列目录：只要名字是合法 UTF-8 的普通文件。权限错误与「不存在」分开报告。
/// 目录项的时间在 Windows 上来自目录本身（FindNextFile），不必逐个打开文件。
pub(super) fn list(path: &Path) -> Listing {
    let reader = match fs::read_dir(path) {
        Ok(reader) => reader,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => return Listing::Denied,
        Err(_) => return Listing::Missing,
    };
    let mut entries = Vec::new();
    for entry in reader.flatten() {
        let (Ok(name), Ok(meta)) = (entry.file_name().into_string(), entry.metadata()) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let Ok(modified) = meta.modified() else {
            continue;
        };
        entries.push(Entry {
            name,
            modified_at: seconds(modified),
            created_at: meta.created().ok().map(seconds),
        });
    }
    Listing::Entries(entries)
}

/// 读文件开头至多 2,048 字节，取收听者与编码。读满仍不完整时按「完整、没有收听者」处理。
pub(super) fn probe_header(path: &Path) -> HeaderProbe {
    let Ok(file) = File::open(path) else {
        return HeaderProbe::Unreadable;
    };
    let mut bytes = Vec::new();
    if file.take(HEADER_PROBE_BYTES).read_to_end(&mut bytes).is_err() {
        return HeaderProbe::Unreadable;
    }
    let mut framer = LogLineFramer::default();
    let lines = framer.append(&bytes);
    let parsed = header::parse(&lines);
    if parsed.is_complete || bytes.len() as u64 >= HEADER_PROBE_BYTES {
        return HeaderProbe::Complete {
            listener: parsed.listener,
            encoding: framer.encoding(),
        };
    }
    HeaderProbe::Incomplete
}

/// 一个被跟踪的日志文件：句柄、已读偏移量与分行器。
#[derive(Debug)]
pub(super) struct TailedFile {
    /// 文件头里的收听者。
    pub listener: String,
    /// 打开的句柄。
    file: File,
    /// 已读到的字节偏移量。
    offset: u64,
    /// 接入时的文件长度；偏移量到达它之前读到的行是积压。从末尾读起的文件为 0（没有积压）。
    backlog_end: u64,
    /// 接入时刻，积压行的时间比它早过容差时丢弃。
    attached_at: f64,
    /// 分行器。
    framer: LogLineFramer,
    /// 读取用的缓冲，跨读取复用。
    buffer: Vec<u8>,
}

impl TailedFile {
    /// 打开文件。打不开时返回 `None`。
    ///
    /// `start_at_end` 为真时从当前的末尾读起（启动前已有的文件），分行器用文件头探测到的编码，
    /// 不对中间的字节做 BOM 判断；否则从头读起，由分行器按开头的字节判断编码。
    pub fn open(
        path: &Path,
        listener: String,
        start_at_end: bool,
        encoding: Option<LogTextEncoding>,
        attached_at: f64,
    ) -> Option<Self> {
        let file = File::open(path).ok()?;
        let size = file.metadata().ok()?.len();
        let framer = if start_at_end {
            LogLineFramer::with_encoding(encoding.unwrap_or(LogTextEncoding::Utf8))
        } else {
            LogLineFramer::default()
        };
        Some(Self {
            listener,
            file,
            offset: if start_at_end { size } else { 0 },
            backlog_end: if start_at_end { 0 } else { size },
            attached_at,
            framer,
            buffer: vec![0; CHUNK_SIZE],
        })
    }

    /// 读新增的字节并切成完整的行，一次至多 1 MiB。返回凑齐的行，以及文件里是否还有没读的内容。
    ///
    /// 长度取自打开的句柄：Windows 上目录项里的长度对正在写的文件会滞后，句柄上的是准的。
    /// 读取出错或意外读到 0 字节时「还有」为假，由下一轮轮询重试，不会在这里死循环。
    pub fn read_new_lines(&mut self) -> (Vec<String>, bool) {
        let Ok(size) = self.file.metadata().map(|m| m.len()) else {
            return (Vec::new(), false);
        };
        let (start, truncated) = read_start(self.offset, size);
        if truncated {
            self.backlog_end = 0;
            self.framer.reset();
        }
        self.offset = start;
        // 这次读取从积压里开始时，读到的行要过一遍防重放的过滤。
        let reads_backlog = self.offset < self.backlog_end;
        let mut lines = Vec::new();
        let mut total = 0;
        let mut failed = false;
        while self.offset < size && total < MAX_BYTES_PER_READ {
            let want = (CHUNK_SIZE as u64)
                .min(size - self.offset)
                .min(MAX_BYTES_PER_READ - total) as usize;
            if self.file.seek(SeekFrom::Start(self.offset)).is_err() {
                failed = true;
                break;
            }
            match self.file.read(&mut self.buffer[..want]) {
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                // 出错，或长度说有内容却读到 0 字节（在取长度与读之间被截断）：交给下一轮。
                Err(_) | Ok(0) => {
                    failed = true;
                    break;
                }
                Ok(count) => {
                    self.offset += count as u64;
                    total += count as u64;
                    lines.extend(self.framer.append(&self.buffer[..count]));
                }
            }
        }
        if reads_backlog {
            lines.retain(|line| should_keep(line, self.attached_at, TOLERANCE));
        }
        (lines, !failed && self.offset < size)
    }
}
