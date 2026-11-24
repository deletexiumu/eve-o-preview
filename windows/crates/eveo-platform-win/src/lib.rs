// SPDX-License-Identifier: GPL-3.0-or-later
//
// Windows 平台层，对应 macOS 的 EVEOPreviewPlatform（docs/windows/architecture.md 第 4 节）。
// 每个模块只包一类系统接口，判断规则都交给 eveo-core；这里只负责调用与把结果换成 Core 的值类型。
// 整个 crate 只在 Windows 上编译出内容，其他系统上是空壳，工作区的 `cargo check --workspace` 照样能过。
//
// unsafe 的约定：每个 unsafe 块前写 `// SAFETY:` 说明前提。常见的前提有三类：
// 传入的缓冲区在调用期间有效且长度如实给出；句柄来自同一模块、尚未释放；回调只在注册它的线程上运行。

//! EVE-O Preview 的 Windows 平台层。

#![cfg(windows)]

pub mod activation;
pub mod appearance;
pub mod discovery;
pub mod esi;
pub mod events;
pub mod hotkey;
pub mod http;
pub mod known_folders;
pub mod menu;
pub mod message_loop;
pub mod mouse_hook;
pub mod overlay;
pub mod process;
pub mod recorder;
pub mod screens;
pub mod screenshot;
pub mod single_instance;
mod text;
pub mod thumbnail;
pub mod tray;
mod window_class;

use eveo_core::model::WindowId;
use windows::Win32::Foundation::HWND;

/// Core 的窗口编号 → 窗口句柄。编号就是句柄的数值。
pub fn hwnd(id: WindowId) -> HWND {
    HWND(id.0 as usize as *mut core::ffi::c_void)
}

/// 窗口句柄 → Core 的窗口编号。
pub fn window_id(hwnd: HWND) -> WindowId {
    WindowId(hwnd.0 as usize as u64)
}
