// SPDX-License-Identifier: GPL-3.0-or-later
//
// Windows 版的应用层逻辑（架构文档 3.1 节、3.3 节）：
// - coordinator：协调器。对应 macOS 的 AppCoordinator，事件进、效果出，自己不碰任何系统接口。
// - config_store：config.json 的读写，对应 macOS 的 JSONFileConfigStore。
// - paths：%APPDATA% 与 %LOCALAPPDATA% 下的数据位置（架构文档 4.10 节）。
// 这个 crate 不依赖 windows crate，在 Linux 上用事件序列做单元测试；Win32 的执行者在可执行文件里。

//! EVE-O Preview Windows 版的协调器、配置存储与数据位置。

pub mod config_store;
pub mod coordinator;
pub mod event;
pub mod gesture;
pub mod paths;

pub use coordinator::Coordinator;
pub use event::{
    ContextMenuAction, ContextMenuModel, DragContext, Effect, Event, ForegroundOwner, SettingsPage,
    TrayAction, TrayModel,
};
