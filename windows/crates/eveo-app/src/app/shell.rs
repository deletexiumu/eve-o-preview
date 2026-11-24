// SPDX-License-Identifier: GPL-3.0-or-later
//
// 交给系统的两件事：显示一个文件或文件夹（启动 explorer.exe，不等它结束）、用默认浏览器打开链接
// （ShellExecuteW 的 open 动作）。启动失败（极少见）不影响设置窗口，只在打开链接失败时记一行日志。
// 链接不能交给 explorer.exe：地址超过约 2000 个字符时它不开浏览器，反而打开「文档」文件夹（真机上见过）。

//! 资源管理器与默认浏览器。

use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::Command;

use eveo_app_core::log::Logger;

/// 日志的类别。
const LOG: Logger = Logger::new("Shell");

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
    // 地址里可能有名字（问题报告的正文已脱敏，但仍不写进日志），失败时只记长度。
    if url.starts_with("https://") && !eveo_platform_win::shell::open_url(url) {
        LOG.error(format_args!("打开链接失败（地址 {} 字节）", url.len()));
    }
}
