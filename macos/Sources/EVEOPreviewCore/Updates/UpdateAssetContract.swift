// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布契约里应用用到的名字与上限（v1.1 设计 8.1 节、9.2 节）。CI 与应用按这些名字对接：
// 改动任何一项，已安装的版本就只能提示更新、不能自动安装。测试用例把名字写死，改名时测试会先失败。
// 要换名字时，新旧两个名字的附件应并存至少一个正式版。

import Foundation

/// 安装包、校验和文件与应用包的名字，以及下载的上限。
public enum UpdateAssetContract {
    /// 校验和文件的附件名。
    public static let checksumsName = "SHA256SUMS.txt"
    /// dmg 卷顶层的应用包名。
    public static let appBundleName = "EVE-O Preview.app"
    /// dmg 的大小上限：300 MiB。
    public static let maxImageBytes = 314_572_800
    /// 校验和文件的大小上限：65,536 字节。
    public static let maxChecksumsBytes = 65_536

    /// 安装包的附件名：`EVE-O-Preview-<版本号>.dmg`。
    public static func imageName(version: String) -> String {
        "EVE-O-Preview-\(version).dmg"
    }

    /// 从发布信息里取 dmg 与校验和文件两个附件。名字按大小写完全相等匹配。
    ///
    /// 缺任何一个时抛 `assetMissing`，关联值是缺的附件名（两个都缺时报 dmg）。
    /// 首选地址不通过 `feed.acceptsAsset` 时按缺失处理（解析清单时已经丢掉了，这里再核对一次）。
    public static func assets(in release: ReleaseInfo, feed: UpdateFeed) throws(UpdateError)
        -> (image: ReleaseAsset, checksums: ReleaseAsset) {
        let imageName = imageName(version: release.version)
        func find(_ name: String) -> ReleaseAsset? {
            release.assets.first { $0.name == name && feed.acceptsAsset($0.downloadURL) }
        }
        guard let image = find(imageName) else { throw .assetMissing(imageName) }
        guard let checksums = find(checksumsName) else { throw .assetMissing(checksumsName) }
        return (image, checksums)
    }
}
