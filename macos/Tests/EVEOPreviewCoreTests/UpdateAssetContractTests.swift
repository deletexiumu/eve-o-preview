// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdateAssetContract 的用例（v1.1 设计 8.1 节、14.1 节）。名字是 CI 与应用之间的契约，这里写死。

import Foundation
import Testing
import EVEOPreviewCore

/// 发布契约里的名字与附件的选取。
struct UpdateAssetContractTests {
    /// 契约的名字与上限。
    @Test func contractConstants() {
        #expect(UpdateAssetContract.imageName(version: "1.1.1") == "EVE-O-Preview-1.1.1.dmg")
        #expect(UpdateAssetContract.checksumsName == "SHA256SUMS.txt")
        #expect(UpdateAssetContract.appBundleName == "EVE-O Preview.app")
        #expect(UpdateAssetContract.maxImageBytes == 300 * 1_048_576)
        #expect(UpdateAssetContract.maxChecksumsBytes == 65_536)
    }

    /// 两个附件都在时取到，其他附件（源码包）不影响。
    @Test func findsBothAssets() throws {
        let base = UpdateFixtures.release("1.0.0")
        let source = ReleaseAsset(name: "eve-o-preview-1.0.0-source.zip",
                                  downloadURL: UpdateFeed.productionAssetPrefix + "download/v1.0.0/s.zip", size: 9)
        let release = UpdateFixtures.release("1.0.0", assets: [source] + base.assets)
        let pair = try UpdateAssetContract.assets(in: release, feed: UpdateFixtures.productionFeed)
        #expect(pair.image.name == "EVE-O-Preview-1.0.0.dmg")
        #expect(pair.image.size == 2_618_184)
        #expect(pair.checksums.name == "SHA256SUMS.txt")
    }

    /// 缺 dmg 或缺校验和文件时抛 assetMissing，带上缺的名字。
    @Test func missingAssets() {
        let base = UpdateFixtures.release("1.1.1")
        let noImage = UpdateFixtures.release("1.1.1", assets: [base.assets[1]])
        let noChecksums = UpdateFixtures.release("1.1.1", assets: [base.assets[0]])
        let none = UpdateFixtures.release("1.1.1", assets: [])
        let feed = UpdateFixtures.productionFeed
        #expect(throws: UpdateError.assetMissing("EVE-O-Preview-1.1.1.dmg")) {
            try UpdateAssetContract.assets(in: noImage, feed: feed)
        }
        #expect(throws: UpdateError.assetMissing("SHA256SUMS.txt")) {
            try UpdateAssetContract.assets(in: noChecksums, feed: feed)
        }
        #expect(throws: UpdateError.assetMissing("EVE-O-Preview-1.1.1.dmg")) {
            try UpdateAssetContract.assets(in: none, feed: feed)
        }
    }

    /// 名字只差大小写时不算。
    @Test func caseSensitiveNames() {
        let prefix = UpdateFeed.productionAssetPrefix + "download/v1.1.1/"
        let release = UpdateFixtures.release("1.1.1", assets: [
            ReleaseAsset(name: "eve-o-preview-1.1.1.dmg", downloadURL: prefix + "a.dmg", size: 1),
            ReleaseAsset(name: "sha256sums.txt", downloadURL: prefix + "s.txt", size: 1),
        ])
        #expect(throws: UpdateError.assetMissing("EVE-O-Preview-1.1.1.dmg")) {
            try UpdateAssetContract.assets(in: release, feed: UpdateFixtures.productionFeed)
        }
    }

    /// 首选地址不是干净的 https 时按缺失处理；正式地址下别的 https 主机（如 R2 的域名）可以。
    @Test func rejectsForeignURLs() throws {
        let checksums = ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: "https://eveo.deepai.wiki/v1.1.1/SHA256SUMS.txt",
                                     size: 1)
        let plain = UpdateFixtures.release("1.1.1", assets: [
            ReleaseAsset(name: "EVE-O-Preview-1.1.1.dmg", downloadURL: "http://example.com/x.dmg", size: 1), checksums,
        ])
        #expect(throws: UpdateError.assetMissing("EVE-O-Preview-1.1.1.dmg")) {
            try UpdateAssetContract.assets(in: plain, feed: UpdateFixtures.productionFeed)
        }
        let mirror = UpdateFixtures.release("1.1.1", assets: [
            ReleaseAsset(name: "EVE-O-Preview-1.1.1.dmg", downloadURL: "https://eveo.deepai.wiki/v1.1.1/x.dmg", size: 1),
            checksums,
        ])
        #expect(try UpdateAssetContract.assets(in: mirror, feed: UpdateFixtures.productionFeed).image.size == 1)
        // 测试地址下仍要同源。
        #expect(throws: UpdateError.assetMissing("EVE-O-Preview-1.1.1.dmg")) {
            try UpdateAssetContract.assets(in: mirror, feed: UpdateFixtures.testFeed)
        }
    }
}
