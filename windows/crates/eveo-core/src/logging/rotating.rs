// SPDX-License-Identifier: GPL-3.0-or-later
//
// 带轮转的日志文件，对应 macOS 的 LogFileLayout.swift 与 RotatingLogFile.swift（docs/macos/design-v1.1.md 5.2 节）：
// - 位置：%LOCALAPPDATA%\EVE-O Preview\logs\eve-o-preview.log（当前），eve-o-preview.1.log～.4.log（旧，1 最新）。
//   目录由调用方给（paths::DataPaths::logs_dir）；不存在时创建。
// - 单个文件上限 1,048,576 字节，保留 4 个旧文件，合计约 5 MiB。
// - 每次追加直接写进文件，不经过用户态缓冲：崩溃前最后一行已经交给了系统。不刷盘（不调 FlushFileBuffers）。
// - 以追加方式打开，两个实例同时写同一个文件时各行不会互相覆盖。
// - 轮转只看大小，不在启动时轮转，所以崩溃那次运行的日志仍在当前文件或 .1 里。
//   条件：追加前当前文件不空，且「当前大小 + 这一行」超过上限。做法：关闭当前文件，删掉最旧的 .N，
//   .N-1～.1 依次改名为后一个序号，当前文件改名为 .1，再建新文件。一行就超过上限时仍写进空文件。
// Windows 上另一个进程开着文件时改名会失败；那时轮转报错，调用方按写入失败处理（连续 3 次后停写）。

//! 带轮转的日志文件。

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// 文件的位置与命名。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogFileLayout {
    /// 目录。
    pub directory: PathBuf,
    /// 文件名的主干，默认 `eve-o-preview`。
    pub base_name: String,
}

impl LogFileLayout {
    /// 默认的主干。
    pub const DEFAULT_BASE_NAME: &'static str = "eve-o-preview";

    /// 用目录与默认主干建布局。
    pub fn in_dir(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
            base_name: Self::DEFAULT_BASE_NAME.to_owned(),
        }
    }

    /// 当前文件：`<主干>.log`。
    pub fn current(&self) -> PathBuf {
        self.directory.join(format!("{}.log", self.base_name))
    }

    /// 第 index 个旧文件：`<主干>.<index>.log`，1 最新。
    pub fn archive(&self, index: usize) -> PathBuf {
        self.directory.join(format!("{}.{index}.log", self.base_name))
    }

    /// 目录里属于本布局的文件，最新的在前（当前文件，然后 .1、.2……）。问题报告附日志时用。
    pub fn existing(&self) -> Vec<PathBuf> {
        let Ok(entries) = fs::read_dir(&self.directory) else {
            return Vec::new();
        };
        let current_name = format!("{}.log", self.base_name);
        let prefix = format!("{}.", self.base_name);
        let mut has_current = false;
        let mut archives: Vec<usize> = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name == current_name {
                has_current = true;
                continue;
            }
            // 旧文件：主干、点、正整数序号、.log；别的文件不管。
            let index = name
                .strip_prefix(&prefix)
                .and_then(|r| r.strip_suffix(".log"))
                .and_then(|r| r.parse::<usize>().ok())
                .filter(|&i| i > 0);
            archives.extend(index);
        }
        archives.sort_unstable();
        has_current
            .then(|| self.current())
            .into_iter()
            .chain(archives.into_iter().map(|i| self.archive(i)))
            .collect()
    }
}

/// 轮转的参数。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LogRotationPolicy {
    /// 单个文件的上限（字节）。
    pub max_file_bytes: u64,
    /// 保留的旧文件个数。
    pub max_archives: usize,
}

impl Default for LogRotationPolicy {
    /// 设计的取值：1 MiB，4 个旧文件。
    fn default() -> Self {
        Self {
            max_file_bytes: 1_048_576,
            max_archives: 4,
        }
    }
}

/// 带轮转的日志文件。不是线程安全的，由调用方串行使用（文件日志在锁内用它）。
#[derive(Debug)]
pub struct RotatingLogFile {
    /// 位置与命名。
    layout: LogFileLayout,
    /// 轮转的参数。
    policy: LogRotationPolicy,
    /// 当前文件；没有打开时为 None，下一次追加时打开。
    file: Option<File>,
    /// 当前文件的字节数：打开时取文件大小，之后按写入累加。
    size: u64,
}

impl RotatingLogFile {
    /// 建文件对象。不碰磁盘，第一次追加时才建目录、打开文件。
    pub fn new(layout: LogFileLayout, policy: LogRotationPolicy) -> Self {
        Self {
            layout,
            policy,
            file: None,
            size: 0,
        }
    }

    /// 位置与命名。
    pub fn layout(&self) -> &LogFileLayout {
        &self.layout
    }

