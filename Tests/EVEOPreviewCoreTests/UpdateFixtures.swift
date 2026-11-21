// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新相关用例共用的样例（v1.1 设计 14.1 节）。
// GitHub 答复取自 2026-11-21 对 `releases/latest` 的一次真实请求，只保留应用读取的字段，正文换成短的样例；
// 校验和样例是 `shasum -a 256 -- *.dmg *.tar.gz *.zip`（package-release.sh 第 5 步的命令）的真实输出格式。

import Foundation
import EVEOPreviewCore

/// 更新用例的样例。
enum UpdateFixtures {
    /// 正式地址。
    static let productionFeed = UpdateFeed.resolve(override: nil)
    /// 本地测试地址。
    static let testFeed = UpdateFeed.resolve(override: "http://127.0.0.1:8123/feed.json")

    /// GitHub `releases/latest` 的答复（v1.0.0）。
    static let githubLatest = """
    {
      "html_url": "https://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.0.0",
      "tag_name": "v1.0.0",
      "name": "EVE-O Preview for macOS v1.0.0",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-11-20T16:26:38Z",
      "body": "<!-- lang:en -->\\nFirst release.\\n<!-- /lang:en -->",
      "assets": [
        {"name": "EVE-O-Preview-1.0.0.dmg", "size": 4221880, "content_type": "application/x-apple-diskimage",
         "browser_download_url": "https://github.com/deletexiumu/eve-o-preview-macos/releases/download/v1.0.0/EVE-O-Preview-1.0.0.dmg"},
        {"name": "eve-o-preview-macos-1.0.0-source.tar.gz", "size": 808012, "content_type": "application/x-gtar",
         "browser_download_url": "https://github.com/deletexiumu/eve-o-preview-macos/releases/download/v1.0.0/eve-o-preview-macos-1.0.0-source.tar.gz"},
        {"name": "eve-o-preview-macos-1.0.0-source.zip", "size": 962085, "content_type": "application/zip",
         "browser_download_url": "https://github.com/deletexiumu/eve-o-preview-macos/releases/download/v1.0.0/eve-o-preview-macos-1.0.0-source.zip"},
        {"name": "SHA256SUMS.txt", "size": 299, "content_type": "text/plain; charset=utf-8",
         "browser_download_url": "https://github.com/deletexiumu/eve-o-preview-macos/releases/download/v1.0.0/SHA256SUMS.txt"}
      ]
    }
    """

    /// 按需改字段的答复：从 GitHub 样例出发，覆盖或删除（值为 NSNull 时删除）若干键。
    static func feedJSON(_ overrides: [String: Any]) -> Data {
        var object = (try? JSONSerialization.jsonObject(with: Data(githubLatest.utf8))) as? [String: Any] ?? [:]
        for (key, value) in overrides {
            if value is NSNull { object.removeValue(forKey: key) } else { object[key] = value }
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// package-release.sh 生成的 `SHA256SUMS.txt` 的格式（文本模式，两个空格）。
    static let packageScriptChecksums = """
    00cbbd0ddbda2762798f7009838ed34ca1f12b93965813c7df22943bc62166d1  EVE-O-Preview-1.1.1.dmg
    407f3ae627dafcf01abdcc6632da77b6a2ab73d22077e5c494a90c66329b5fb9  eve-o-preview-macos-1.1.1-source.tar.gz
    4a70fe9aa6436e02c2dea340fbd1e352e4ef2d8ce6ca52ad25d4b95471fc8bf2  eve-o-preview-macos-1.1.1-source.zip

    """

    /// 一个 64 位的十六进制串，用 c 重复填满。
    static func digest(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }

    /// 一个发布版。正式地址下的附件：dmg 与校验和文件。
    static func release(_ version: String, prerelease: Bool = false, draft: Bool = false,
                        assets: [ReleaseAsset]? = nil) -> ReleaseInfo {
        let prefix = UpdateFeed.productionAssetPrefix + "download/v\(version)/"
        let defaultAssets = [
            ReleaseAsset(name: "EVE-O-Preview-\(version).dmg", downloadURL: prefix + "EVE-O-Preview-\(version).dmg",
                         size: 2_618_184),
            ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: prefix + "SHA256SUMS.txt", size: 299),
        ]
        return ReleaseInfo(version: version, tagName: "v\(version)", title: "EVE-O Preview \(version)", notes: "",
                           pageURL: UpdateFeed.productionAssetPrefix + "tag/v\(version)", publishedAt: nil,
                           isPrerelease: prerelease, isDraft: draft, assets: assets ?? defaultAssets)
    }

    /// 一个运行环境。默认是装在「应用程序」里、发布证书签名的 1.1.0。
    static func environment(version: String = "1.1.0", label: String? = nil, kind: SignatureKind = .release,
                            location: InstallLocationKind = .applications, writable: Bool = true,
                            bundlePath: String? = "/Applications/EVE-O Preview.app") -> AppEnvironment {
        AppEnvironment(bundleIdentifier: "io.github.deletexiumu.eveopreview-macos", version: version,
                       buildLabel: label ?? version, buildCommit: "abc1234",
                       bundlePath: location == .notBundled ? nil : bundlePath, executableName: "EVEOPreview",
                       signature: CodeSignatureInfo(kind: kind, signerName: nil,
                                                    designatedRequirement: "identifier \"x\""),
                       location: location, isLocationWritable: writable)
    }
}
