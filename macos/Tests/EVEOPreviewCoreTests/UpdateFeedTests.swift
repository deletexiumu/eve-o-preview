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

    /// 没有覆盖值（nil 或空串）时用正式地址：两个清单源，R2 的 CDN 在前、GitHub 在后。
    @Test func noOverrideUsesProduction() {
        #expect(UpdateFeed.resolve(override: "") == production)
        #expect(!production.isTestFeed)
        #expect(production.manifestURLs.map(\.absoluteString) == [
            "https://eveo.deepai.wiki/update-manifest.json",
            "https://github.com/deletexiumu/eve-o-preview/releases/latest/download/update-manifest.json",
        ])
        #expect(production.feedURL == production.manifestURLs[0])
    }

    /// 测试地址只有它自己一个清单源。
    @Test func testFeedHasSingleSource() {
        let feed = UpdateFeed.resolve(override: "http://127.0.0.1:8123/update-manifest.json")
        #expect(feed.manifestURLs.map(\.absoluteString) == ["http://127.0.0.1:8123/update-manifest.json"])
    }

    /// 正式地址下清单里的附件：干净的 https 都可以（R2、GitHub），http、带用户信息、反斜杠、控制字符不可以。
    @Test func productionAssetRules() {
        #expect(production.acceptsAsset("https://eveo.deepai.wiki/v1.5.0/EVE-O-Preview-1.5.0.dmg"))
        #expect(production.acceptsAsset(UpdateFeed.productionAssetPrefix + "download/v1.5.0/SHA256SUMS.txt"))
        #expect(production.acceptsAsset("https://dl.example.com:8443/a.dmg"))
        #expect(!production.acceptsAsset("http://eveo.deepai.wiki/v1.5.0/a.dmg"))
        #expect(!production.acceptsAsset("https://user:pass@eveo.deepai.wiki/a.dmg"))
        #expect(!production.acceptsAsset("https://eveo.deepai.wiki\\@evil.com/a.dmg"))
        #expect(!production.acceptsAsset("https://eveo.deepai.wiki/a\n.dmg"))
        #expect(!production.acceptsAsset("ftp://eveo.deepai.wiki/a.dmg"))
        #expect(!production.acceptsAsset("not a url"))
        #expect(!production.acceptsAsset(""))
        // 发布页仍只认 GitHub 的 Release 地址。
        #expect(!production.accepts("https://eveo.deepai.wiki/v1.5.0/EVE-O-Preview-1.5.0.dmg"))
    }

    /// 测试地址下附件仍要与清单同源。
    @Test func testFeedAssetRules() {
        let feed = UpdateFeed.resolve(override: "http://127.0.0.1:8123/update-manifest.json")
        #expect(feed.acceptsAsset("http://127.0.0.1:8123/EVE-O-Preview-1.5.0.dmg"))
        #expect(!feed.acceptsAsset("https://eveo.deepai.wiki/v1.5.0/EVE-O-Preview-1.5.0.dmg"))
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

    /// 正式地址下，前缀对但路径能跳出 Release 目录、编码过的点与斜杠、反斜杠、别的端口都不认。
    @Test(arguments: [
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/../../../evil/repo/releases/download/v1/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/download/../../../../evil/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/./download/v1/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/..",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/%2e%2e/%2e%2e/evil/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/%2E%2E/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/.%2e/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/%2f..%2fevil/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/download\\..\\..\\evil/x.dmg",
        "https://github.com/deletexiumu/eve-o-preview-macos/releases/%5c../x.dmg",
        "https://github.com:8443/deletexiumu/eve-o-preview-macos/releases/x.dmg",
        "https://api.github.com/deletexiumu/eve-o-preview-macos/releases/x.dmg",
        "https://objects.githubusercontent.com/deletexiumu/eve-o-preview-macos/releases/x.dmg",
        "https://github.com.evil.com/deletexiumu/eve-o-preview-macos/releases/x.dmg",
        "",
    ])
    func productionRejectsTraversal(text: String) {
        #expect(!production.accepts(text))
    }

    /// 正式地址下：查询串、显式的 443 端口、文件名里普通的点不影响结果；大写的主机不在前缀里，不认。
    @Test func productionEdgeCases() {
        let base = "https://github.com/deletexiumu/eve-o-preview-macos/releases/"
        #expect(production.accepts(base + "download/v1.1.0/EVE-O-Preview-1.1.0.dmg?raw=1"))
        #expect(production.accepts(base + "download/v1.1.0/SHA256SUMS.txt"))
        #expect(production.accepts(base + "tag/v1.1.0"))
        #expect(production.accepts(base + "latest"))
        #expect(!production.accepts("https://GITHUB.com/deletexiumu/eve-o-preview-macos/releases/tag/v1"))
        #expect(!production.accepts("https://github.com:443/deletexiumu/eve-o-preview-macos/releases/tag/v1"))
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
