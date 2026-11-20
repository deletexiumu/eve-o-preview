// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdateFeed 的用例（v1.1 设计 8.4 节的 `UpdateFeed` 规则、14.1 节）。

import Foundation
import Testing
import EVEOPreviewCore

/// 检查地址的选取与附件地址的校验。
struct UpdateFeedTests {
    /// 正式地址。
    private let production = UpdateFeed.resolve(override: nil)

    /// 没有覆盖值（nil 或空串）时用正式地址。
    @Test func noOverrideUsesProduction() {
        #expect(production == UpdateFeed(feedURL: UpdateFeed.productionURL, isTestFeed: false))
        #expect(UpdateFeed.resolve(override: "") == production)
        #expect(UpdateFeed.productionURL.absoluteString
            == "https://api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest")
    }

    /// https 地址与回环主机的 http 地址被接受，成为测试地址。
    @Test(arguments: ["https://example.com/feed.json", "http://127.0.0.1:8123/feed.json",
                      "http://localhost/feed.json", "http://[::1]:8123/feed.json", "HTTP://LOCALHOST:9/f.json"])
    func acceptedOverrides(text: String) throws {
        let feed = UpdateFeed.resolve(override: text)
        #expect(feed.isTestFeed)
        #expect(feed.feedURL == URL(string: text))
    }

    /// 别的主机的 http、别的协议、不是地址的字符串被忽略，用正式地址。
    @Test(arguments: ["http://example.com/feed.json", "ftp://127.0.0.1/feed.json", "not a url", "127.0.0.1:8123",
                      "http://127.0.0.2/feed.json", "file:///tmp/feed.json"])
    func rejectedOverrides(text: String) {
        #expect(UpdateFeed.resolve(override: text) == production)
    }

    /// 正式地址下只认本仓库 Release 路径下的地址。
    @Test func productionAcceptsOnlyRepositoryReleases() {
        #expect(production.accepts("https://github.com/deletexiumu/eve-o-preview-macos/releases/download/v1.1.1/EVE-O-Preview-1.1.1.dmg"))
        #expect(production.accepts("https://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.1.1"))
        #expect(!production.accepts("https://github.com/someone/eve-o-preview-macos/releases/tag/v1.1.1"))
        #expect(!production.accepts("https://github.com/deletexiumu/eve-o-preview-macos-fork/releases/tag/v1"))
        #expect(!production.accepts("https://example.com/deletexiumu/eve-o-preview-macos/releases/x.dmg"))
        #expect(!production.accepts("http://github.com/deletexiumu/eve-o-preview-macos/releases/x.dmg"))
        #expect(!production.accepts("https://github.com/deletexiumu/eve-o-preview-macos/issues/1"))
    }

    /// 测试地址下只认同源（协议、主机、端口都相同）的地址。
    @Test func testFeedAcceptsSameOriginOnly() {
        let feed = UpdateFeed.resolve(override: "http://127.0.0.1:8123/feed.json")
        #expect(feed.accepts("http://127.0.0.1:8123/EVE-O-Preview-1.1.1.dmg"))
        #expect(feed.accepts("HTTP://127.0.0.1:8123/sub/SHA256SUMS.txt"))
        #expect(!feed.accepts("http://127.0.0.1:8124/EVE-O-Preview-1.1.1.dmg"))
        #expect(!feed.accepts("http://localhost:8123/EVE-O-Preview-1.1.1.dmg"))
        #expect(!feed.accepts("https://127.0.0.1:8123/EVE-O-Preview-1.1.1.dmg"))
        #expect(!feed.accepts("https://github.com/deletexiumu/eve-o-preview-macos/releases/x.dmg"))
        #expect(!feed.accepts("not a url"))
    }

    /// 省略端口时按协议的默认端口比较；IPv6 回环同源。
    @Test func defaultPortsAndIPv6() {
        let https = UpdateFeed.resolve(override: "https://example.com/feed.json")
        #expect(https.accepts("https://example.com:443/a.dmg"))
        #expect(!https.accepts("https://example.com:8443/a.dmg"))
        let http = UpdateFeed.resolve(override: "http://localhost/feed.json")
        #expect(http.accepts("http://localhost:80/a.dmg"))
        let ipv6 = UpdateFeed.resolve(override: "http://[::1]:8123/feed.json")
        #expect(ipv6.accepts("http://[::1]:8123/a.dmg"))
        #expect(!ipv6.accepts("http://127.0.0.1:8123/a.dmg"))
    }
}
