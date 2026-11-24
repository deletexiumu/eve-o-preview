// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的跟踪服务，对应 macOS 的 FileChatLogMonitor 与 ChatLogTailer（docs/macos/design-intel-translate.md 5.4～5.6 节）。
// 预警与翻译都读它：功能控制器按设置拼出 ChatLogRequest，请求变了时丢掉旧服务、建新服务，全部文件重新定起点。
// - start：用 crate::poller 开一个后台线程，每 250 毫秒走一步 Worker::step。
// - drain：主线程在自己的定时器里取走消息：一批批事件（消息与位置线索）、状态变化、覆盖情况变化。
// - 丢掉服务就停止线程；旧服务的通道随它一起丢掉，迟到的消息不会混进新请求的结果（macOS 用代号做同样的事）。
// 只读日志文件，不写、不改、不删 EVE 目录下的任何内容。只用标准库，整个服务能在 Linux 上测试。

//! 聊天日志的跟踪服务：后台线程轮询 Chatlogs（与位置线索用的 Gamelogs），把消息、线索与状态交给主线程。

pub mod discovery;
mod file;
mod worker;

#[cfg(test)]
mod tests;

use eveo_core::chat_log::coverage::FollowedChatChannel;
use eveo_core::chat_log::request::ChatLogRequest;
use eveo_core::chat_log::{ChatLogEvent, ChatLogStatus};

use self::worker::Worker;
use crate::poller::{Poller, now};

/// 跟踪服务送给主线程的消息。
#[derive(Debug, Clone, PartialEq)]
pub enum ChatLogMessage {
    /// 一批事件，按日志里的先后顺序。启动时补读的内容合成一批，之后每读一次文件一批。
    Events(Vec<ChatLogEvent>),
    /// 状态变了（只反映聊天日志目录）。
    Status(ChatLogStatus),
    /// 跟踪的聊天日志文件的收听者与频道变了（去重、排好序）。浮窗据此说明「EVE 没写这个频道的日志」。
    Followed(Vec<FollowedChatChannel>),
}

/// 聊天日志的跟踪服务。丢掉它就停止跟踪。
#[derive(Debug)]
pub struct ChatLogTailer {
    /// 这个服务的请求。
    request: ChatLogRequest,
    /// 后台轮询线程。
    poller: Poller<ChatLogMessage>,
}

impl ChatLogTailer {
    /// 按请求开始跟踪。`automatic` 是自动查找的 logs 目录（`文档\EVE\logs`），设置里没给目录时用它。
    /// 线程建不出来时返回错误。
    pub fn start(request: ChatLogRequest, automatic: &str) -> std::io::Result<Self> {
        let mut worker = Worker::new(request.clone(), automatic, now());
        let poller = Poller::start("chat-log", move |now, out| worker.step(now, out))?;
        Ok(Self { request, poller })
    }

    /// 这个服务的请求；调用方用 [`ChatLogRequest::requires_restart`] 判断要不要换新服务。
    pub fn request(&self) -> &ChatLogRequest {
        &self.request
    }

    /// 取走目前为止的全部消息。
    pub fn drain(&self) -> Vec<ChatLogMessage> {
        self.poller.drain()
    }
}
