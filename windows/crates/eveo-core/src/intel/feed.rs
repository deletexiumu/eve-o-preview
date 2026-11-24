// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的缓冲，对应 macOS 的 IntelFeed.swift（设计文档 6.5 节）：按收听者分开，每个收听者至多 300 条，
// 编号在整个缓冲里递增、从 1 起。浮窗只显示活动角色的那一份，切换客户端时立即换内容。
// - 同一个收听者的消息按到达顺序排列，新的追加在末尾，已有的条目不挪位置。跟踪服务把每一轮补读的事件
//   按时间排好再交来，所以一轮之内仍是时间顺序。不按时间插入的理由：插到中间会让浮窗按编号对齐行时整表重排，
//   「N 条新消息」也不再累加。
// - items 的收听者先按原样比较，没有时再不区分大小写比较（coverage::match_name）。
// - 每次刷新前由控制器调 prune，丢掉早于保留时长的消息。
// - 星图数据晚于消息读完时，控制器用 reparse 重新解析缓冲里的消息。

//! 预警消息的缓冲：按收听者分开，每人至多 300 条。

use std::collections::{BTreeMap, VecDeque};

use super::IntelReport;
use crate::chat_log::ChatMessage;
use crate::chat_log::coverage::match_name;

/// 每个收听者至多保留的条数。
pub const CAPACITY_PER_CHARACTER: usize = 300;

/// 缓冲里的一条消息。
#[derive(Debug, Clone, PartialEq)]
pub struct IntelItem {
    /// 编号，在整个缓冲里递增。
    pub id: u64,
    /// 原始消息。
    pub message: ChatMessage,
    /// 解析结果。
    pub report: IntelReport,
}

/// 预警缓冲。
#[derive(Debug, Clone)]
pub struct IntelFeed {
    /// 收听者 → 消息，按到达顺序排列。
    by_listener: BTreeMap<String, VecDeque<IntelItem>>,
    /// 下一条的编号。
    next_id: u64,
}

impl Default for IntelFeed {
    fn default() -> Self {
        Self {
            by_listener: BTreeMap::new(),
            next_id: 1,
        }
    }
}

impl IntelFeed {
    /// 加一条消息；同一个收听者超过容量时丢最早的。返回这条的编号。
    pub fn append(&mut self, message: ChatMessage, report: IntelReport) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let key = self
            .key(&message.listener)
            .unwrap_or_else(|| message.listener.clone());
        let items = self.by_listener.entry(key).or_default();
        items.push_back(IntelItem { id, message, report });
        while items.len() > CAPACITY_PER_CHARACTER {
            items.pop_front();
        }
        id
    }

    /// 丢掉时间早于 cutoff 的消息，返回有没有丢。没有消息的收听者一并去掉。
    pub fn prune(&mut self, cutoff: f64) -> bool {
        let before = self.len();
        for items in self.by_listener.values_mut() {
            items.retain(|item| item.message.time >= cutoff);
        }
        self.by_listener.retain(|_, items| !items.is_empty());
        self.len() != before
    }

    /// 某个收听者的消息，旧的在前；没有时为空。
    pub fn items(&self, listener: &str) -> Vec<&IntelItem> {
        self.key(listener)
            .and_then(|key| self.by_listener.get(&key))
            .map(|items| items.iter().collect())
            .unwrap_or_default()
    }

    /// 清空全部收听者的消息。编号不重新开始。
    pub fn remove_all(&mut self) {
        self.by_listener.clear();
    }

    /// 清空某个收听者的消息，返回有没有清掉。
    pub fn remove_items(&mut self, listener: &str) -> bool {
        self.key(listener)
            .is_some_and(|key| self.by_listener.remove(&key).is_some())
    }

    /// 用新的解析规则重新解析每一条消息（星图数据晚于消息读完时）。编号与顺序不变。
    pub fn reparse(&mut self, mut parse: impl FnMut(&ChatMessage) -> IntelReport) {
        for item in self.by_listener.values_mut().flatten() {
            item.report = parse(&item.message);
        }
    }

    /// 全部消息的条数。
    pub fn len(&self) -> usize {
        self.by_listener.values().map(VecDeque::len).sum()
    }

    /// 是否一条消息也没有。
    pub fn is_empty(&self) -> bool {
        self.by_listener.is_empty()
    }

    /// 缓冲里与收听者对应的键：先原样相等，再不区分大小写相等。
    fn key(&self, listener: &str) -> Option<String> {
        match_name(listener, self.by_listener.keys().map(String::as_str)).map(str::to_owned)
    }
}
