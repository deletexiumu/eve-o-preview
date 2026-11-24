// SPDX-License-Identifier: GPL-3.0-or-later
//
// 日志跟踪服务共用的后台轮询线程。游戏日志（受击提醒）与聊天日志（预警、翻译）的跟踪服务都是
// 「一个只在后台线程上用的 Worker，每 250 毫秒走一步，产生的消息交给主线程」，线程的启停放在这里：
// - start：开一个具名线程，先走一步，然后每隔一个间隔走一步，消息放进通道。
// - drain：主线程在自己的定时器里取走全部消息，不需要跨线程唤醒（主循环每 50 毫秒一次）。
// - Drop：关掉控制通道，线程在下一次等待时醒来退出，然后等它结束；之后不会再有消息。
// 每次换请求都建新的轮询线程，旧线程的通道随它一起丢掉，迟到的消息不会盖掉新的状态。
// 只用标准库，能在 Linux 上测试。

//! 日志跟踪服务共用的后台轮询线程。

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime};

use crate::game_log::file::seconds;

/// 两步之间的间隔。
pub const STEP_INTERVAL: Duration = Duration::from_millis(250);

/// 一个后台轮询线程。丢掉它就停止轮询。
#[derive(Debug)]
pub(crate) struct Poller<M> {
    /// 控制通道；丢掉它让线程退出。
    stop: Option<Sender<()>>,
    /// 后台线程。
    thread: Option<JoinHandle<()>>,
    /// 后台线程送来的消息。
    messages: Receiver<M>,
}

impl<M: Send + 'static> Poller<M> {
    /// 开一个名为 `name` 的线程，每一步用当前的墙上时钟调 `step`，把它追加的消息送给主线程。
    /// 线程建不出来时返回错误。
    pub fn start<F>(name: &str, mut step: F) -> std::io::Result<Self>
    where
        F: FnMut(f64, &mut Vec<M>) + Send + 'static,
    {
        let (stop, control) = mpsc::channel::<()>();
        let (sender, messages) = mpsc::channel();
        let thread = thread::Builder::new()
            .name(name.into())
            .spawn(move || run(&mut step, &control, &sender))?;
        Ok(Self {
            stop: Some(stop),
            thread: Some(thread),
            messages,
        })
    }

    /// 取走目前为止的全部消息。
    pub fn drain(&self) -> Vec<M> {
        self.messages.try_iter().collect()
    }
}

impl<M> Drop for Poller<M> {
    fn drop(&mut self) {
        // 先关控制通道，线程在等待里立即醒来；再等它结束（最多是读完手上这一块的时间）。
        self.stop = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// 当前的墙上时钟（1970 年以来的秒数）。
pub(crate) fn now() -> f64 {
    seconds(SystemTime::now())
}

/// 后台线程：先走一步，然后每隔一个间隔走一步，直到控制通道关闭或主线程不再收消息。
fn run<M>(step: &mut impl FnMut(f64, &mut Vec<M>), control: &Receiver<()>, sender: &Sender<M>) {
    let mut out = Vec::new();
    loop {
        step(now(), &mut out);
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
