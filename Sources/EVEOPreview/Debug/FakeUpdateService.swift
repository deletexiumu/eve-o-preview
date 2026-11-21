// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式（`EVEO_FAKE=1`）的更新服务（v1.1 设计 8.5 节、第 12 节），不发任何网络请求。
// 另放 `EVEO_UPDATE_UI_STATE` 调试入口用的样例（13.1 节第 4 项），由 `UpdateController.start()` 取用。
//
// 演示模式下 `UpdateController` 不下载、不安装、不重新启动，所以下面的下载与安装只做最少的事。

import Foundation
import EVEOPreviewCore

/// 演示模式的更新服务。检查返回样例版本 1.1.1，Release 列表另有样例 1.1.0；下载只模拟进度，不写文件；安装不改动任何东西。
final class FakeUpdateService: UpdateService {
    /// 模拟下载的步数与每步的间隔。
    private static let steps = 10
    private static let stepDelay: Duration = .milliseconds(200)

    /// 返回样例版本 1.1.1（不发请求），不带 ETag。
    func fetchLatestRelease(feed: UpdateFeed, etag: String?, appVersion: String) async -> ReleaseFetchResult {
        .release(FakeUpdateService.sampleRelease, etag: nil)
    }

    /// 返回样例的中间版本 1.1.0 与已是最新的 1.1.1（不发请求），供核对按版本分段的显示。
    func fetchReleaseHistory(feed: UpdateFeed, appVersion: String) async -> ReleaseHistoryPage? {
        ReleaseHistoryPage(entries: [ReleaseNotesEntry(version: "1.1.1", notes: FakeUpdateService.sampleNotes)]
                           + FakeUpdateService.sampleIntermediateNotes.entries, isFull: false)
    }

    /// 模拟约 2 秒的下载进度，然后返回 `.cancelled`：演示模式不写缓存目录，也就没有可装的 dmg。
    func prepare(_ release: ReleaseInfo, feed: UpdateFeed,
                 progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError> {
        let total: Int64 = 2_618_184
        for step in 1...FakeUpdateService.steps {
            try? await Task.sleep(for: FakeUpdateService.stepDelay)
            progress(UpdateProgress(receivedBytes: total * Int64(step) / Int64(FakeUpdateService.steps), totalBytes: total))
        }
        return .failure(.cancelled)
    }

    /// 没有真实的下载可取消。
    func cancelPreparation() {}

    /// 演示模式不改动已安装的应用（控制器在演示模式下也不会调用它）。
    func install(_ prepared: PreparedUpdate, environment: AppEnvironment) async -> Result<InstallOutcome, UpdateError> {
        .failure(.cancelled)
    }

    /// 演示模式没有缓存文件，不做事。
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

    /// 样例版本 1.1.1。正文按 8.2 节的格式写 8 种语言，供核对按界面语言取段落与 Markdown 的显示。
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

    /// 界面调试时的中间版本样例（8.8 节）：一个 1.1.0，`hasMore` 为真，窗口显示两段说明和「更早版本见发布页」一行。
    static var sampleIntermediateNotes: IntermediateReleaseNotes {
        IntermediateReleaseNotes(latestVersion: "1.1.1", runningVersion: "1.0.0",
                                 entries: [ReleaseNotesEntry(version: "1.1.0", notes: sampleEarlierNotes)], hasMore: true)
    }

    /// 中间版本样例的说明：英文与中文两块，其余语言取英文（核对取不到界面语言时的退回）。
    static let sampleEarlierNotes = """
    <!-- lang:en -->
    ## New

    - **In-app updates:** EVE-O Preview checks GitHub for new versions and installs them.
    <!-- /lang:en -->
    <!-- lang:zh -->
    <details><summary>简体中文</summary>

    ### 新增

    - **应用内更新：** EVE-O Preview 会到 GitHub 检查新版本并安装。

    </details>
    <!-- /lang:zh -->
    """

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
    <!-- lang:fr -->
    <details><summary>Français</summary>

    ## Nouveautés

    - Les vignettes conservent la **couleur de la bordure** après un changement de profil.

    </details>
    <!-- /lang:fr -->
    <!-- lang:de -->
    <details><summary>Deutsch</summary>

    ## Neu

    - Miniaturen behalten die **Rahmenfarbe** nach dem Wechsel des Profils.

    </details>
    <!-- /lang:de -->
    <!-- lang:es -->
    <details><summary>Español</summary>

    ## Novedades

    - Las miniaturas conservan el **color del borde** al cambiar de perfil.

    </details>
    <!-- /lang:es -->
    """
}
