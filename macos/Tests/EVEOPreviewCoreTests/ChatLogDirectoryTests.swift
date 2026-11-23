// SPDX-License-Identifier: GPL-3.0-or-later
//
// ChatLogDirectory 的用例（docs/macos/design-intel-translate.md 5.2 节、5.4 节、14.1 节）：候选目录、文件名、
// 跟踪文件的取舍与 UTF-16 的偶数偏移量。频道名与收听者都是虚构的。

import Testing
import EVEOPreviewCore

/// 聊天日志目录与文件的规则。
struct ChatLogDirectoryTests {
    /// 测试用的主目录。
    private let home = "/Users/sample"

    /// 4 种 configured：nil（及空白）、logs、Gamelogs、Chatlogs。
    @Test func candidates() {
        #expect(ChatLogDirectory.candidates(configured: nil, homeDirectory: home)
                == ["/Users/sample/Documents/EVE/logs/Chatlogs"])
        #expect(ChatLogDirectory.candidates(configured: "  ", homeDirectory: home + "/")
                == ["/Users/sample/Documents/EVE/logs/Chatlogs"])
        #expect(ChatLogDirectory.candidates(configured: "/Volumes/D/EVE/logs/", homeDirectory: home)
                == ["/Volumes/D/EVE/logs/Chatlogs", "/Volumes/D/EVE/logs"])
        #expect(ChatLogDirectory.candidates(configured: "/Volumes/D/EVE/logs/Gamelogs", homeDirectory: home)
                == ["/Volumes/D/EVE/logs/Chatlogs"])
        #expect(ChatLogDirectory.candidates(configured: "~/Documents/EVE/logs/CHATLOGS/", homeDirectory: home)
                == ["/Users/sample/Documents/EVE/logs/CHATLOGS"])
        #expect(ChatLogDirectory.candidates(configured: "/Gamelogs", homeDirectory: home) == ["/Chatlogs"])
    }

    /// 游戏日志的候选：Chatlogs 先换成同级的 Gamelogs，其余同 CombatLogDirectory。
    @Test func gameLogCandidates() {
        #expect(ChatLogDirectory.gameLogCandidates(configured: "/Volumes/D/EVE/logs/Chatlogs", homeDirectory: home)
                == ["/Volumes/D/EVE/logs/Gamelogs"])
        #expect(ChatLogDirectory.gameLogCandidates(configured: "/Volumes/D/EVE/logs", homeDirectory: home)
                == CombatLogDirectory.candidates(configured: "/Volumes/D/EVE/logs", homeDirectory: home))
        #expect(ChatLogDirectory.gameLogCandidates(configured: nil, homeDirectory: home)
                == ["/Users/sample/Documents/EVE/logs/Gamelogs"])
    }

    /// 频道名里有 `.`、`+`、`_` 与汉字时，从右边解析。
    @Test func fileNames() {
        #expect(ChatLogDirectory.parseFileName("intel.Demo_20261120_113340_1234567890.txt")
                == ChatLogDirectory.FileName(channel: "intel.Demo", stamp: "20261120_113340", suffix: "1234567890"))
        #expect(ChatLogDirectory.parseFileName("a+b_c_20261120_113340_7.TXT")?.channel == "a+b_c")
        #expect(ChatLogDirectory.parseFileName("预警_频道_20261120_000001_42.txt")?.channel == "预警_频道")
        #expect(ChatLogDirectory.parseFileName("Local_20261119_235959_1.txt")?.stamp == "20261119_235959")
    }

    /// 不合法的文件名返回 nil。
    @Test(arguments: [
        "Local_20261119_235959.txt", "_20261119_235959_1.txt", "Local_2026111_235959_1.txt",
        "Local_20261119_23595_1.txt", "Local_20261119_235959_x.txt", "Local_20261119_235959_1.log",
        "Local_20261119_235959_.txt", ".txt", "20261119_235959_1.txt",
    ])
    func invalidFileNames(name: String) {
        #expect(ChatLogDirectory.parseFileName(name) == nil)
    }

    /// 同一个（收听者，频道）取时间戳最大的；超过上限时留最新的；不同收听者各留一个。
    @Test func selectFollowed() {
        typealias C = ChatLogDirectory.Candidate
        let candidates = [
            C(name: "old", stamp: "20261119_100000", listener: "Kael Doran", channelID: "player_a"),
            C(name: "new", stamp: "20261120_100000", listener: "Kael Doran", channelID: "player_a"),
            C(name: "other-listener", stamp: "20261118_100000", listener: "Mira Voss", channelID: "player_a"),
            C(name: "local", stamp: "20261120_090000", listener: "Kael Doran", channelID: "local"),
        ]
        #expect(ChatLogDirectory.selectFollowed(candidates) == ["new", "local", "other-listener"])
        #expect(ChatLogDirectory.selectFollowed(candidates, limit: 2) == ["new", "local"])
        #expect(ChatLogDirectory.selectFollowed(candidates, limit: 0).isEmpty)
        #expect(ChatLogDirectory.maxFollowedFiles == 48 && ChatLogDirectory.recentSeconds == 172_800)
    }

    /// 偏移量向下取成偶数；负数取 0。
    @Test func alignedOffset() {
        #expect(ChatLogDirectory.alignedOffset(0) == 0)
        #expect(ChatLogDirectory.alignedOffset(7) == 6)
        #expect(ChatLogDirectory.alignedOffset(8) == 8)
        #expect(ChatLogDirectory.alignedOffset(-3) == 0)
    }

    /// 补读的起点：文件小于 maxBytes 时是 0，大于时是差值，总是偶数。
    @Test func backfillStart() {
        #expect(ChatLogDirectory.backfillStart(fileSize: 1_000, maxBytes: 524_288) == 0)
        #expect(ChatLogDirectory.backfillStart(fileSize: 600_000, maxBytes: 524_288) == 75_712)
        #expect(ChatLogDirectory.backfillStart(fileSize: 600_001, maxBytes: 524_288) == 75_712)
        #expect(ChatLogDirectory.backfillStart(fileSize: 524_289, maxBytes: 524_287) % 2 == 0)
    }
}
