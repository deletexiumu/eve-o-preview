// SPDX-License-Identifier: GPL-3.0-or-later
//
// ReleaseHistory 与 `UpdateFeed.historyURL` 的用例（v1.1 设计 8.8 节）：Release 列表的解析、中间版本的挑选、
// 条数与大小的上限、「还有更早的版本」的判断，以及列表地址的推导。

import Foundation
import Testing
import EVEOPreviewCore

/// 跨版本发布说明的解析与挑选。
struct ReleaseHistoryTests {
    /// 版本号字面量转成 `SemanticVersion`；写错时用例直接失败。
    private func version(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text))
    }

    /// 列表答复里的一项。
    private func item(_ tag: Any, body: Any? = nil, draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
        var object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease]
        if let body { object["body"] = body }
        return object
    }

    /// 把若干项编成列表答复的正文。
    private func listJSON(_ items: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: items)
    }

    /// 只看版本号，便于比较。
    private func versions(_ entries: [ReleaseNotesEntry]) -> [String] {
        entries.map(\.version)
    }

    // MARK: - 解析

    /// 正式版按答复顺序取出；草稿、预发布（字段或 tag）、tag 解析不了、不是对象的项跳过；body 缺失或 null 取空串。
    @Test func parseFiltersAndKeepsOrder() throws {
        let data = try listJSON([
            item("v1.1.3", body: "three"),
            item("v1.1.4", body: "draft", draft: true),
            item("v1.1.4-beta.1", body: "beta"),
            item("v1.1.2-rc.1", body: "rc", prerelease: false),
            item("v1.1.2", body: "pre", prerelease: true),
            item("latest", body: "bad"),
            item(7, body: "bad"),
            "not an object",
            item("V1.1.1", body: NSNull()),
            item("v1.1.0"),
        ])
        let page = try ReleaseHistory.parse(data)
        #expect(versions(page.entries) == ["1.1.3", "1.1.1", "1.1.0"])
        #expect(page.entries[0].notes == "three")
        #expect(page.entries[1].notes == "")
        #expect(page.entries[2].notes == "")
        #expect(!page.isFull)
    }

    /// 项数（含被跳过的）达到每页个数时 `isFull` 为真。
    @Test func fullPage() throws {
        let items = (0..<ReleaseHistory.pageSize).map { item("v1.0.\($0)", prerelease: $0 % 2 == 0) }
        let page = try ReleaseHistory.parse(try listJSON(items))
        #expect(page.isFull)
        #expect(page.entries.count == ReleaseHistory.pageSize / 2)
    }

    /// 正文超过 65,536 个字符时截短。
    @Test func longBodyIsTruncated() throws {
        let body = String(repeating: "x", count: ReleaseFeedParser.maxNotesCharacters + 10)
        let page = try ReleaseHistory.parse(try listJSON([item("v1.0.0", body: body)]))
        #expect(page.entries.first?.notes.count == ReleaseFeedParser.maxNotesCharacters)
    }

    /// 不是 JSON、不是数组、超过 4 MiB 时抛 malformedFeed。
    @Test func malformedLists() throws {
        #expect(throws: UpdateError.malformedFeed("release list is not JSON")) {
            try ReleaseHistory.parse(Data("{".utf8))
        }
        #expect(throws: UpdateError.malformedFeed("release list is not an array")) {
            try ReleaseHistory.parse(Data(#"{"tag_name":"v1.0.0"}"#.utf8))
        }
        let huge = Data(repeating: 0x20, count: ReleaseHistory.maxListBytes + 1)
        #expect(throws: UpdateError.malformedFeed("release list larger than 4 MiB")) {
            try ReleaseHistory.parse(huge)
        }
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

    // MARK: - 列表地址

    /// 正式地址的列表接口，每页个数与 `ReleaseHistory.pageSize` 一致。
    @Test func productionHistoryURL() {
        let feed = UpdateFeed.resolve(override: nil)
        #expect(feed.historyURL?.absoluteString
            == "https://api.github.com/repos/deletexiumu/eve-o-preview/releases?per_page=\(ReleaseHistory.pageSize)")
    }

    /// 测试地址：最后一段换成 releases.json，同源；没有 .json 文件名或带查询串时不取。
    @Test func testFeedHistoryURL() {
        #expect(UpdateFeed.resolve(override: "http://127.0.0.1:8123/feed.json").historyURL?.absoluteString
            == "http://127.0.0.1:8123/releases.json")
        #expect(UpdateFeed.resolve(override: "https://example.com/a/b/feed.json").historyURL?.absoluteString
            == "https://example.com/a/b/releases.json")
        #expect(UpdateFeed.resolve(override: "http://127.0.0.1:8123/feed.json?x=1").historyURL == nil)
        #expect(UpdateFeed.resolve(override: "http://127.0.0.1:8123/").historyURL == nil)
        #expect(UpdateFeed.resolve(override: "http://127.0.0.1:8123").historyURL == nil)
    }

    /// 不是测试地址、也不是正式地址的（只能手工构造）不取。
    @Test func otherProductionFeedHasNoHistory() throws {
        let feed = UpdateFeed(feedURL: try #require(URL(string: "https://api.github.com/repos/x/y/releases/latest")),
                              isTestFeed: false)
        #expect(feed.historyURL == nil)
    }
}
