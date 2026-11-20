// SPDX-License-Identifier: GPL-3.0-or-later
//
// ReleaseFeedParser 的用例（v1.1 设计 8.4 节、14.1 节）。

import Foundation
import Testing
import EVEOPreviewCore

/// 发布信息的解析与限流判断。
struct ReleaseFeedParserTests {
    private let feed = UpdateFixtures.productionFeed

    /// GitHub 答复的样例：各字段取到，附件全部保留（都在本仓库的 Release 路径下）。
    @Test func parsesGitHubSample() throws {
        let info = try ReleaseFeedParser.parse(Data(UpdateFixtures.githubLatest.utf8), feed: feed)
        #expect(info.version == "1.0.0")
        #expect(info.tagName == "v1.0.0")
        #expect(info.title == "EVE-O Preview for macOS v1.0.0")
        #expect(info.pageURL == "https://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.0.0")
        #expect(info.notes == "<!-- lang:en -->\nFirst release.\n<!-- /lang:en -->")
        #expect(info.publishedAt == ISO8601DateFormatter().date(from: "2026-11-20T16:26:38Z"))
        #expect(!info.isDraft && !info.isPrerelease)
        #expect(info.assets.map(\.name) == ["EVE-O-Preview-1.0.0.dmg", "eve-o-preview-macos-1.0.0-source.tar.gz",
                                            "eve-o-preview-macos-1.0.0-source.zip", "SHA256SUMS.txt"])
        #expect(info.assets.last?.size == 299)
    }

    /// 缺 body 或 body 为 null 时取空串；缺 name 时标题取 tag。
    @Test func missingBodyAndName() throws {
        let noBody = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["body": NSNull()]), feed: feed)
        #expect(noBody.notes == "")
        let nullBody = try ReleaseFeedParser.parse(Data(#"{"tag_name":"v1.0.0","body":null,"name":null,"html_url":"https://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.0.0"}"#.utf8), feed: feed)
        #expect(nullBody.notes == "")
        #expect(nullBody.title == "v1.0.0")
        #expect(nullBody.assets.isEmpty)
        #expect(nullBody.publishedAt == nil)
    }

    /// tag_name 缺失或不是版本号时抛 malformedFeed；version 取规范写法。
    @Test func tagName() throws {
        for bad: Any in ["latest", "1.0", NSNull(), 7] {
            #expect(throws: UpdateError.self) {
                try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["tag_name": bad]), feed: feed)
            }
        }
        let beta = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["tag_name": "V1.2.0-beta.1"]), feed: feed)
        #expect(beta.version == "1.2.0-beta.1")
        #expect(beta.tagName == "V1.2.0-beta.1")
    }

    /// html_url 指向别的仓库、别的主机或不是字符串时抛 malformedFeed。
    @Test(arguments: ["https://github.com/someone/eve-o-preview-macos/releases/tag/v1.0.0",
                      "https://example.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.0.0",
                      "http://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.0.0"])
    func foreignPageURL(url: String) {
        #expect(throws: UpdateError.malformedFeed("html_url not accepted")) {
            try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["html_url": url]), feed: feed)
        }
    }

    /// 附件地址不合格时只丢掉这个附件；缺字段的附件也丢掉。
    @Test func dropsUnacceptedAssets() throws {
        let prefix = UpdateFeed.productionAssetPrefix + "download/v1.0.0/"
        let assets: [[String: Any]] = [
            ["name": "EVE-O-Preview-1.0.0.dmg", "browser_download_url": "https://evil.example/x.dmg", "size": 1],
            ["name": "SHA256SUMS.txt", "browser_download_url": prefix + "SHA256SUMS.txt", "size": 2],
            ["name": "no-url.txt", "size": 3],
            ["browser_download_url": prefix + "no-name.txt"],
        ]
        let info = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["assets": assets]), feed: feed)
        #expect(info.assets == [ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: prefix + "SHA256SUMS.txt", size: 2)])
    }

    /// 附件多于 100 个时只看前 100 个。
    @Test func assetLimit() throws {
        let prefix = UpdateFeed.productionAssetPrefix + "download/v1.0.0/"
        let assets = (0..<150).map { ["name": "a\($0)", "browser_download_url": prefix + "a\($0)"] }
        let info = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["assets": assets]), feed: feed)
        #expect(info.assets.count == 100)
        #expect(info.assets.last?.name == "a99")
    }

    /// 测试地址下附件应与检查地址同源。
    @Test func testFeedSameOrigin() throws {
        let test = UpdateFixtures.testFeed
        let assets: [[String: Any]] = [
            ["name": "EVE-O-Preview-1.1.1.dmg", "browser_download_url": "http://127.0.0.1:8123/EVE-O-Preview-1.1.1.dmg"],
            ["name": "SHA256SUMS.txt", "browser_download_url": "http://localhost:8123/SHA256SUMS.txt"],
        ]
        let info = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON([
            "tag_name": "v1.1.1", "html_url": "http://127.0.0.1:8123/", "assets": assets,
        ]), feed: test)
        #expect(info.assets.map(\.name) == ["EVE-O-Preview-1.1.1.dmg"])
    }

    /// 超长的正文截短到 65,536 个字符。
    @Test func truncatesLongNotes() throws {
        let long = String(repeating: "é", count: 70_000)
        let info = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["body": long]), feed: feed)
        #expect(info.notes.count == ReleaseFeedParser.maxNotesCharacters)
        #expect(ReleaseFeedParser.maxNotesCharacters == 65_536)
    }

    /// 不是 JSON、顶层不是对象、超过 1 MiB 时抛 malformedFeed。
    @Test func malformedBodies() {
        #expect(throws: UpdateError.malformedFeed("not JSON")) {
            try ReleaseFeedParser.parse(Data("<html>".utf8), feed: feed)
        }
        #expect(throws: UpdateError.malformedFeed("top level is not an object")) {
            try ReleaseFeedParser.parse(Data("[1,2]".utf8), feed: feed)
        }
        let huge = Data(count: ReleaseFeedParser.maxFeedBytes + 1)
        #expect(throws: UpdateError.malformedFeed("response larger than 1 MiB")) {
            try ReleaseFeedParser.parse(huge, feed: feed)
        }
        #expect(ReleaseFeedParser.maxFeedBytes == 1_048_576)
    }

    /// draft 与 prerelease 原样取出（是否提示由 UpdatePolicy 决定）。
    @Test func draftAndPrereleaseFlags() throws {
        let info = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["draft": true, "prerelease": true]), feed: feed)
        #expect(info.isDraft && info.isPrerelease)
    }

    /// published_at 带小数秒也能解析，解析不了时是 nil。
    @Test func publishedAtFormats() throws {
        let fractional = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["published_at": "2026-11-20T16:26:38.5Z"]),
                                                     feed: feed)
        #expect(fractional.publishedAt != nil)
        let bad = try ReleaseFeedParser.parse(UpdateFixtures.feedJSON(["published_at": "yesterday"]), feed: feed)
        #expect(bad.publishedAt == nil)
    }

    // MARK: - 限流

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 403 加 x-ratelimit-remaining: 0：时刻取 x-ratelimit-reset。
    @Test func forbiddenWithZeroRemaining() {
        let result = ReleaseFeedParser.rateLimit(status: 403, headers: ["x-ratelimit-remaining": "0",
                                                                        "x-ratelimit-reset": "1800001234"], now: now)
        #expect(result == .rateLimited(until: Date(timeIntervalSince1970: 1_800_001_234)))
    }

    /// 429 加 retry-after：时刻是现在加 retry-after 秒。
    @Test func tooManyRequestsWithRetryAfter() {
        let result = ReleaseFeedParser.rateLimit(status: 429, headers: ["retry-after": "120"], now: now)
        #expect(result == .rateLimited(until: now.addingTimeInterval(120)))
    }

    /// 两个时刻头都有时先看 retry-after；都没有时取现在加 1 小时。
    @Test func precedenceAndDefault() {
        let both = ReleaseFeedParser.rateLimit(status: 403, headers: ["x-ratelimit-remaining": "0", "retry-after": "60",
                                                                      "x-ratelimit-reset": "1900000000"], now: now)
        #expect(both == .rateLimited(until: now.addingTimeInterval(60)))
        let neither = ReleaseFeedParser.rateLimit(status: 403, headers: ["x-ratelimit-remaining": "0"], now: now)
        #expect(neither == .rateLimited(until: now.addingTimeInterval(3_600)))
    }

    /// 普通 403（还有额度、没有 retry-after）、200、404 不是限流。
    @Test func notRateLimited() {
        #expect(ReleaseFeedParser.rateLimit(status: 403, headers: ["x-ratelimit-remaining": "12"], now: now) == nil)
        #expect(ReleaseFeedParser.rateLimit(status: 403, headers: [:], now: now) == nil)
        #expect(ReleaseFeedParser.rateLimit(status: 200, headers: ["x-ratelimit-remaining": "0"], now: now) == nil)
        #expect(ReleaseFeedParser.rateLimit(status: 404, headers: ["retry-after": "5"], now: now) == nil)
    }
}
