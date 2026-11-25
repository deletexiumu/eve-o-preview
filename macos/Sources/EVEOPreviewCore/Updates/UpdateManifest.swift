// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新清单的验签与解析（docs/update-manifest.md 第 2、4 节）。Windows 的 eveo-core/src/update/manifest.rs
// 按同样的规则实现，两端用 shared/fixtures/update-manifest/ 的样例核对（UpdateManifestTests）。
//
// 清单是一个签名信封：`{"format": 1, "payload": "<正文的 base64>", "signature": "<ed25519 签名的 base64>"}`。
// 签名的消息是 `UpdateSigning.prefix` 接上正文的原始字节。先验签再解析正文，验不过的正文一个字段都不看。
//
// 正文里与本平台有关的部分：
// - `latest.<平台>`：改动了本平台的最新正式版，转成 ReleaseInfo。版本号要能解析；发布页要通过 `feed.accepts`
//   （GitHub 的发布页规则）；每个文件都要有正数的 `size` 与 64 位十六进制的 `sha256`，地址只留通过
//   `feed.acceptsAsset` 的，一个都不剩时整份清单不收（文件下不来，提示了也装不上）。第一个地址作下载地址，其余作后备。
// - `releases`：各版本的平台与说明。缺字段或类型不对的项跳过，不影响整份清单。
// 不认识的字段一律忽略：以后加字段不用改 schema（第 2.3 节）。

import CryptoKit
import Foundation

/// 清单里的一个版本：版本号、改动了哪些平台、发布说明的原文。
public struct UpdateManifestEntry: Sendable, Equatable {
    /// 规范写法的版本号，如 `1.4.1`。
    public var version: String
    /// 改动了的平台，如 `["windows"]`。
    public var platforms: [String]
    /// 发布说明原文，最多 65,536 个字符。
    public var notes: String
}

/// 验过签、解析好的清单（只含一个平台需要的部分）。
public struct UpdateManifest: Sendable, Equatable {
    /// 清单的文件名。
    public static let fileName = "update-manifest.json"
    /// 清单文件的上限：1 MiB。发布流程把它控制在 512 KiB 以内，这里留一倍余量。
    public static let maxBytes = 1_048_576
    /// 本平台在清单里的键。
    public static let ownPlatform = "macos"
    /// 信封的格式号；别的值都不收。
    static let format = 1
    /// 正文的 schema；别的值都不收。
    static let schema = 1
    /// SHA-256 的十六进制长度。
    static let sha256HexLength = 64

    /// 清单的序号；应用记下接受过的最大值，拒收更小的（防止旧清单被重放）。
    public var sequence: UInt64
    /// 改动了这个平台的最新正式版；清单里没有这个平台时是 nil。
    public var latest: ReleaseInfo?
    /// 各版本，保持清单里的顺序（新版在前）。
    public var entries: [UpdateManifestEntry]

    /// 改动了 platform 的各版本的说明，供 `ReleaseHistory.record` 挑出中间版本。
    /// 清单已含全部需要的版本（最多 20 个），所以 `isFull` 为假：不提示「更早的版本请看发布页」。
    public func historyPage(platform: String = ownPlatform) -> ReleaseHistoryPage {
        let entries = entries.filter { $0.platforms.contains(platform) }
            .map { ReleaseNotesEntry(version: $0.version, notes: $0.notes) }
        return ReleaseHistoryPage(entries: entries, isFull: false)
    }

