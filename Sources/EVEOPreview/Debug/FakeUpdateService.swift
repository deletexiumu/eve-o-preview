// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式（`EVEO_FAKE=1`）的更新服务（v1.1 设计 8.5 节、第 12 节），不发任何网络请求。
// 另放 `EVEO_UPDATE_UI_STATE` 调试入口用的样例（13.1 节第 4 项），由 `UpdateController.start()` 取用。
//
// WP-0 只建骨架：检查返回 `.noRelease`，下载与安装返回 `.cancelled`；WP-3 实现。

import Foundation
import EVEOPreviewCore

/// 演示模式的更新服务。
final class FakeUpdateService: UpdateService {
    /// 骨架：返回 `.noRelease`（WP-3 实现）。
    func fetchLatestRelease(feed: UpdateFeed, etag: String?, appVersion: String) async -> ReleaseFetchResult {
        .noRelease
    }

    /// 骨架：返回 `.cancelled`（WP-3 实现）。
    func prepare(_ release: ReleaseInfo, feed: UpdateFeed,
                 progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError> {
        .failure(.cancelled)
    }

    /// 骨架：不做事（WP-3 实现）。
    func cancelPreparation() {}

    /// 骨架：返回 `.cancelled`（WP-3 实现）。
    func install(_ prepared: PreparedUpdate, environment: AppEnvironment) async -> Result<InstallOutcome, UpdateError> {
        .failure(.cancelled)
    }

    /// 骨架：不做事（WP-3 实现）。
    func removeLeftovers(keeping prepared: PreparedUpdate?, staleStagingPath: String?) async {}
}

// MARK: - 界面调试的样例

extension FakeUpdateService {
    /// `EVEO_UPDATE_UI_STATE` 的取值对应的样例阶段与安装能力；取值不认识时返回 nil。
    ///
    /// | 取值 | 阶段 | 能力 |
    /// | --- | --- | --- |
    /// | `available` | `.available` | `.canInstall` |
    /// | `notifyonly` | `.available` | `.notifyOnly(.adHocSignature)` |
    /// | `downloading` | `.downloading`，约 1.2 MB / 2.6 MB | `.canInstall` |
    /// | `ready` | `.readyToInstall` | `.canInstall` |
    /// | `failed` | `.failed(.checksumMismatch)` | `.canInstall` |
    /// | `uptodate` | `.upToDate`，现在 | `.canInstall` |
    static func samplePhase(named name: String) -> (phase: UpdatePhase, capability: InstallCapability)? {
        let release = sampleRelease
        switch name {
        case "available": return (.available(release), .canInstall)
        case "notifyonly": return (.available(release), .notifyOnly(.adHocSignature))
        case "downloading":
            return (.downloading(release, UpdateProgress(receivedBytes: 1_200_000, totalBytes: 2_618_184)), .canInstall)
        case "ready": return (.readyToInstall(release), .canInstall)
        case "failed": return (.failed(.checksumMismatch, release: release), .canInstall)
        case "uptodate": return (.upToDate(checkedAt: Date()), .canInstall)
        default: return nil
        }
    }

    /// 样例版本 1.1.1。正文按 8.2 节的格式写 5 种语言，供核对按界面语言取段落与 Markdown 的显示。
    static var sampleRelease: ReleaseInfo {
        let prefix = UpdateFeed.productionAssetPrefix
        return ReleaseInfo(version: "1.1.1", tagName: "v1.1.1", title: "EVE-O Preview 1.1.1", notes: sampleNotes,
                           pageURL: prefix + "tag/v1.1.1", publishedAt: Date().addingTimeInterval(-86_400),
                           isPrerelease: false, isDraft: false,
                           assets: [ReleaseAsset(name: "EVE-O-Preview-1.1.1.dmg",
                                                 downloadURL: prefix + "download/v1.1.1/EVE-O-Preview-1.1.1.dmg",
                                                 size: 2_618_184),
                                    ReleaseAsset(name: "SHA256SUMS.txt",
                                                 downloadURL: prefix + "download/v1.1.1/SHA256SUMS.txt", size: 220)])
    }

    /// 样例的发布说明（8.2 节的格式：英文在前，其余语言各一个可折叠的块）。
    static let sampleNotes = """
    <!-- lang:en -->
    ## What's new

    - Thumbnails keep their **border colour** after switching profiles.
    - The *Check Now* button shows the time of the last check.
      - Nested item for layout checks.

    1. Quit EVE-O Preview.
    2. Open the new version.

    See the [release page](https://github.com/deletexiumu/eve-o-preview-macos/releases) for details. `code` stays monospaced.
    <!-- /lang:en -->
    <!-- lang:zh -->
    <details><summary>简体中文</summary>

    ## 新内容

    - 切换配置方案后，缩略图保留**边框颜色**。
    - 「立即检查」按钮显示上次检查的时刻。

    详见[发布页](https://github.com/deletexiumu/eve-o-preview-macos/releases)。

    </details>
    <!-- /lang:zh -->
    <!-- lang:ja -->
    <details><summary>日本語</summary>

    ## 新機能

    - プロファイルを切り替えても、サムネイルの**枠線の色**が保たれます。

    </details>
    <!-- /lang:ja -->
    <!-- lang:ko -->
    <details><summary>한국어</summary>

    ## 새로운 기능

    - 프로필을 전환해도 썸네일의 **테두리 색**이 유지됩니다.

    </details>
    <!-- /lang:ko -->
    <!-- lang:ru -->
    <details><summary>Русский</summary>

    ## Что нового

    - После смены профиля миниатюры сохраняют **цвет рамки**.

    </details>
    <!-- /lang:ru -->
    """
}
