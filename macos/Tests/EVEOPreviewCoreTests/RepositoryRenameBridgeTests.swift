// SPDX-License-Identifier: GPL-3.0-or-later
//
// 仓库改名的用例：1.3.0 起接受新旧两个名字，2026-11-23 仓库改名为 eve-o-preview，1.3.2 起正式地址用新名字。
// 同一仓库还会发布 Windows 版（tag `win-v*`）。
// - 附件与发布页同时接受新旧两个仓库名，别的名字（包括只差一个后缀的）仍然拒绝。
// - `releases/latest` 是 Windows 版时，`needsListFallback` 为真，`parseLatestFromList` 从列表里挑出 macOS 的最新正式版。
// - Release 列表每页 100 条。

import Foundation
import Testing
import EVEOPreviewCore

/// 改名与 Windows 版发布前的兼容规则。
struct RepositoryRenameBridgeTests {
    /// 正式地址。
    private let production = UpdateFixtures.productionFeed

    /// 改名后的仓库在 Release 路径下的地址被接受。
    @Test(arguments: [
        "https://github.com/deletexiumu/eve-o-preview/releases/download/v1.3.1/EVE-O-Preview-1.3.1.dmg",
        "https://github.com/deletexiumu/eve-o-preview/releases/download/v1.3.1/SHA256SUMS.txt",
        "https://github.com/deletexiumu/eve-o-preview/releases/tag/v1.3.1",
        "https://github.com/deletexiumu/eve-o-preview/releases/latest",
    ])
    func acceptsRenamedRepository(url: String) {
        #expect(production.accepts(url))
    }

    /// 与新名字相近的仓库名、别的账号、仓库的非 Release 路径与跳出 Release 目录的路径都不认。
    @Test(arguments: [
        "https://github.com/deletexiumu/eve-o-preview-fork/releases/tag/v1",
        "https://github.com/deletexiumu/eve-o-previewx/releases/tag/v1",
        "https://github.com/deletexiumu/eve-o-preview/issues/1",
        "https://github.com/deletexiumu/eve-o-preview/release/tag/v1",
        "https://github.com/someone/eve-o-preview/releases/tag/v1",
        "http://github.com/deletexiumu/eve-o-preview/releases/tag/v1",
        "https://github.com/deletexiumu/eve-o-preview/releases/../../evil/releases/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview/releases/%2e%2e/x.dmg",
        "https://github.com.evil.com/deletexiumu/eve-o-preview/releases/x.dmg",
    ])
    func rejectsLookalikes(url: String) {
        #expect(!production.accepts(url))
    }

    /// 改名后 GitHub 的答复里 `html_url` 与附件都是新名字，仍能解析出全部附件。
    @Test func parsesRenamedFeed() throws {
        let renamed = UpdateFixtures.githubLatest.replacingOccurrences(of: "/eve-o-preview-macos/releases/",
                                                                        with: "/eve-o-preview/releases/")
        let info = try ReleaseFeedParser.parse(Data(renamed.utf8), feed: production)
        #expect(info.pageURL == "https://github.com/deletexiumu/eve-o-preview/releases/tag/v1.0.0")
        #expect(info.assets.count == 4)
    }

    /// 最新 Release 是 Windows 版（`win-v*`）时抛出的错误要求改取列表；其他解析错误不要求。
    @Test func windowsLatestNeedsListFallback() throws {
        let windows = UpdateFixtures.feedJSON(["tag_name": "win-v0.1.0"])
        do {
            _ = try ReleaseFeedParser.parse(windows, feed: production)
            Issue.record("win-v tag should not parse")
        } catch {
            #expect(ReleaseFeedParser.needsListFallback(error))
        }
        #expect(!ReleaseFeedParser.needsListFallback(.malformedFeed("html_url not accepted")))
        #expect(!ReleaseFeedParser.needsListFallback(.malformedFeed("missing tag_name")))
        #expect(!ReleaseFeedParser.needsListFallback(.httpStatus(500)))
    }

