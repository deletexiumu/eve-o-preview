// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名缓存文件，对应 macOS 的 FilePilotNameCacheStore.swift（设计文档 6.10 节）。
// 位置：%LOCALAPPDATA%\EVE-O Preview\cache\pilot-names.json（paths::DataPaths::cache_dir）。macOS 放在
// Application Support；Windows 把可以重建的数据放在本机目录，漫游配置不必带着它走。
// 内容是 `{"format": 1, "entries": [...]}`，每项有 key、characterID、name、time，只存查到的角色。
// 原子写入：先在同一目录写临时文件并刷到磁盘，再改名替换（Windows 上 rename 会替换已有文件）。
// LOCALAPPDATA 的默认权限只有本用户与系统，所以不另设 ACL（macOS 用 0600）。
// 读不了、格式版本不对或结构不符时从空缓存开始：缓存丢了只是多查几次，不影响使用。
// 文件里有其他玩家的角色名与角色 ID（游戏的公开数据），只留在本机，不进问题报告。

//! `pilot-names.json` 的读写。

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use eveo_core::intel::pilots::PilotNameCacheEntry;
use serde::{Deserialize, Serialize};

/// 文件名。
pub const FILE_NAME: &str = "pilot-names.json";
/// 文件的格式版本。与 macOS 相同，两边的文件可以互相读（虽然通常不会拷来拷去）。
pub const FORMAT: i64 = 1;

/// 临时文件名里的序号：同一进程里连续两次写入不会撞名。
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// 文件的结构。
#[derive(Serialize, Deserialize)]
struct File {
    /// 格式版本。
    format: i64,
    /// 条目。
    entries: Vec<PilotNameCacheEntry>,
}

/// 存在文件里的人名缓存。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PilotNameStore {
    /// 缓存文件的位置。
    path: PathBuf,
}

impl PilotNameStore {
    /// 用缓存文件的位置建存储。
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// 放在缓存目录下的默认文件名。
    pub fn in_dir(cache_dir: &Path) -> Self {
        Self::new(cache_dir.join(FILE_NAME))
    }

    /// 缓存文件的位置。
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 读全部条目。文件不存在、读不了、格式版本不对或结构不符时返回空数组。
    pub fn load(&self) -> Vec<PilotNameCacheEntry> {
        let Ok(text) = fs::read_to_string(&self.path) else {
            return Vec::new();
        };
        match serde_json::from_str::<File>(&text) {
            Ok(file) if file.format == FORMAT => file.entries,
            _ => Vec::new(),
        }
    }

    /// 写全部条目：同目录的临时文件写好并刷盘后改名替换。目录不存在时创建。
    pub fn save(&self, entries: &[PilotNameCacheEntry]) -> io::Result<()> {
        let file = File {
            format: FORMAT,
            entries: entries.to_vec(),
        };
        let text = serde_json::to_string(&file).map_err(io::Error::other)?;
        let directory = self.path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(directory)?;
        let serial = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let temp = directory.join(format!(".pilot-names-{}-{serial}.tmp", std::process::id()));
        let result = (|| {
            let mut handle = fs::File::create(&temp)?;
            handle.write_all(text.as_bytes())?;
            handle.sync_all()?;
            // 先关掉句柄再改名：Windows 上打开着的文件不能被改名替换。
            drop(handle);
            fs::rename(&temp, &self.path)
        })();
        // 失败时删掉临时文件，原文件保持不变。
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }
}
