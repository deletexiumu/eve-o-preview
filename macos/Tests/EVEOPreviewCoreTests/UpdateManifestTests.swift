// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新清单的用例（docs/update-manifest.md）。主要用 shared/fixtures/update-manifest/ 的样例（Windows 的
// eveo-core/src/update/manifest_tests.rs 用同一份核对）：有效的清单、两个平台各自的 latest、中间版本的挑选，
// 以及几份应当被拒收的变体。另有公钥、序号与测试地址的用例。

import CryptoKit
import Foundation
import Testing
import EVEOPreviewCore

/// 更新清单的验签与解析。
struct UpdateManifestTests {
    /// 仓库根目录：本文件在 macos/Tests/EVEOPreviewCoreTests，往上 4 级。
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// 读仓库里的一个文件。
    private static func file(_ relative: String) throws -> Data {
        let url = root.appendingPathComponent(relative)
        return try #require(try? Data(contentsOf: url), "找不到 \(url.path)")
    }

    /// 样例清单（签名信封的原文）。
    private static func manifest() throws -> Data {
        try file("shared/fixtures/update-manifest/manifest.json")
    }

    /// 样例的期望值。
    private static func cases() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try file("shared/fixtures/update-manifest/cases.json"))
        return try #require(object as? [String: Any])
    }

    /// 样例的测试公钥。
    private static func key() throws -> Curve25519.Signing.PublicKey {
        // #require 不能嵌套展开，先取出十六进制串再解析。
        let hex = try #require(try cases()["publicKey"] as? String)
        return try #require(UpdateSigning.publicKey(hex: hex))
    }

    /// 用正式地址的规则、测试公钥打开一份清单。
    private static func open(_ data: Data, platform: String = UpdateManifest.ownPlatform) throws -> UpdateManifest {
        try UpdateManifest.open(data, publicKey: try key(), feed: UpdateFixtures.productionFeed, platform: platform)
    }

    /// 两个平台的 latest 都与期望值一致：版本、tag、发布页、标题，以及每个文件的大小、SHA-256 与按顺序的地址。
    @Test(arguments: ["macos", "windows"])
    func sharedFixtureLatest(platform: String) throws {
        let cases = try Self.cases()
        let manifest = try Self.open(try Self.manifest(), platform: platform)
        #expect(manifest.sequence == (cases["sequence"] as? NSNumber)?.uint64Value)
        let expected = try #require((cases["latest"] as? [String: Any])?[platform] as? [String: Any])
        let latest = try #require(manifest.latest)
        #expect(latest.version == expected["version"] as? String)
        #expect(latest.tagName == expected["tag"] as? String)
        #expect(latest.pageURL == expected["pageURL"] as? String)
        #expect(latest.title == "EVE-O Preview \(latest.version)")
        // 说明取 releases 里同一版本的那一项。
        #expect(latest.notes.contains("Release \(latest.version)."))
        let files = try #require(expected["files"] as? [[String: Any]])
        #expect(latest.assets.count == files.count)
        for (asset, file) in zip(latest.assets, files) {
            #expect(asset.name == file["name"] as? String)
            #expect(asset.size == (file["size"] as? NSNumber)?.intValue)
            #expect(asset.sha256 == file["sha256"] as? String)
            #expect(asset.urls == file["urls"] as? [String])
        }
    }

    /// 中间版本：平台含本平台、且 running < v < latest，新版在前。
    @Test func sharedFixtureIntermediate() throws {
        let cases = try #require(try Self.cases()["intermediate"] as? [[String: Any]])
        for item in cases {
            let platform = try #require(item["platform"] as? String)
            let manifest = try Self.open(try Self.manifest(), platform: platform)
            let latestEntry = try #require(manifest.latest)
            let latest = try #require(SemanticVersion(latestEntry.version))
            let runningText = try #require(item["running"] as? String)
            let running = try #require(SemanticVersion(runningText))
            let record = ReleaseHistory.record(from: manifest.historyPage(platform: platform), running: running,
                                               latest: latest)
            #expect(record.entries.map(\.version) == item["versions"] as? [String], "\(item)")
            #expect(!record.hasMore)
        }
    }

    /// 应当被拒收的变体：正文被改、别的私钥、没有前缀、格式与 schema 不对、缺 SHA-256、不是 JSON。
    @Test func sharedFixtureInvalid() throws {
        let cases = try #require(try Self.cases()["invalid"] as? [[String: Any]])
        #expect(cases.count == 7)
        for item in cases {
            let envelope = try #require(item["envelope"] as? String)
            #expect(throws: UpdateError.self, "\(item["name"] ?? "")") {
                try Self.open(Data(envelope.utf8))
            }
        }
    }

    /// 清单里没有这个平台：latest 为空，中间版本也为空。
    @Test func unknownPlatformHasNoLatest() throws {
        let manifest = try Self.open(try Self.manifest(), platform: "linux")
        #expect(manifest.latest == nil)
        #expect(manifest.historyPage(platform: "linux").entries.isEmpty)
    }

    /// 测试地址下附件要与清单同源：样例里的正式地址全被丢掉，整份清单不收。
    /// 发布页地址在附件之前检查，样例的发布页也是正式地址，所以报的是发布页这一条（Windows 端同序）。
    @Test func testFeedRejectsForeignAssets() throws {
        let data = try Self.manifest()
        let key = try Self.key()
        #expect(throws: UpdateError.malformedFeed("latest pageURL not accepted")) {
            try UpdateManifest.open(data, publicKey: key, feed: UpdateFixtures.testFeed)
        }
    }

    /// 超过 1 MiB 的文件不解析；正式的公钥验不过测试私钥签的样例。
    @Test func oversizedAndWrongKey() throws {
        let key = try Self.key()
        #expect(throws: UpdateError.malformedFeed("manifest larger than 1 MiB")) {
            try UpdateManifest.open(Data(repeating: 0x20, count: UpdateManifest.maxBytes + 1), publicKey: key,
                                    feed: UpdateFixtures.productionFeed)
        }
        let production = try #require(UpdateSigning.publicKey(for: UpdateFixtures.productionFeed, environment: [:]))
        let data = try Self.manifest()
        #expect(throws: UpdateError.malformedFeed("manifest signature invalid")) {
            try UpdateManifest.open(data, publicKey: production, feed: UpdateFixtures.productionFeed)
        }
    }

    /// 内置的正式公钥与 windows/packaging/update-public-key.txt 相同（发布流程用它对应的私钥签名）。
    @Test func productionKeyMatchesRepository() throws {
        let text = String(decoding: try Self.file("windows/packaging/update-public-key.txt"), as: UTF8.self)
        #expect(UpdateSigning.productionPublicKeyHex == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(UpdateSigning.publicKey(hex: UpdateSigning.productionPublicKeyHex) != nil)
    }

    /// 测试公钥只在测试地址下生效；测试地址没设时没有公钥（检查失败），正式地址下忽略环境变量。
    @Test func publicKeySelection() throws {
        let hex = try #require(try Self.cases()["publicKey"] as? String)
        let environment = [UpdateSigning.testPublicKeyVariable: hex]
        let test = UpdateSigning.publicKey(for: UpdateFixtures.testFeed, environment: environment)
        // #expect 的比较闭包不能抛错，先在外面取出公钥。
        let expected = try Self.key()
        #expect(test?.rawRepresentation == expected.rawRepresentation)
        #expect(UpdateSigning.publicKey(for: UpdateFixtures.testFeed, environment: [:]) == nil)
        let production = UpdateSigning.publicKey(for: UpdateFixtures.productionFeed, environment: environment)
        #expect(production?.rawRepresentation
            == UpdateSigning.publicKey(hex: UpdateSigning.productionPublicKeyHex)?.rawRepresentation)
        #expect(UpdateSigning.publicKey(hex: "zz") == nil)
        #expect(UpdateSigning.publicKey(hex: String(repeating: "g", count: 64)) == nil)
    }

    /// 自己签一份清单：不认识的字段忽略；布尔值、小数不能当整数；缺地址或只有 http 地址的文件让整份清单不收。
    @Test func payloadRules() throws {
        let signer = Curve25519.Signing.PrivateKey()
        func open(_ payload: [String: Any]) throws -> UpdateManifest {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let signature = try signer.signature(for: UpdateSigning.message(for: body))
            let envelope = try JSONSerialization.data(withJSONObject: [
                "format": 1, "payload": body.base64EncodedString(), "signature": signature.base64EncodedString(),
                "extra": "ignored",
            ])
            return try UpdateManifest.open(envelope, publicKey: signer.publicKey, feed: UpdateFixtures.productionFeed)
        }
        let file: [String: Any] = ["name": "EVE-O-Preview-1.5.0.dmg", "size": 10, "sha256": String(repeating: "A", count: 64),
                                   "urls": ["http://plain.example.com/a.dmg", "https://eveo.deepai.wiki/v1.5.0/a.dmg"]]
        func payload(file: [String: Any], schema: Any = 1) -> [String: Any] {
            ["schema": schema, "sequence": 5, "future": ["x": 1],
             "latest": ["macos": ["version": "1.5.0", "tag": "v1.5.0",
                                  "pageURL": UpdateFeed.productionAssetPrefix + "tag/v1.5.0", "files": [file]]],
             "releases": [["version": "1.5.0", "platforms": ["macos"], "notes": "n"], ["version": "bad"]]]
        }
        let manifest = try open(payload(file: file))
        let asset = try #require(manifest.latest?.assets.first)
        // http 的地址被丢掉；SHA-256 转成小写。
        #expect(asset.urls == ["https://eveo.deepai.wiki/v1.5.0/a.dmg"])
        #expect(asset.sha256 == String(repeating: "a", count: 64))
        #expect(manifest.entries.map(\.version) == ["1.5.0"])
        #expect(throws: UpdateError.malformedFeed("unsupported manifest schema")) { try open(payload(file: file, schema: true)) }
        var noURL = file
        noURL["urls"] = ["http://plain.example.com/a.dmg"]
        #expect(throws: UpdateError.malformedFeed("file has no usable url")) { try open(payload(file: noURL)) }
        var fractional = file
        fractional["size"] = 1.5
        #expect(throws: UpdateError.malformedFeed("file size missing")) { try open(payload(file: fractional)) }
    }

    /// 说明的截短上限与 Windows 相同。
    @Test func notesLimit() {
        #expect(ReleaseFeedParser.maxNotesCharacters == 65_536)
        #expect(UpdateManifest.maxBytes == 1_048_576)
    }
}
