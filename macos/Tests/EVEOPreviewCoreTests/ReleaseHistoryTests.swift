// SPDX-License-Identifier: GPL-3.0-or-later
//
// ReleaseHistory 的用例（v1.1 设计 8.8 节）：中间版本的挑选、条数与大小的上限、「还有更早的版本」的判断。
// 1.5.0 起各版本的说明来自更新清单（UpdateManifestTests 核对清单里的挑选），GitHub 列表的解析与地址推导随之去掉。

import Foundation
import Testing
import EVEOPreviewCore

/// 跨版本发布说明的挑选。
struct ReleaseHistoryTests {
    /// 版本号字面量转成 `SemanticVersion`；写错时用例直接失败。
    private func version(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text))
    }

    /// 只看版本号，便于比较。
    private func versions(_ entries: [ReleaseNotesEntry]) -> [String] {
        entries.map(\.version)
    }

    // MARK: - 挑选

    /// 只留 running < v < latest，按版本号从新到旧排（列表顺序乱也一样），重复的版本只留第一次出现的。
    @Test func intermediatePicksRangeNewestFirst() throws {
        let entries = ["1.0.0", "1.1.2", "1.1.3", "1.1.1", "1.2.0", "1.1.2"].enumerated().map {
            ReleaseNotesEntry(version: $0.element, notes: "n\($0.offset)")
        }
        let picked = ReleaseHistory.intermediate(from: entries, running: try version("1.1.0"),
                                                 latest: try version("1.1.3"))
        #expect(versions(picked) == ["1.1.2", "1.1.1"])
        #expect(picked.first?.notes == "n1")
    }

    /// 正在运行的是 CI 构建（如 1.1.2-pr.3.abc，小于 1.1.2）时，1.1.2 也算中间版本。
    @Test func prereleaseRunningVersionIncludesItsRelease() throws {
        let entries = [ReleaseNotesEntry(version: "1.1.2", notes: ""), ReleaseNotesEntry(version: "1.1.1", notes: "")]
        let picked = ReleaseHistory.intermediate(from: entries, running: try version("1.1.2-pr.3.abc1234"),
                                                 latest: try version("1.1.3"))
        #expect(versions(picked) == ["1.1.2"])
    }

    /// 相邻版本之间没有中间版本；列表一页覆盖到了正在运行的版本，所以 `hasMore` 为假。
    @Test func adjacentVersionsHaveNoIntermediate() throws {
        let page = ReleaseHistoryPage(entries: [ReleaseNotesEntry(version: "1.1.3", notes: ""),
                                                ReleaseNotesEntry(version: "1.1.2", notes: "")], isFull: false)
        let record = ReleaseHistory.record(from: page, running: try version("1.1.2"), latest: try version("1.1.3"))
        #expect(record.entries.isEmpty)
        #expect(!record.hasMore)
        #expect(record.latestVersion == "1.1.3")
        #expect(record.runningVersion == "1.1.2")
    }

    // MARK: - 上限与「还有更早的」

    /// 超过 `maxEntries` 个时留最新的那些，`hasMore` 为真。
    @Test func entryLimit() throws {
        let entries = (1...15).reversed().map { ReleaseNotesEntry(version: "1.0.\($0)", notes: "n") }
        let page = ReleaseHistoryPage(entries: entries + [ReleaseNotesEntry(version: "1.0.0", notes: "")], isFull: false)
        let record = ReleaseHistory.record(from: page, running: try version("1.0.0"), latest: try version("1.0.16"))
        #expect(record.entries.count == ReleaseHistory.maxEntries)
        #expect(record.entries.first?.version == "1.0.15")
        #expect(record.hasMore)
    }

    /// 总字符数超过上限时从较旧的开始丢，`hasMore` 为真。
    @Test func sizeLimit() throws {
        let big = String(repeating: "x", count: ReleaseHistory.maxTotalCharacters / 2)
        let page = ReleaseHistoryPage(entries: ["1.0.3", "1.0.2", "1.0.1"].map { ReleaseNotesEntry(version: $0, notes: big) },
                                      isFull: false)
        let record = ReleaseHistory.record(from: page, running: try version("1.0.0"), latest: try version("1.0.4"))
        #expect(versions(record.entries) == ["1.0.3", "1.0.2"])
        #expect(record.hasMore)
    }

    /// 满页且整页都比正在运行的版本新：更早的中间版本可能在下一页，`hasMore` 为真；不满页时为假。
    @Test func fullPageWithoutRunningVersionHasMore() throws {
        let entries = ["1.0.9", "1.0.8"].map { ReleaseNotesEntry(version: $0, notes: "") }
        let running = try version("1.0.1")
        let latest = try version("1.0.9")
        #expect(ReleaseHistory.record(from: ReleaseHistoryPage(entries: entries, isFull: true),
                                      running: running, latest: latest).hasMore)
        #expect(!ReleaseHistory.record(from: ReleaseHistoryPage(entries: entries, isFull: false),
                                       running: running, latest: latest).hasMore)
    }
}
