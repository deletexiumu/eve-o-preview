// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的覆盖情况，对应 macOS 的 ChatLogCoverage.swift：跟踪服务正在跟踪哪些（收听者，频道）的日志文件。
// EVE 有时不为某个频道写日志文件（2026-11 用户本机的 Local、Corp、Alliance 连续几天没有文件），这时浮窗只能
// 显示「还没有消息」，用户看不出原因。功能控制器用这里的规则判断「活动角色在全部所选频道都没有日志文件」，
// 在浮窗的状态行里说明。跟踪服务还没扫描完（followed 为 None）时一律不提示，避免启动时闪一下。

//! 聊天日志的覆盖情况：所选频道里哪些没有被跟踪的日志文件。

use crate::model::ChannelRef;

/// 跟踪服务正在跟踪的一个聊天日志文件的收听者与频道。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FollowedChatChannel {
    /// 文件头的收听者（角色名）。
    pub listener: String,
    /// 文件头的 Channel ID。
    pub channel_id: String,
    /// 文件头的 Channel Name；没有时为 `None`。
    pub channel_name: Option<String>,
}

/// 在 `candidates` 里找与 `name` 对应的角色名：先原样相等，再不区分大小写相等；都没有时返回 `None`。
/// 不区分大小写的命中有多个时取靠前的。对应 macOS 的 CharacterNameMatch.match。
pub fn match_name<'a>(name: &str, candidates: impl IntoIterator<Item = &'a str>) -> Option<&'a str> {
    let lower = name.to_lowercase();
    let mut folded = None;
    for candidate in candidates {
        if candidate == name {
            return Some(candidate);
        }
        if folded.is_none() && candidate.to_lowercase() == lower {
            folded = Some(candidate);
        }
    }
    folded
}

/// `channels` 里 `listener` 没有被跟踪的日志文件的频道，保持 `channels` 的顺序。
/// `followed` 为 `None` 表示还没扫描完，此时返回空。
pub fn missing_channels(
    listener: &str,
    channels: &[ChannelRef],
    followed: Option<&[FollowedChatChannel]>,
) -> Vec<ChannelRef> {
    let Some(followed) = followed else {
        return Vec::new();
    };
    // 先找出这个角色对应的收听者名（大小写可能与窗口标题不同）；排序后再找，结果稳定。
    let mut listeners: Vec<&str> = followed.iter().map(|f| f.listener.as_str()).collect();
    listeners.sort_unstable();
    listeners.dedup();
    let Some(own) = match_name(listener, listeners) else {
        return channels.to_vec();
    };
    let mine: Vec<&FollowedChatChannel> = followed.iter().filter(|f| f.listener == own).collect();
    channels
        .iter()
        .filter(|channel| {
            !mine
                .iter()
                .any(|f| channel.matches(Some(&f.channel_id), f.channel_name.as_deref()))
        })
        .cloned()
        .collect()
}

/// `listener` 在 `channels` 的每一个里都没有被跟踪的日志文件。`channels` 为空或 `followed` 为 `None` 时为假。
pub fn lacks_all_logs(
    listener: &str,
    channels: &[ChannelRef],
    followed: Option<&[FollowedChatChannel]>,
) -> bool {
    !channels.is_empty()
        && followed.is_some()
        && missing_channels(listener, channels, followed).len() == channels.len()
}
