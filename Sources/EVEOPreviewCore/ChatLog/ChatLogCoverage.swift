// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的覆盖情况：跟踪服务正在跟踪哪些（收听者，频道）的日志文件。
// 用途：EVE 有时不为某个频道写日志文件（例如 2026-11 用户本机的 Local、Corp、Alliance 连续几天没有文件），
// 这时浮窗只能显示「还没有消息」，用户看不出原因。功能控制器用这里的规则判断「活动角色在全部所选频道都没有
// 日志文件」，在浮窗的状态行里说明，而不是让用户以为翻译坏了。
// - FollowedChatChannel：一个被跟踪的聊天日志文件的收听者与频道（只取文件头，不含文件名与路径）。
// - ChatLogCoverage.missingChannels：所选频道里，某个收听者没有被跟踪的文件的那些。
//   跟踪服务还没扫描完（followed 为 nil）时一律返回空，避免启动时闪一下提示。
// 只做纯计算，跟踪服务在平台层。

import Foundation

/// 跟踪服务正在跟踪的一个聊天日志文件的收听者与频道。
public struct FollowedChatChannel: Sendable, Hashable {
    /// 文件头的收听者（角色名）。
    public var listener: String
    /// 文件头的 Channel ID。
    public var channelID: String
    /// 文件头的 Channel Name；没有时为 nil。
    public var channelName: String?

    /// 用各字段建一个结果。
    public init(listener: String, channelID: String, channelName: String?) {
        self.listener = listener
        self.channelID = channelID
        self.channelName = channelName
    }
}

/// 聊天日志覆盖情况的规则。
public enum ChatLogCoverage {
    /// channels 里 listener 没有被跟踪的日志文件的频道，保持 channels 的顺序。
    ///
    /// - Parameters:
    ///   - listener: 角色名，按 `CharacterNameMatch` 的规则与文件头的收听者比较（先原样，再不区分大小写）。
    ///   - channels: 功能所选的频道。
    ///   - followed: 跟踪服务正在跟踪的文件；nil 表示还没扫描完，此时返回空数组。
    public static func missingChannels(for listener: String, channels: [ChannelRef],
                                       followed: [FollowedChatChannel]?) -> [ChannelRef] {
        guard let followed else { return [] }
        // 先找出这个角色对应的收听者名（大小写可能与窗口标题不同）。
        let listeners = Set(followed.map(\.listener))
        guard let own = CharacterNameMatch.match(listener, in: listeners.sorted()) else { return channels }
        let mine = followed.filter { $0.listener == own }
        return channels.filter { channel in
            !mine.contains { channel.matches(channelID: $0.channelID, channelName: $0.channelName) }
        }
    }

    /// listener 在 channels 的每一个里都没有被跟踪的日志文件。channels 为空或 followed 为 nil 时为假。
    public static func lacksAllLogs(for listener: String, channels: [ChannelRef],
                                    followed: [FollowedChatChannel]?) -> Bool {
        guard !channels.isEmpty, followed != nil else { return false }
        return missingChannels(for: listener, channels: channels, followed: followed).count == channels.count
    }
}
