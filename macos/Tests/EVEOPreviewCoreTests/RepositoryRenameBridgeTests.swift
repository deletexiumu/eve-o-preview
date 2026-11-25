// SPDX-License-Identifier: GPL-3.0-or-later
//
// 仓库改名的用例：1.3.0 起接受新旧两个名字，2026-11-23 仓库改名为 eve-o-preview，1.3.2 起正式地址用新名字。
// 同一仓库还会发布 Windows 版（tag `win-v*`）。
// - 附件与发布页同时接受新旧两个仓库名，别的名字（包括只差一个后缀的）仍然拒绝。
// - 1.5.0 起检查读更新清单，不再解析 GitHub 的 Release 接口；`latest` 是 Windows 版时挑 macOS 版的列表回退随之去掉。
//   发布页（与 1.4.x 缓存的附件）仍按这里的规则核对。

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

    /// 1.3.2 起（仓库已改名）默认发布页用新名字，改名前的附件与发布页地址仍然接受；
    /// 1.5.0 起 GitHub 上的清单也在改名后的仓库里。
    @Test func productionUsesNewNameAndKeepsLegacy() {
        #expect(UpdateFeed.productionAssetPrefix == "https://github.com/deletexiumu/eve-o-preview/releases/")
        #expect(UpdateFeed.legacyAssetPrefix == "https://github.com/deletexiumu/eve-o-preview-macos/releases/")
        #expect(production.accepts(UpdateFeed.productionAssetPrefix + "download/v1.3.2/EVE-O-Preview-1.3.2.dmg"))
        #expect(production.accepts(UpdateFeed.legacyAssetPrefix + "download/v1.3.1/EVE-O-Preview-1.3.1.dmg"))
        #expect(UpdateFeed.productionManifestURLs.last?.absoluteString
            == UpdateFeed.productionAssetPrefix + "latest/download/update-manifest.json")
    }
}