    /// 追加一行。line 不应含换行符，这里在行尾加 `\n`。需要时先轮转。
    /// 失败时文件保持关闭，下一次调用会重新打开。
    pub fn append(&mut self, line: &str) -> io::Result<()> {
        let mut bytes = Vec::with_capacity(line.len() + 1);
        bytes.extend_from_slice(line.as_bytes());
        bytes.push(b'\n');
        self.open_if_needed()?;
        let length = bytes.len() as u64;
        if self.size > 0 && self.size + length > self.policy.max_file_bytes {
            self.rotate()?;
            self.open_if_needed()?;
        }
        let Some(file) = self.file.as_mut() else {
            return Err(io::Error::other("日志文件没有打开"));
        };
        if let Err(error) = file.write_all(&bytes) {
            self.close();
            return Err(error);
        }
        self.size += length;
        Ok(())
    }

    /// 关闭当前文件。之后再追加会重新打开。
    pub fn close(&mut self) {
        self.file = None;
        self.size = 0;
    }

    /// 没有打开时建目录并打开当前文件，读出已有的大小。
    fn open_if_needed(&mut self) -> io::Result<()> {
        if self.file.is_some() {
            return Ok(());
        }
        fs::create_dir_all(&self.layout.directory)?;
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.layout.current())?;
        self.size = file.metadata().map_or(0, |m| m.len());
        self.file = Some(file);
        Ok(())
    }

    /// 轮转：关闭当前文件，删最旧的旧文件，其余旧文件序号加一，当前文件改名为 .1。
    /// 不存在的旧文件跳过；max_archives 为 0 时直接删掉当前文件。
    fn rotate(&mut self) -> io::Result<()> {
        self.close();
        let current = self.layout.current();
        if self.policy.max_archives == 0 {
            return remove_if_exists(&current);
        }
        remove_if_exists(&self.layout.archive(self.policy.max_archives))?;
        for index in (1..self.policy.max_archives).rev() {
            let source = self.layout.archive(index);
            if source.exists() {
                fs::rename(&source, self.layout.archive(index + 1))?;
            }
        }
        fs::rename(&current, self.layout.archive(1))
    }
}

/// 删掉文件；本来就没有时也算成功。
fn remove_if_exists(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用的临时目录，用完删掉。
    struct TempDir(PathBuf);

    impl TempDir {
        /// 新建一个空目录，名字带上用例名与进程号。
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!("eveo-log-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// 写满就轮转，旧文件依次后移，最旧的被删；已有的文件接着写。
    #[test]
    fn rotates_by_size() {
        let dir = TempDir::new("rotate");
        let layout = LogFileLayout::in_dir(&dir.0);
        let policy = LogRotationPolicy {
            max_file_bytes: 10,
            max_archives: 2,
        };
        let mut file = RotatingLogFile::new(layout.clone(), policy);
        // 每行 5 字节（4 个字符加换行），两行正好 10 字节，第三行轮转。
        for line in ["aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff", "gggg"] {
            file.append(line).unwrap();
        }
        let read = |p: PathBuf| fs::read_to_string(p).unwrap();
        assert_eq!(read(layout.current()), "gggg\n");
        assert_eq!(read(layout.archive(1)), "eeee\nffff\n");
        assert_eq!(read(layout.archive(2)), "cccc\ndddd\n");
        assert!(!layout.archive(3).exists(), "最旧的被删掉");
        assert_eq!(
            layout.existing(),
            vec![layout.current(), layout.archive(1), layout.archive(2)]
        );
        // 重新打开后从已有大小接着算：再写一行不超过上限，不轮转。
        let mut again = RotatingLogFile::new(layout.clone(), policy);
        again.append("hhhh").unwrap();
        assert_eq!(read(layout.current()), "gggg\nhhhh\n");
        // 一行就超过上限时仍写进（轮转后的）空文件。
        again.append("a very long line").unwrap();
        assert_eq!(read(layout.current()), "a very long line\n");
    }

    /// 没有旧文件可留时直接删掉当前文件；目录不存在时 existing 为空。
    #[test]
    fn zero_archives_and_missing_directory() {
        let dir = TempDir::new("zero");
        let layout = LogFileLayout::in_dir(dir.0.join("nested"));
        assert!(layout.existing().is_empty());
        let policy = LogRotationPolicy {
            max_file_bytes: 6,
            max_archives: 0,
        };
        let mut file = RotatingLogFile::new(layout.clone(), policy);
        file.append("one").unwrap();
        file.append("two").unwrap();
        file.append("six").unwrap();
        assert_eq!(fs::read_to_string(layout.current()).unwrap(), "six\n");
        assert_eq!(layout.existing(), vec![layout.current()]);
    }
}
