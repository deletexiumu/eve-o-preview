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
use std::io;
use std::path::{Path, PathBuf};

use eveo_core::translation::cache::{CacheEntry, decode_file, encode_file};

/// 文件名。
pub const FILE_NAME: &str = "translation-cache.json";

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
        crate::atomic_file::write_atomic(&self.path, &bytes, "translation-cache")
    }
}
