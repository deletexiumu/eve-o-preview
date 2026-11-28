// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置界面「从日志添加」与翻译浮窗切换频道用的频道发现，对应 macOS 的 ChatChannelDiscovery（FileChatLogMonitor.swift）。
// 规则与 macOS 相同：
// - 候选目录与跟踪服务相同（设置里的日志目录，没设时用自动查找的目录），取第一个能列出的。
// - 只看最近 24 小时修改过的、文件名合法的聊天日志；读文件头，没有 Channel ID 的、私聊的、文件头没写完的不列。
// - 按 Channel ID 合并：收听者（不区分大小写）计数并记下角色名列表，名字取最近修改的那个文件里的，按最后修改时间从新到旧排。
// 一次扫描读几十到几百个文件的开头（每个至多 4 KB），由调用方放到后台线程里做，不阻塞界面。
// 只读，不写、不改、不删 EVE 目录下的任何内容。

//! 从聊天日志目录发现最近出现过的频道。

use std::collections::{HashMap, HashSet};
use std::path::Path;

use eveo_core::chat_log::directory::{candidates, parse_file_name};
use eveo_core::chat_log::{ChatChannelKind, DiscoveredChannel};

use super::file::{ChatHeaderProbe, probe_chat_header};
use crate::game_log::file::{Entry, Listing, list};

/// 只列这么多秒以内修改过的文件：24 小时，避免过早的旧频道干扰选择。
pub const WINDOW_SECONDS: f64 = 86_400.0;

/// 一个频道的累计结果。
struct Accumulated {
    /// 最近修改的那个文件里的频道名。
    name: String,
    /// 频道种类（按 ID 判断，同一个 ID 总是同一种）。
    kind: ChatChannelKind,
    /// 出现过的收听者，小写。
    listeners: HashSet<String>,
    /// 最近一个文件的修改时间。
    last_modified: f64,
}

/// 列出最近 24 小时出现过的频道，按最后修改时间从新到旧（相同时按 ID）。
/// `configured` 是设置里的日志目录，`automatic` 是自动查找的 logs 目录，`now` 是墙上时钟的秒数。
/// 目录都不存在或没有权限时返回空表。
pub fn discover_channels(configured: Option<&str>, automatic: &str, now: f64) -> Vec<DiscoveredChannel> {
    let Some((directory, entries)) = first_listing(&candidates(configured, automatic)) else {
        return Vec::new();
    };
    scan(Path::new(&directory), &entries, now - WINDOW_SECONDS)
}

/// 第一个能列出的候选目录与它的条目；遇到没有权限的目录就停（与 macOS 相同，不再往后找）。
fn first_listing(candidates: &[String]) -> Option<(String, Vec<Entry>)> {
    for path in candidates {
        match list(Path::new(path)) {
            Listing::Entries(entries) => return Some((path.clone(), entries)),
            Listing::Denied => return None,
            Listing::Missing => {}
        }
    }
    None
}

/// 按 Channel ID 合并 `cutoff` 之后修改过的文件。
fn scan(directory: &Path, entries: &[Entry], cutoff: f64) -> Vec<DiscoveredChannel> {
    let mut channels: HashMap<String, Accumulated> = HashMap::new();
    for entry in entries {
        // 先用文件名与修改时间筛，读文件头的只有最近的合法文件。
        let Some(file_name) = parse_file_name(&entry.name) else {
            continue;
        };
        if entry.modified_at < cutoff {
            continue;
        }
        let ChatHeaderProbe::Complete(header) = probe_chat_header(&directory.join(&entry.name)) else {
            continue;
        };
        let kind = header.kind();
        let Some(id) = header
            .channel_id
            .clone()
            .filter(|_| kind != ChatChannelKind::PrivateChat)
        else {
            continue;
        };
        // 文件头没有频道名时用文件名里的。
        let name = header.channel_name.clone().unwrap_or(file_name.channel);
        let channel = channels.entry(id).or_insert_with(|| Accumulated {
            name: name.clone(),
            kind,
            listeners: HashSet::new(),
            last_modified: entry.modified_at,
        });
        if let Some(listener) = &header.listener {
            channel.listeners.insert(listener.to_lowercase());
        }
        // 频道改过名时以最近的文件为准。
        if entry.modified_at >= channel.last_modified {
            channel.last_modified = entry.modified_at;
            channel.name = name;
        }
    }
    let mut result: Vec<DiscoveredChannel> = channels
        .into_iter()
        .map(|(id, c)| {
            let mut listener_names: Vec<String> = c.listeners.into_iter().collect();
            listener_names.sort();
            DiscoveredChannel {
                id,
                name: c.name,
                kind: c.kind,
                listeners: listener_names.len(),
                last_modified: c.last_modified,
                listener_names,
            }
        })
        .collect();
    // 最近用过的排前面；时间相同时按 ID，结果稳定。
    result.sort_by(|a, b| {
        b.last_modified
            .total_cmp(&a.last_modified)
            .then_with(|| a.id.cmp(&b.id))
    });
    result
}
