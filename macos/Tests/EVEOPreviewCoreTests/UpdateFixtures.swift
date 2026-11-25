// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新相关用例共用的样例（v1.1 设计 14.1 节）。
// 校验和样例是 `shasum -a 256 -- *.dmg *.tar.gz *.zip`（package-release.sh 第 5 步的命令）的真实输出格式。

import Foundation
import EVEOPreviewCore

/// 更新用例的样例。
enum UpdateFixtures {
    /// 正式地址。
    static let productionFeed = UpdateFeed.resolve(override: nil)
    /// 本地测试地址。
    static let testFeed = UpdateFeed.resolve(override: "http://127.0.0.1:8123/update-manifest.json")

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
