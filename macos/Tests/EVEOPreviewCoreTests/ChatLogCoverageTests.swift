// SPDX-License-Identifier: GPL-3.0-or-later
//
// ChatLogCoverage 的用例：判断某个角色在所选频道里有没有被跟踪的日志文件。
// 角色名、频道名与 ID 都是虚构的。

import Testing
import EVEOPreviewCore

/// 聊天日志覆盖情况的规则。
struct ChatLogCoverageTests {
    /// 虚构的玩家频道。
    private let intel = ChannelRef(name: "intel.Demo", id: "player_00000000000000000000000000de0001")

    /// 只有玩家频道的文件、没有 Local 的文件：Local 算缺失（用户本机 2026-11 的情形）。
    @Test func localMissingWhenOnlyPlayerChannelFollowed() {
        let followed = [FollowedChatChannel(listener: "Demo Pilot", channelID: intel.id!, channelName: "intel.Demo")]
        #expect(ChatLogCoverage.missingChannels(for: "Demo Pilot", channels: [.local], followed: followed) == [.local])
        #expect(ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local], followed: followed))
    }

    /// 有一个频道有文件就不算「全部缺失」，但缺的那个仍列出来。
    @Test func partialCoverageIsNotAllMissing() {
        let followed = [FollowedChatChannel(listener: "Demo Pilot", channelID: intel.id!, channelName: "intel.Demo")]
        let channels = [ChannelRef.local, intel]
        #expect(ChatLogCoverage.missingChannels(for: "Demo Pilot", channels: channels, followed: followed) == [.local])
        #expect(!ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: channels, followed: followed))
    }

    /// 内置频道按 ID 匹配，名字随客户端语言变也不影响。
    @Test func builtInMatchesByIDWhateverTheName() {
        let followed = [FollowedChatChannel(listener: "Demo Pilot", channelID: "local", channelName: "本地")]
        #expect(!ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local], followed: followed))
    }

    /// 别的角色有文件不算：按收听者区分。
    @Test func otherListenersDoNotCount() {
        let followed = [FollowedChatChannel(listener: "Demo Other", channelID: "local", channelName: "Local")]
        #expect(ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local], followed: followed))
    }

    /// 收听者只差大小写时仍认作同一个角色。
    @Test func listenerMatchIgnoresCaseAsFallback() {
        let followed = [FollowedChatChannel(listener: "demo pilot", channelID: "local", channelName: "Local")]
        #expect(!ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local], followed: followed))
    }

    /// 两个只差大小写的角色：原样相等的优先，不借用另一个的文件。
    @Test func exactListenerWinsOverCaseInsensitive() {
        let followed = [
            FollowedChatChannel(listener: "demo pilot", channelID: "local", channelName: "Local"),
            FollowedChatChannel(listener: "Demo Pilot", channelID: "corp", channelName: "Corp"),
        ]
        #expect(ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local], followed: followed))
    }

    /// 还没扫描完（nil）或没有选频道时不提示。
    @Test func unknownOrEmptyIsNeverMissing() {
        #expect(ChatLogCoverage.missingChannels(for: "Demo Pilot", channels: [.local], followed: nil).isEmpty)
        #expect(!ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local], followed: nil))
        #expect(!ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [], followed: []))
    }

    /// 跟踪服务扫描完但一个文件都没有：所选频道全部缺失。
    @Test func emptyFollowedMeansAllMissing() {
        #expect(ChatLogCoverage.lacksAllLogs(for: "Demo Pilot", channels: [.local, .corp], followed: []))
    }
}
