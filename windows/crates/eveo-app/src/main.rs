// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVE-O Preview Windows 版的入口。发布版不开控制台窗口（windows 子系统）；调试版保留控制台看输出。
// 真正的内容在 app 模块，只在 Windows 上编译。

//! EVE-O Preview for Windows。

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod hotkeys;
#[cfg(windows)]
mod menus;
#[cfg(windows)]
mod thumbnails;

use std::process::ExitCode;

fn main() -> ExitCode {
    #[cfg(windows)]
    {
        app::run()
    }
    #[cfg(not(windows))]
    {
        eprintln!("EVE-O Preview 的这个版本只能在 Windows 上运行。");
        ExitCode::FAILURE
    }
}
