// SPDX-License-Identifier: GPL-3.0-or-later
//
// CombatLogDirectory 的用例（反馈文档 7.3 节、10.1 节）：候选目录，以及跟踪服务的几条纯规则
// （48 小时、按收听者取最新、至多 16 个、起点、截断）。

import Testing
import EVEOPreviewCore

/// 目录的候选与文件的取舍。
struct CombatLogDirectoryTests {
    /// 测试用的主目录。
    private let home = "/Users/sample"

    /// 没有配置（或配置是空白）时取默认路径（L1）。
    @Test func defaultPath() {
        let expected = ["/Users/sample/Documents/EVE/logs/Gamelogs"]
        #expect(CombatLogDirectory.candidates(configured: nil, homeDirectory: home) == expected)
        #expect(CombatLogDirectory.candidates(configured: "  ", homeDirectory: home) == expected)
        #expect(CombatLogDirectory.candidates(configured: nil, homeDirectory: home + "/") == expected)
    }

    /// 配置的是 logs 目录：先找它下面的 Gamelogs，再找它自己。
    @Test func logsDirectory() {
        #expect(CombatLogDirectory.candidates(configured: "/Volumes/Data/EVE/logs/", homeDirectory: home)
                == ["/Volumes/Data/EVE/logs/Gamelogs", "/Volumes/Data/EVE/logs"])
    }

    /// 配置的就是 Gamelogs 目录（不区分大小写）：只返回它自己。
    @Test func gamelogsDirectory() {
        #expect(CombatLogDirectory.candidates(configured: "/Volumes/Data/EVE/logs/Gamelogs", homeDirectory: home)
                == ["/Volumes/Data/EVE/logs/Gamelogs"])
        #expect(CombatLogDirectory.candidates(configured: "/tmp/GAMELOGS/", homeDirectory: home) == ["/tmp/GAMELOGS"])
    }

    /// 开头的 `~` 展开成主目录。
    @Test func tildeExpansion() {
        #expect(CombatLogDirectory.candidates(configured: "~/Documents/EVE/logs", homeDirectory: home)
                == ["/Users/sample/Documents/EVE/logs/Gamelogs", "/Users/sample/Documents/EVE/logs"])
        #expect(CombatLogDirectory.candidates(configured: "~", homeDirectory: home)
                == ["/Users/sample/Gamelogs", "/Users/sample"])
    }

    /// 只认 `.txt` 文件，隐藏文件不算。
    @Test func logFileNames() {
        #expect(CombatLogDirectory.isLogFileName("20261120_113346_1234567890.txt"))
        #expect(CombatLogDirectory.isLogFileName("20261120_113329.TXT"))
        #expect(!CombatLogDirectory.isLogFileName(".DS_Store"))
        #expect(!CombatLogDirectory.isLogFileName("._20261120_113329.txt"))
        #expect(!CombatLogDirectory.isLogFileName("notes.log"))
    }

    /// 修改时间在 48 小时内的文件才看。
    @Test func recentWindow() {
        let now = 1_000_000.0
        #expect(CombatLogDirectory.isRecent(modifiedAt: now - 48 * 3_600, now: now))
        #expect(!CombatLogDirectory.isRecent(modifiedAt: now - 48 * 3_600 - 1, now: now))
        #expect(CombatLogDirectory.isRecent(modifiedAt: now + 5, now: now))
    }

    /// 同一个收听者只取文件名最大的；结果按文件名从大到小排列。
    @Test func newestFilePerListener() {
        let candidates = [
            CombatLogDirectory.Candidate(name: "20261120_095137_1.txt", listener: "Aurora Vale"),
            CombatLogDirectory.Candidate(name: "20261120_113331_1.txt", listener: "Aurora Vale"),
            CombatLogDirectory.Candidate(name: "20261120_113346_2.txt", listener: "Borealis Kade"),
            CombatLogDirectory.Candidate(name: "20261119_080000_3.txt", listener: "Cygnus Ward"),
        ]
        #expect(CombatLogDirectory.selectFollowed(candidates)
                == ["20261120_113346_2.txt", "20261120_113331_1.txt", "20261119_080000_3.txt"])
    }

    /// 超过 16 个收听者时保留文件名最大的 16 个。
    @Test func limitToSixteen() {
        let candidates = (0..<20).map {
            CombatLogDirectory.Candidate(name: String(format: "20261120_%06d.txt", $0), listener: "Pilot \($0)")
        }
        let selected = CombatLogDirectory.selectFollowed(candidates)
        #expect(selected.count == CombatLogDirectory.maxFollowedFiles)
        #expect(selected.first == "20261120_000019.txt")
        #expect(selected.last == "20261120_000004.txt")
    }

    /// 启动前已有的文件（创建时间早于启动时刻减 2 秒）从末尾读起，之后建的从头读起。
    @Test func startOffset() {
        let start = 5_000.0
        #expect(CombatLogDirectory.startsAtEnd(createdAt: start - 10, tailerStartedAt: start))
        #expect(!CombatLogDirectory.startsAtEnd(createdAt: start - 2, tailerStartedAt: start))
        #expect(!CombatLogDirectory.startsAtEnd(createdAt: start + 30, tailerStartedAt: start))
        #expect(CombatLogDirectory.startsAtEnd(createdAt: nil, tailerStartedAt: start))
    }

    /// 文件变短时视为被截断，从 0 开始读。
    @Test func truncation() {
        let grown = CombatLogDirectory.readStart(offset: 100, fileSize: 150)
        #expect(grown.offset == 100 && !grown.truncated)
        let same = CombatLogDirectory.readStart(offset: 100, fileSize: 100)
        #expect(same.offset == 100 && !same.truncated)
        let shrunk = CombatLogDirectory.readStart(offset: 100, fileSize: 40)
        #expect(shrunk.offset == 0 && shrunk.truncated)
    }
}
