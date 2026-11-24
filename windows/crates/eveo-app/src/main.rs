// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVE-O Preview Windows 版的入口。用 windows 子系统，不开控制台窗口：调试版也会交给测试的人在游戏旁边运行，
// 弹出的控制台会盖住游戏画面（真机测试发现）。应用本身不往控制台输出，诊断日志随后写到 %LOCALAPPDATA% 的 logs 目录。
// 真正的内容在 app 模块，只在 Windows 上编译。

//! EVE-O Preview for Windows。

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod hotkeys;
#[cfg(windows)]
mod menus;
// 浮窗的管理；接到协调器与菜单在下一步（M6n），在那之前部分接口还没有调用方。
#[cfg(windows)]
#[allow(dead_code)]
mod overlays;
#[cfg(windows)]
mod slint_platform;
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
