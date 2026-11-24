// SPDX-License-Identifier: GPL-3.0-or-later
//
// 小文件的原子写入：先在同一目录写临时文件并刷到磁盘，再改名替换。写到一半断电或进程被结束时，
// 原文件保持不变，不会留下半个文件。人名缓存、译文缓存与 state.json 共用。
// 临时文件名带前缀、进程号与序号：两个实例、或同一进程里连续两次写入都不会撞名。
// 临时文件放在同一目录，保证改名不跨卷；Windows 上 rename 是 MoveFileExW 带 MOVEFILE_REPLACE_EXISTING，
// 目标存在时直接替换。

//! 原子写入小文件。

use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

/// 临时文件名里的序号。
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// 把 bytes 原子地写到 path；目录不存在时创建。prefix 只用在临时文件名里，便于认出是谁留下的。
pub(crate) fn write_atomic(path: &Path, bytes: &[u8], prefix: &str) -> io::Result<()> {
    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(directory)?;
    let serial = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let temp = directory.join(format!(".{prefix}-{}-{serial}.tmp", std::process::id()));
    let result = (|| {
        let mut handle = fs::File::create(&temp)?;
        handle.write_all(bytes)?;
        handle.sync_all()?;
        // 先关掉句柄再改名：Windows 上打开着的文件不能被改名替换。
        drop(handle);
        fs::rename(&temp, path)
    })();
    // 失败时删掉临时文件，原文件保持不变。
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
