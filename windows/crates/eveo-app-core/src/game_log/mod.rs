// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的跟踪服务，对应 macOS 的 FileCombatLogMonitor 与 CombatLogTailer（反馈文档 7.1～7.4 节）。
// - start：用 crate::poller 开一个后台线程，每 250 毫秒走一步 Worker::step，把受击事件与状态变化放进通道。
// - drain：主线程在自己的定时器里取走全部消息。丢掉服务就停止线程，之后不会再有消息。
// 每次切换目录都建新的服务，旧服务的通道随它一起丢掉，迟到的消息不会盖掉新的状态（macOS 用代号做同样的事）。
// 只用标准库，不依赖 windows crate，整个服务能在 Linux 上测试。

//! 游戏日志的跟踪服务：后台线程轮询 Gamelogs，把受击事件与状态交给主线程。

pub(crate) mod file;
mod worker;

#[cfg(test)]
mod tests;

use eveo_core::combat_log::{CombatLogEvent, CombatLogStatus};

use self::worker::Worker;
use crate::poller::{Poller, now};

pub use crate::poller::STEP_INTERVAL;

/// 跟踪服务送给主线程的消息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GameLogMessage {
    /// 一批受击事件，还没按提醒设置过滤。
    Events(Vec<CombatLogEvent>),
    /// 状态变了。
    Status(CombatLogStatus),
}

/// 游戏日志的跟踪服务。丢掉它就停止跟踪。
#[derive(Debug)]
pub struct GameLogTailer {
    /// 后台轮询线程。
    poller: Poller<GameLogMessage>,
}

impl GameLogTailer {
    /// 开始跟踪这些候选目录（`combat_log::directory::candidates` 的结果）。线程建不出来时返回错误。
    pub fn start(candidates: Vec<String>) -> std::io::Result<Self> {
        let mut worker = Worker::new(candidates, now());
        let poller = Poller::start("game-log", move |now, out| worker.step(now, out))?;
        Ok(Self { poller })
    }

    /// 取走目前为止的全部消息。
    pub fn drain(&self) -> Vec<GameLogMessage> {
        self.poller.drain()
    }
}