    /// 列表里混有 Windows 版、草稿、预发布与新旧两个仓库名时，挑出版本号最高的 macOS 正式版。
    @Test func listFallbackPicksHighestMacRelease() throws {
        let list = Self.listJSON([
            Self.item("win-v0.2.0"),
            Self.item("v1.3.2", draft: true),
            Self.item("v1.4.0-beta.1", prerelease: true),
            Self.item("v1.3.0"),
            Self.item("v1.3.1", repository: "eve-o-preview"),
            Self.item("win-v9.0.0"),
        ])
        let info = try ReleaseFeedParser.parseLatestFromList(list, feed: production)
        #expect(info.version == "1.3.1")
        #expect(info.pageURL == "https://github.com/deletexiumu/eve-o-preview/releases/tag/v1.3.1")
        #expect(info.assets.map(\.name) == ["EVE-O-Preview-1.3.1.dmg", "SHA256SUMS.txt"])
    }

    /// 单项的地址不被接受时只跳过这一项；整个列表没有可用的 macOS 正式版时抛 malformedFeed。
    @Test func listFallbackSkipsBadItemsAndFailsWhenEmpty() throws {
        let mixed = Self.listJSON([Self.item("v1.5.0", repository: "someone-else"), Self.item("v1.2.2")])
        #expect(try ReleaseFeedParser.parseLatestFromList(mixed, feed: production).version == "1.2.2")

        let onlyWindows = Self.listJSON([Self.item("win-v0.1.0"), Self.item("win-v0.2.0")])
        #expect(throws: UpdateError.malformedFeed("no release with a version tag in list")) {
            try ReleaseFeedParser.parseLatestFromList(onlyWindows, feed: production)
        }
        #expect(throws: UpdateError.malformedFeed("release list is not an array")) {
            try ReleaseFeedParser.parseLatestFromList(Data("{}".utf8), feed: production)
        }
        #expect(throws: UpdateError.malformedFeed("not JSON")) {
            try ReleaseFeedParser.parseLatestFromList(Data("nope".utf8), feed: production)
        }
    }

    /// Release 列表每页 100 条，与正式地址的 `per_page` 一致。
    @Test func historyPageHoldsOneHundred() {
        #expect(ReleaseHistory.pageSize == 100)
        #expect(UpdateFeed.productionHistoryURL.absoluteString.hasSuffix("/releases?per_page=100"))
    }

    /// 1.3.2 起（仓库已改名）正式地址与默认发布页用新名字，改名前的附件与发布页地址仍然接受。
    @Test func productionUsesNewNameAndKeepsLegacy() {
        #expect(UpdateFeed.productionAssetPrefix == "https://github.com/deletexiumu/eve-o-preview/releases/")
        #expect(UpdateFeed.legacyAssetPrefix == "https://github.com/deletexiumu/eve-o-preview-macos/releases/")
        #expect(production.accepts(UpdateFeed.productionAssetPrefix + "download/v1.3.2/EVE-O-Preview-1.3.2.dmg"))
        #expect(production.accepts(UpdateFeed.legacyAssetPrefix + "download/v1.3.1/EVE-O-Preview-1.3.1.dmg"))
    }

    // MARK: - 样例

    /// 列表接口里的一项。repository 是仓库名，附件为 dmg 与校验和文件。
    private static func item(_ tag: String, draft: Bool = false, prerelease: Bool = false,
                             repository: String = "eve-o-preview-macos") -> [String: Any] {
        let base = "https://github.com/deletexiumu/\(repository)/releases/"
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return [
            "tag_name": tag, "name": "EVE-O Preview \(tag)", "draft": draft, "prerelease": prerelease,
            "html_url": base + "tag/\(tag)", "body": "notes for \(tag)",
            "assets": [
                ["name": "EVE-O-Preview-\(version).dmg", "size": 100,
                 "browser_download_url": base + "download/\(tag)/EVE-O-Preview-\(version).dmg"],
                ["name": "SHA256SUMS.txt", "size": 10, "browser_download_url": base + "download/\(tag)/SHA256SUMS.txt"],
            ],
        ]
    }

    /// 把若干项编码成列表接口的答复。
    private static func listJSON(_ items: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: items)) ?? Data()
    }
}
