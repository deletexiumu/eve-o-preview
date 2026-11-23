// SPDX-License-Identifier: GPL-3.0-or-later
//
// ChannelRef.matches 的用例（docs/macos/design-intel-translate.md 5.3 节、14.1 节）。频道名与 ID 都是虚构的。

import Testing
import EVEOPreviewCore

/// 频道的匹配：内置频道按 ID，玩家频道按 ID 或名字，私聊一律不匹配。
struct ChannelRefTests {
    /// 虚构的玩家频道 ID。
    private let playerID = "player_00112233445566778899aabbccddeeff"

    /// 4 个内置频道按 ID 匹配，不看名字（名字随客户端语言变）。
    @Test func builtInsMatchByID() {
        #expect(ChannelRef.local.matches(channelID: "local", channelName: "本地"))
        #expect(ChannelRef.corp.matches(channelID: "corp", channelName: "军团"))
        #expect(ChannelRef.alliance.matches(channelID: "alliance", channelName: nil))
        #expect(!ChannelRef.local.matches(channelID: "corp", channelName: "Local"))
        #expect(!ChannelRef.corp.matches(channelID: nil, channelName: "Corp"))
        #expect(ChannelRef.local.isBuiltIn && ChannelRef.fleet.isBuiltIn)
        #expect(!ChannelRef(name: "intel.Demo").isBuiltIn)
        #expect(ChannelRef.builtIns == [.local, .corp, .alliance, .fleet])
    }

    /// fleet 按前缀匹配 `fleet_<数字>`。
    @Test func fleetMatchesPrefix() {
        #expect(ChannelRef.fleet.matches(channelID: "fleet_123", channelName: "Fleet"))
        #expect(ChannelRef.fleet.matches(channelID: "FLEET_98765", channelName: nil))
        #expect(!ChannelRef.fleet.matches(channelID: "fleet", channelName: "Fleet"))
        #expect(!ChannelRef.fleet.matches(channelID: "corp", channelName: "Fleet"))
    }

    /// 玩家频道：ID 相同、名字不同（频道改名）时匹配。
    @Test func playerChannelMatchesByID() {
        let ref = ChannelRef(name: "Old Name", id: playerID)
        #expect(ref.matches(channelID: playerID, channelName: "New Name"))
    }

    /// 玩家频道：ID 不同、名字相同（频道重建）时匹配。
    @Test func playerChannelMatchesByName() {
        let ref = ChannelRef(name: "intel.Demo", id: playerID)
        #expect(ref.matches(channelID: "player_ffeeddccbbaa99887766554433221100", channelName: "intel.Demo"))
        #expect(!ref.matches(channelID: "player_ffeeddccbbaa99887766554433221100", channelName: "other.Demo"))
    }

    /// 只有名字时不区分大小写，去掉首尾空白后比较。
    @Test func nameOnlyIsCaseInsensitive() {
        let ref = ChannelRef(name: " Intel.Demo ")
        #expect(ref.matches(channelID: playerID, channelName: "intel.demo"))
        #expect(!ref.matches(channelID: playerID, channelName: nil))
        #expect(!ChannelRef(name: "").matches(channelID: playerID, channelName: ""))
    }

    /// 私聊频道一律不匹配，哪怕名字或 ID 相同。
    @Test func privateNeverMatches() {
        #expect(!ChannelRef(name: "Mira Voss").matches(channelID: "private_42", channelName: "Mira Voss"))
        #expect(!ChannelRef(name: "x", id: "private_42").matches(channelID: "private_42", channelName: "x"))
        #expect(!ChannelRef(name: "x", id: "PRIVATE_42").matches(channelID: "PRIVATE_42", channelName: "x"))
    }
}
