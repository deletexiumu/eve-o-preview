// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存文件，对应 macOS 的 FileTranslationCacheStore（设计文档 7.8 节）。
// 位置：%LOCALAPPDATA%\EVE-O Preview\cache\translation-cache.json（paths::DataPaths::cache_dir）。
// macOS 放在 Application Support；Windows 把可以重建的数据放在本机目录，漫游配置不必带着它走。
// 内容的编码与解码在 eveo-core::translation::cache（`{"format": 1, "entries": [...]}`，与 macOS 相同），
// 这里只负责读写文件。原子写入：先在同一目录写临时文件并刷到磁盘，再改名替换。
// 读不了、格式版本不对或结构不符时从空缓存开始：缓存丢了只是多花几次请求，不影响使用。
// 文件里有聊天原文与译文（没有说话人与频道名），只留在本机，不进问题报告。

//! `translation-cache.json` 的读写。

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use eveo_core::translation::cache::{CacheEntry, decode_file, encode_file};

/// 文件名。
pub const FILE_NAME: &str = "translation-cache.json";

/// 临时文件名里的序号：同一进程里连续两次写入不会撞名。
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// 存在文件里的译文缓存。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranslationCacheStore {
    /// 缓存文件的位置。
    path: PathBuf,
}

impl TranslationCacheStore {
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

    /// 读全部条目（最近用过的在后）。文件不存在、读不了或内容不对时返回空数组。
    pub fn load(&self) -> Vec<CacheEntry> {
        match fs::read(&self.path) {
            Ok(bytes) => decode_file(&bytes),
            Err(_) => Vec::new(),
        }
    }

    /// 写全部条目：同目录的临时文件写好并刷盘后改名替换。目录不存在时创建。
    pub fn save(&self, entries: Vec<CacheEntry>) -> io::Result<()> {
        let bytes = encode_file(entries);
        let directory = self.path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(directory)?;
        // 文件名带进程号与序号：两个实例、或同一进程里的两次写入都不会撞名。
        let serial = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let temp = directory.join(format!(".translation-cache-{}-{serial}.tmp", std::process::id()));
        let result = (|| {
            let mut handle = fs::File::create(&temp)?;
            handle.write_all(&bytes)?;
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
