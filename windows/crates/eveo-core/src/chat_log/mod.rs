// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的纯逻辑，逐项对应 macOS 的 EVEOPreviewCore/ChatLog（docs/macos/design-intel-translate.md 5.2～5.6 节）：
// - parser：文件头（Channel ID、Channel Name、Listener）与消息行「[ 时间 ] 说话人 > 正文」，频道种类，正文清理。
// - directory：Chatlogs 目录的候选（Windows 路径）、文件名「频道_日期_时间_数字.txt」、每个（收听者，频道）取最新、
//   UTF-16 的偶数偏移。
// - coverage：活动角色在所选频道里有没有被跟踪的日志文件（浮窗据此说明「EVE 没写这个频道的日志」）。
// - location：位置线索的句式，从 Local 的系统消息与游戏日志的 (None) 行里取星系名的原文。
// - request：跟踪请求（目录、频道、是否读位置线索、补读的秒数），以及什么时候要重建跟踪服务。
// 这里只有值类型与规则；读目录与文件的跟踪服务在 eveo-app-core。
// 时间都是 UTC，1970 年以来的秒数；聊天日志里的时间就是 UTC（EVE 时间）。

//! 聊天日志的解析、目录与文件取舍、覆盖情况、位置线索与跟踪请求。

pub mod coverage;
pub mod directory;
pub mod location;
pub mod parser;
pub mod request;

#[cfg(test)]
mod tests;

use crate::model::ChannelRef;

/// 聊天频道的种类，由文件头的 Channel ID 决定（[`parser::channel_kind`]）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChatChannelKind {
    /// 本地频道，ID 是 `local`。
    Local,
    /// 军团频道，ID 是 `corp`。
    Corp,
    /// 联盟频道，ID 是 `alliance`。
    Alliance,
    /// 舰队频道，ID 以 `fleet_` 开头。
    Fleet,
    /// 玩家建的频道，ID 以 `player_` 开头。
    Player,
    /// 私聊，ID 以 `private_` 开头。不跟踪，也不列出。
    PrivateChat,
    /// 其他 ID，或没有 ID。
    Other,
}

/// 聊天日志文件头的解析结果（[`parser::parse_header`]）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatLogHeader {
    /// 文件头的 Channel ID；没有这一行时为 `None`。
    pub channel_id: Option<String>,
    /// 文件头的 Channel Name。
    pub channel_name: Option<String>,
    /// 文件头的收听者（角色名）。
    pub listener: Option<String>,
    /// 是否已读完文件头；`false` 表示还没读到第二条分隔线（文件刚建出来）。
    pub is_complete: bool,
}

impl ChatLogHeader {
    /// 按 Channel ID 判断的频道种类。
    pub fn kind(&self) -> ChatChannelKind {
        parser::channel_kind(self.channel_id.as_deref())
    }
}

/// 解析出的一行消息（[`parser::parse_line`]）。
#[derive(Debug, Clone, PartialEq)]
pub struct ChatLine {
    /// 日志里的时间，UTC，1970 年以来的秒数。
    pub time: f64,
    /// 说话人，已去掉首尾空白。
    pub speaker: String,
    /// 正文，已经过 [`parser::plain_text`] 清理。
    pub text: String,
    /// 说话人是 EVE 系统（在 [`parser::SYSTEM_SPEAKERS`] 里）。
    pub is_system: bool,
}

/// 跟踪服务上报的一条消息：一行消息加上它所在文件的收听者与频道。
#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    /// 文件头的收听者。浮窗只显示活动角色的消息。
    pub listener: String,
    /// 文件头的 Channel ID。
    pub channel_id: String,
    /// 文件头的 Channel Name。
    pub channel_name: String,
    /// 日志里的时间，UTC。
    pub time: f64,
    /// 说话人。
    pub speaker: String,
    /// 正文。
    pub text: String,
    /// 是否为启动时从已有内容里补读的消息。
    pub is_backfill: bool,
}

/// 位置线索的来源（5.6 节）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LocationHintSource {
    /// `Local` 聊天日志的系统消息。
    LocalChannel,
    /// 游戏日志里类别是 None 的行（跳跃与离站）。
    GameLog,
}

/// 一条位置线索：日志里能说明角色所在星系的一行，只带原文，不查星图数据。
#[derive(Debug, Clone, PartialEq)]
pub struct LocationHint {
    /// 角色名（文件头的收听者）。
    pub character: String,
    /// 日志里的时间，UTC。
    pub time: f64,
    /// 来源。
    pub source: LocationHintSource,
    /// `Local` 的系统消息正文，或游戏日志 (None) 行的正文（已去掉标记）。
    pub text: String,
    /// 是否为启动时回读到的线索。
    pub is_backfill: bool,
}

/// 跟踪服务上报的事件。
#[derive(Debug, Clone, PartialEq)]
pub enum ChatLogEvent {
    /// 一条非系统消息。
    Message(ChatMessage),
    /// 一条位置线索。
    LocationHint(LocationHint),
}

/// 聊天日志跟踪服务的状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatLogStatus {
    /// 没有在跟踪（两个功能都关着）。
    Stopped,
    /// 正在跟踪：目录与跟踪的文件数。
    Watching {
        /// 正在监视的 Chatlogs 目录。
        directory: String,
        /// 正在跟踪的文件数。
        followed_files: usize,
    },
    /// 候选目录都不存在，关联值是第一个候选目录。
    DirectoryNotFound(String),
    /// 没有读取权限。
    AccessDenied(String),
}

/// 日志目录里发现的一个频道，给设置界面的「从日志添加」用（5.3 节）。
#[derive(Debug, Clone, PartialEq)]
pub struct DiscoveredChannel {
    /// Channel ID。
    pub id: String,
    /// Channel Name。
    pub name: String,
    /// 频道种类。
    pub kind: ChatChannelKind,
    /// 有几个角色的日志里出现过。
    pub listeners: usize,
    /// 最近一个文件的修改时间，1970 年以来的秒数。
    pub last_modified: f64,
}

impl DiscoveredChannel {
    /// 写进配置用的频道：名字与 ID 都存。
    pub fn channel_ref(&self) -> ChannelRef {
        ChannelRef::new(&self.name, Some(&self.id))
    }
}
