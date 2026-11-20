// SPDX-License-Identifier: GPL-3.0-or-later
//
// `UpdateService` 的真实实现（v1.1 设计 8.4、9.2、9.3 节）。WP-3 实现时把各方法转给
// `ReleaseFeedClient`（检查）、`UpdateDownloader`（下载与核对）、`BundleInstaller`（挂载、验证与替换）。
// WP-0 只建骨架：检查返回 `.noRelease`（按已是最新处理），下载与安装返回 `.cancelled`，不发任何网络请求。

import Foundation
import EVEOPreviewCore

/// 更新的平台服务。
public final class SystemUpdateService: UpdateService {
    /// 建服务。
    public init() {}

    /// 骨架：不发请求，返回 `.noRelease`（WP-3 实现）。
    public func fetchLatestRelease(feed: UpdateFeed, etag: String?, appVersion: String) async -> ReleaseFetchResult {
        .noRelease
    }

    /// 骨架：返回 `.cancelled`（WP-3 实现）。
    public func prepare(_ release: ReleaseInfo, feed: UpdateFeed,
                        progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError> {
        .failure(.cancelled)
    }

    /// 骨架：没有进行中的下载，不做事（WP-3 实现）。
    public func cancelPreparation() {}

    /// 骨架：返回 `.cancelled`，不碰已安装的应用（WP-3 实现）。
    public func install(_ prepared: PreparedUpdate, environment: AppEnvironment) async -> Result<InstallOutcome, UpdateError> {
        .failure(.cancelled)
    }

    /// 骨架：不删任何文件（WP-3 实现）。
    public func removeLeftovers(keeping prepared: PreparedUpdate?, staleStagingPath: String?) async {}
}
