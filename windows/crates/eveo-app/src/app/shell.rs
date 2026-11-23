// SPDX-License-Identifier: GPL-3.0-or-later
//
// 交给资源管理器的两件事：显示一个文件或文件夹、用默认浏览器打开链接。都是启动 explorer.exe，不等它结束；
// 启动失败（极少见）不影响设置窗口，忽略。

//! 资源管理器与默认浏览器。

use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::Command;

/// 在资源管理器里显示一个位置：文件则打开所在文件夹并选中它，文件夹则打开它；
/// 都不存在时（例如还没写过配置或日志）打开最近的存在的上一级文件夹，一直找不到就什么都不做。
pub(super) fn reveal(path: &Path) {
    // 资源管理器总在系统路径上，不必写全路径。
    let mut command = Command::new("explorer.exe");
    if path.is_file() {
        // explorer 自己解析参数：路径含空格（「EVE-O Preview」）时要在 /select, 之后加引号，
        // 整个参数加引号它不认，所以用 raw_arg 原样传。
        command.raw_arg(format!("/select,\"{}\"", path.display()));
    } else if let Some(dir) = path.ancestors().find(|dir| dir.is_dir()) {
        // 最近的存在的文件夹：path 本身是文件夹时就是它。
        command.arg(dir);
    } else {
        return;
    }
    let _ = command.spawn();
}

/// 用默认浏览器打开一个链接。调用方负责核对地址（只打开固定的几个），这里只拒绝不是 https 的。
pub(super) fn open_url(url: &str) {
    if url.starts_with("https://") {
        let _ = Command::new("explorer.exe").arg(url).spawn();
    }
}