    /// 验签并解析一份清单，取出 platform 的部分。任何一步不符合规则都抛 `malformedFeed`（原因是英文短语）。
    public static func open(_ data: Data, publicKey: Curve25519.Signing.PublicKey, feed: UpdateFeed,
                            platform: String = ownPlatform) throws(UpdateError) -> UpdateManifest {
        guard data.count <= maxBytes else { throw .malformedFeed("manifest larger than 1 MiB") }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformedFeed("manifest is not a JSON object")
        }
        guard integer(envelope["format"]) == Int64(format) else { throw .malformedFeed("unsupported manifest format") }
        guard let payload = (envelope["payload"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw .malformedFeed("manifest payload is not base64")
        }
        guard let signature = (envelope["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
              publicKey.isValidSignature(signature, for: UpdateSigning.message(for: payload)) else {
            throw .malformedFeed("manifest signature invalid")
        }
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw .malformedFeed("manifest payload is not a JSON object")
        }
        return try parse(root, feed: feed, platform: platform)
    }

    /// 解析验过签的正文。
    static func parse(_ root: [String: Any], feed: UpdateFeed, platform: String) throws(UpdateError) -> UpdateManifest {
        guard integer(root["schema"]) == Int64(schema) else { throw .malformedFeed("unsupported manifest schema") }
        guard let rawSequence = integer(root["sequence"]), rawSequence >= 0 else {
            throw .malformedFeed("manifest sequence missing")
        }
        guard let releases = root["releases"] as? [Any] else { throw .malformedFeed("manifest releases missing") }
        let entries = releases.compactMap(entry(from:))
        guard let latestTable = root["latest"] as? [String: Any] else { throw .malformedFeed("manifest latest missing") }
        var latest: ReleaseInfo?
        if let value = latestTable[platform] { latest = try release(from: value, entries: entries, feed: feed) }
        return UpdateManifest(sequence: UInt64(rawSequence), latest: latest, entries: entries)
    }

    /// releases 里的一项；缺字段或类型不对、版本号解析不了时返回 nil。
    static func entry(from value: Any) -> UpdateManifestEntry? {
        guard let object = value as? [String: Any],
              let version = (object["version"] as? String).flatMap(SemanticVersion.init),
              let rawPlatforms = object["platforms"] as? [Any],
              let notes = object["notes"] as? String else { return nil }
        let platforms = rawPlatforms.compactMap { $0 as? String }
        guard platforms.count == rawPlatforms.count else { return nil }
        return UpdateManifestEntry(version: version.description, platforms: platforms,
                                   notes: String(notes.prefix(ReleaseFeedParser.maxNotesCharacters)))
    }

    /// `latest.<平台>` 转成发布信息。不合规则时整份清单不收：这一项是要安装的版本，不能带着坏数据往下走。
    static func release(from value: Any, entries: [UpdateManifestEntry],
                        feed: UpdateFeed) throws(UpdateError) -> ReleaseInfo {
        guard let object = value as? [String: Any] else { throw .malformedFeed("latest is not an object") }
        guard let version = (object["version"] as? String).flatMap(SemanticVersion.init) else {
            throw .malformedFeed("latest version is not a version")
        }
        guard let tag = object["tag"] as? String else { throw .malformedFeed("latest tag missing") }
        guard let page = object["pageURL"] as? String, feed.accepts(page) else {
            throw .malformedFeed("latest pageURL not accepted")
        }
        guard let files = object["files"] as? [Any] else { throw .malformedFeed("latest files missing") }
        var assets: [ReleaseAsset] = []
        for file in files { assets.append(try asset(from: file, feed: feed)) }
        // 说明取 releases 里同一版本的那一项；没有时为空（窗口只显示标题）。
        let notes = entries.first { SemanticVersion($0.version) == version }?.notes ?? ""
        return ReleaseInfo(version: version.description, tagName: tag, title: "EVE-O Preview \(version.description)",
                           notes: notes, pageURL: page, publishedAt: nil, isPrerelease: false, isDraft: false,
                           assets: assets)
    }

    /// files 里的一个文件。名字、正数的大小与 SHA-256 都必须有；地址只留通过 `acceptsAsset` 的，至少要剩一个。
    static func asset(from value: Any, feed: UpdateFeed) throws(UpdateError) -> ReleaseAsset {
        guard let object = value as? [String: Any] else { throw .malformedFeed("file is not an object") }
        guard let name = object["name"] as? String, !name.isEmpty,
              !name.contains("/"), !name.contains("\\") else { throw .malformedFeed("file name missing") }
        guard let size = integer(object["size"]), size > 0, size <= Int64(Int.max) else {
            throw .malformedFeed("file size missing")
        }
        guard let hash = object["sha256"] as? String, hash.utf8.count == sha256HexLength,
              hash.utf8.allSatisfy({ $0.isASCIIHexDigit }) else { throw .malformedFeed("file sha256 missing") }
        guard let rawURLs = object["urls"] as? [Any] else { throw .malformedFeed("file urls missing") }
        let urls = rawURLs.compactMap { $0 as? String }.filter(feed.acceptsAsset)
        guard let first = urls.first else { throw .malformedFeed("file has no usable url") }
        return ReleaseAsset(name: name, downloadURL: first, size: Int(size), sha256: hash.lowercased(),
                            mirrors: Array(urls.dropFirst()))
    }

    /// JSON 里的整数：不是布尔值、没有小数部分时返回它，否则返回 nil。
    /// `JSONSerialization` 把 `true` 也解成 NSNumber（值是 1），所以先排除布尔值。
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return number.doubleValue == Double(integer) ? integer : nil
    }
}

/// 验签用的公钥与消息（docs/update-manifest.md 第 2.1 节）。
public enum UpdateSigning {
    /// 签名消息的前缀，与 scripts/build_update_manifest.py 相同：把清单的签名与 `SHA256SUMS.txt.sig` 区分开。
    public static let prefix = Data("eveo-update-manifest-v1\n".utf8)
    /// 正式的公钥（32 字节 ed25519，十六进制）。与 windows/packaging/update-public-key.txt 相同，由用例核对。
    public static let productionPublicKeyHex = "08b57d6500c28cce85d428dd6e31345f9ad2be73e3742fbc3a55bee14399e13a"
    /// 测试公钥的环境变量：只在测试地址下生效，正式地址下忽略。
    public static let testPublicKeyVariable = "EVEO_UPDATE_TEST_PUBLIC_KEY"

    /// 签名的消息：前缀接上正文的原始字节。
    public static func message(for payload: Data) -> Data {
        prefix + payload
    }

    /// 检查要用的公钥。正式地址下用 `productionPublicKeyHex`；测试地址下用环境变量 `EVEO_UPDATE_TEST_PUBLIC_KEY`，
    /// 没设或不是 64 位十六进制时返回 nil（这时测试地址的检查失败）。
    public static func publicKey(for feed: UpdateFeed,
                                 environment: [String: String]) -> Curve25519.Signing.PublicKey? {
        let hex = feed.isTestFeed ? environment[testPublicKeyVariable] : productionPublicKeyHex
        return hex.flatMap(publicKey(hex:))
    }

    /// 十六进制的公钥；长度不对或不是十六进制时返回 nil。
    public static func publicKey(hex: String) -> Curve25519.Signing.PublicKey? {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 64 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    }
}

extension UInt8 {
    /// 是不是 ASCII 的十六进制数字（0-9、a-f、A-F）。
    var isASCIIHexDigit: Bool {
        (0x30...0x39).contains(self) || (0x41...0x46).contains(self) || (0x61...0x66).contains(self)
    }
}
