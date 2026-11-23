// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的跟踪服务，对应 macOS 的 FileCombatLogMonitor 与 CombatLogTailer（反馈文档 7.1～7.4 节）。
// - start：开一个后台线程，每 250 毫秒走一步 Worker::step，把受击事件与状态变化放进通道。
// - drain：主线程在自己的定时器里取走全部消息，不需要跨线程唤醒（主循环每 50 毫秒一次）。
// - Drop：关掉控制通道，线程在下一次等待时醒来退出，然后等它结束；之后不会再有消息。
// 每次切换目录都建新的服务，旧服务的通道随它一起丢掉，迟到的消息不会盖掉新的状态（macOS 用代号做同样的事）。
// 只用标准库，不依赖 windows crate，整个服务能在 Linux 上测试。

//! 游戏日志的跟踪服务：后台线程轮询 Gamelogs，把受击事件与状态交给主线程。

mod file;
mod worker;

#[cfg(test)]
mod tests;

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime};

use eveo_core::combat_log::{CombatLogEvent, CombatLogStatus};

use self::worker::Worker;

/// 两步之间的间隔。
pub const STEP_INTERVAL: Duration = Duration::from_millis(250);

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
    /// 控制通道；丢掉它让线程退出。
    stop: Option<Sender<()>>,
    /// 后台线程。
    thread: Option<JoinHandle<()>>,
    /// 后台线程送来的消息。
    messages: Receiver<GameLogMessage>,
}

impl GameLogTailer {
    /// 开始跟踪这些候选目录（`combat_log::directory::candidates` 的结果）。线程建不出来时返回错误。
    pub fn start(candidates: Vec<String>) -> std::io::Result<Self> {
        let (stop, control) = mpsc::channel::<()>();
        let (sender, messages) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("game-log".into())
            .spawn(move || run(candidates, &control, &sender))?;
        Ok(Self {
            stop: Some(stop),
            thread: Some(thread),
            messages,
        })
    }

    /// 取走目前为止的全部消息。
    pub fn drain(&self) -> Vec<GameLogMessage> {
        self.messages.try_iter().collect()
    }
}

impl Drop for GameLogTailer {
    fn drop(&mut self) {
        // 先关控制通道，线程在等待里立即醒来；再等它结束（最多是读完手上这一块的时间）。
        self.stop = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// 当前的墙上时钟（1970 年以来的秒数）。
fn now() -> f64 {
    file::seconds(SystemTime::now())
}

/// 后台线程：先走一步，然后每隔一个间隔走一步，直到控制通道关闭或主线程不再收消息。
fn run(candidates: Vec<String>, control: &Receiver<()>, sender: &Sender<GameLogMessage>) {
    let mut worker = Worker::new(candidates, now());
    let mut out = Vec::new();
    loop {
        worker.step(now(), &mut out);
        for message in out.drain(..) {
            if sender.send(message).is_err() {
                return;
            }
        }
        match control.recv_timeout(STEP_INTERVAL) {
            Err(RecvTimeoutError::Timeout) => {}
            Ok(()) | Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}
