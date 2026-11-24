// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的跟踪请求，对应 macOS ChatLogModels.swift 里的 ChatLogRequest（设计文档 5.4 节、9.2 节）。
// 功能控制器按预警与翻译的设置拼出请求，交给跟踪服务；请求变了时重建跟踪服务，全部文件重新定起点。
// 只有「补读多少秒」变了时不重建：补读只在启动时用一次。

//! 聊天日志的跟踪请求，以及什么时候要重建跟踪服务。

use std::collections::BTreeSet;

use crate::model::ChannelRef;
use crate::overlay::OverlayKind;

/// 跟踪服务的请求。
#[derive(Debug, Clone, PartialEq)]
pub struct ChatLogRequest {
    /// 配置的日志目录（`general.eveLogDirectory`）；`None` 表示自动查找。
    pub log_directory: Option<String>,
    /// 要跟踪的频道：预警频道与翻译频道的并集。
    pub channels: Vec<ChannelRef>,
    /// 预警开启时为真：另外读 `Local` 与游戏日志里的位置线索。
    pub follows_location: bool,
    /// 启动时补读多少秒以内的消息。
    pub backfill_seconds: f64,
    /// 已打开的功能。跟踪服务不读它，只用来判断请求变没变：功能的开关变了算请求变了。
    pub enabled_features: BTreeSet<OverlayKind>,
}

impl ChatLogRequest {
    /// 文件头里的频道是否与请求的某个频道匹配（[`ChannelRef::matches`]）。
    pub fn is_requested(&self, channel_id: Option<&str>, channel_name: Option<&str>) -> bool {
        self.channels
            .iter()
            .any(|channel| channel.matches(channel_id, channel_name))
    }

    /// 从 `old` 换成 `new` 时要不要重建跟踪服务（并清空两个功能的缓冲）：
    /// 1. 一边是 `None` 另一边不是时要。
    /// 2. 日志目录、频道、是否跟踪位置、已打开的功能有一项不同时要。
    /// 3. 只有 `backfill_seconds` 不同时不要：补读只在启动时用一次，「保留最近」变短时缓冲在刷新时按新的
    ///    时长修剪，变长时不补读更早的消息。
    ///
    /// 已打开的功能要比：翻译的频道全在预警的频道里时，打开翻译只改变 `backfill_seconds`，
    /// 不比的话不会重建、不会补读，翻译浮窗从空白开始。
    pub fn requires_restart(old: Option<&ChatLogRequest>, new: Option<&ChatLogRequest>) -> bool {
        let (Some(old), Some(new)) = (old, new) else {
            return old.is_some() != new.is_some();
        };
        old.log_directory != new.log_directory
            || old.channels != new.channels
            || old.follows_location != new.follows_location
            || old.enabled_features != new.enabled_features
    }
}
