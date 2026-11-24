// SPDX-License-Identifier: GPL-3.0-or-later
//
// Windows 版的应用层逻辑（架构文档 3.1 节、3.3 节）：
// - coordinator：协调器。对应 macOS 的 AppCoordinator，事件进、效果出，自己不碰任何系统接口。
// - config_store：config.json 的读写，对应 macOS 的 JSONFileConfigStore。
// - paths：%APPDATA% 与 %LOCALAPPDATA% 下的数据位置（架构文档 4.10 节）。
// - gesture：缩略图的鼠标手势状态机；flash：战斗提醒的闪烁曲线。
// - game_log：游戏日志的跟踪服务（后台线程轮询 Gamelogs，只用标准库）。
// - chat_log：聊天日志的跟踪服务（轮询 Chatlogs，位置线索另读 Gamelogs）；poller 是两者共用的轮询线程。
// - chat：预警与翻译的功能控制器（取聊天日志事件，产出浮窗的内容）。
// - pilots：人名核对服务（缓存文件、排队、后台发请求），发请求的函数由可执行文件交进来。
// - translation：翻译功能的控制器（缓冲、后台发请求、译文缓存与 API Key），传输与凭据由可执行文件交进来。
// 这个 crate 不依赖 windows crate，在 Linux 上用事件序列做单元测试；Win32 的执行者在可执行文件里。

//! EVE-O Preview Windows 版的协调器、配置存储与数据位置。

pub mod chat;
pub mod chat_log;
pub mod config_store;
pub mod coordinator;
pub mod event;
pub mod flash;
pub mod game_log;
pub mod gesture;
pub mod paths;
pub mod pilots;
mod poller;
pub mod translation;

pub use coordinator::Coordinator;
pub use event::{
    ContextMenuAction, ContextMenuModel, DragContext, Effect, Event, ForegroundOwner, OverlayMenuAction,
    SettingsPage, TrayAction, TrayModel,
};
