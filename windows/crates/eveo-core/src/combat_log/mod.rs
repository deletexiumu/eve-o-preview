// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志（Gamelogs）与战斗提醒的纯逻辑，逐个对应 macOS 的 EVEOPreviewCore/CombatLog（反馈文档第 7 节）。
// 读目录、读文件、跟踪新增内容在平台层做；这里只有能在 Linux 上测试的部分：
// - [`framer`]：把读到的字节切成完整的文本行（UTF-8 与 UTF-16，BOM、CRLF、超长行）。
// - [`header`]：文件头里的收听者（角色名），8 种语言的标签。
// - [`parser`]：单行的拆分与归类（受到伤害、造成伤害、未命中……），以及行里的 UTC 时间。
// - [`catalog`]：8 种语言的短语表。
// - [`directory`]：Gamelogs 目录的候选、文件的取舍与读取起点。
// - [`rules`]：一次读取合并成至多两条事件，事件是否提醒。提醒时段的延长在 planning 的 CombatAlertWindow。
// - [`replay`]：晚跟踪的文件从头读起时，过滤掉接入前的旧行。
// 只读日志文件，不写、不改、不删 EVE 目录下的任何内容。

//! 游戏日志与战斗提醒的纯逻辑。

pub mod catalog;
pub mod directory;
pub mod framer;
pub mod header;
pub mod parser;
pub mod replay;
pub mod rules;

#[cfg(test)]
mod tests;

/// 一行游戏日志的归类结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CombatLineKind {
    /// 本角色受到伤害，关联值是伤害数字（可能为 0）。
    IncomingDamage(i64),
    /// 本角色造成伤害，关联值是伤害数字。
    OutgoingDamage(i64),
    /// 对方攻击本角色但没有命中。
    IncomingMiss,
    /// 本角色的攻击没有命中。
    OutgoingMiss,
    /// combat 类别的其他消息，或判断不了方向的伤害行。
    OtherCombat,
    /// 其他类别（hint、notify 等）。
    Other,
}

/// 解析后的一行游戏日志。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CombatLogLine {
    /// 类别，小写，如 `combat`。
    pub category: String,
    /// 归类结果。
    pub kind: CombatLineKind,
}

/// 交给协调器的一条受击事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CombatLogEvent {
    /// 日志文件头里的收听者（角色名）。
    pub character: String,
    /// 受击的种类，只会是 `IncomingDamage` 或 `IncomingMiss`。
    pub kind: CombatLineKind,
}

/// 游戏日志跟踪服务的状态，显示在「提醒」页的状态行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CombatLogStatus {
    /// 没有在跟踪（功能关闭或已停止）。
    Stopped,
    /// 正在跟踪：所在目录与跟踪的文件数。
    Watching {
        /// 正在读的 Gamelogs 目录。
        directory: String,
        /// 跟踪的文件数。
        followed_files: usize,
    },
    /// 候选目录都不存在，关联值是第一个候选路径。
    DirectoryNotFound(String),
    /// 列目录被系统拒绝。
    AccessDenied(String),
}
