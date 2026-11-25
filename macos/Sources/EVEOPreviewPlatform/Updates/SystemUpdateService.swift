// SPDX-License-Identifier: GPL-3.0-or-later
//
// `UpdateService` 的真实实现（v1.1 设计 8.4、8.8、9.2、9.3 节）。各方法转给：
// `ReleaseFeedClient`（取更新清单）、`UpdateDownloader`（下载与核对）、`BundleInstaller`（挂载、验证、替换与残留清理）。
//
// 中间版本的说明取自最近一次检查拿到的清单（存在内存里）；没有时（重启后从缓存恢复的提示）重新取一次清单。
//
// 缓存目录默认是 `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/`。探针可以另指目录，
// 不碰用户的缓存。
//
// 契约的两处缺口在这里补上：
// - `install` 不带检查地址，而 9.3 节第 1 步要知道是不是测试地址：按环境变量 `EVEO_UPDATE_FEED_URL`
//   用 `UpdateFeed.resolve` 重新算一次，口径与 `UpdateController` 相同。
// - `prepare` 不带应用版本，而下载请求的 `User-Agent` 要它：取本进程 Info.plist 的版本号，没有时是 0.0.0。

import Foundation
import EVEOPreviewCore
import os

/// 更新的平台服务。
public final class SystemUpdateService: UpdateService {
    /// 下载与核对。
    let downloader: UpdateDownloader
    /// 替换与残留清理。
    let installer: BundleInstaller
    /// 最近一次检查拿到的清单与它的检查地址，供 `fetchReleaseHistory` 用。
    private let lastManifest = OSAllocatedUnfairLock<(feed: UpdateFeed, manifest: UpdateManifest)?>(initialState: nil)

    /// 默认的缓存目录 `~/Library/Caches/<bundle id>/Updates`。
    public static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent(PlatformLog.subsystem, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    /// 用默认缓存目录建服务。`PlatformServices.makeLive()` 用它。
    public convenience init() {
        self.init(cacheDirectory: SystemUpdateService.defaultCacheDirectory())
    }

    /// 用指定的缓存目录建服务。registersWithLaunchServices 为假时，安装后不向 LaunchServices 登记（探针用）。
    public init(cacheDirectory: URL, registersWithLaunchServices: Bool = true) {
        downloader = UpdateDownloader(cacheRoot: cacheDirectory)
        installer = BundleInstaller(cacheRoot: cacheDirectory, registersWithLaunchServices: registersWithLaunchServices)
    }

    /// 取更新清单，返回改动了 macOS 的最新正式版（docs/update-manifest.md 第 4 节）。
    public func fetchLatestRelease(feed: UpdateFeed, minimumSequence: UInt64?,
                                   appVersion: String) async -> ReleaseFetchResult {
        let (result, manifest) = await ReleaseFeedClient.fetch(feed: feed, minimumSequence: minimumSequence,
                                                               appVersion: appVersion)
        if let manifest { lastManifest.withLock { $0 = (feed, manifest) } }
        return result
    }

    /// 改动了 macOS 的各版本的说明（8.8 节）：用最近一次检查的清单，没有时重新取一次（不比较序号：只用来显示说明）。
    public func fetchReleaseHistory(feed: UpdateFeed, appVersion: String) async -> ReleaseHistoryPage? {
        if let cached = lastManifest.withLock({ $0 }), cached.feed == feed { return cached.manifest.historyPage() }
        guard case .success(let manifest) = await ReleaseFeedClient.fetchManifest(feed: feed, minimumSequence: nil,
                                                                                  appVersion: appVersion) else {
            return nil
        }
        lastManifest.withLock { $0 = (feed, manifest) }
        return manifest.historyPage()
    }

    /// 下载校验和文件与 dmg，核对 SHA-256（9.2 节）。
    public func prepare(_ release: ReleaseInfo, feed: UpdateFeed,
                        progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError> {
        await downloader.prepare(release, feed: feed, appVersion: SystemUpdateService.appVersion, progress: progress)
    }

    /// 取消进行中的 `prepare`；它随后返回 `.cancelled`。
    public func cancelPreparation() {
        downloader.cancel()
    }

    /// 挂载、复制、验证并替换已安装的应用，不重新启动（9.3 节）。
    public func install(_ prepared: PreparedUpdate, environment: AppEnvironment) async -> Result<InstallOutcome, UpdateError> {
        let override = ProcessInfo.processInfo.environment["EVEO_UPDATE_FEED_URL"]
        let isTestFeed = UpdateFeed.resolve(override: override).isTestFeed
        return await installer.install(prepared, environment: environment, isTestFeed: isTestFeed,
                                       systemVersion: SystemUpdateService.systemVersion)
    }

    /// 删除缓存目录里除 prepared 之外的文件，以及上次安装换下来的旧包（9.3 节）。
    public func removeLeftovers(keeping prepared: PreparedUpdate?, staleStagingPath: String?) async {
        await installer.removeLeftovers(keeping: prepared, staleStagingPath: staleStagingPath)
    }

    /// path（来自 state.json 的 `prepared.imagePath`）解析符号链接后是否位于缓存目录之下。
    /// App 删 dmg 前用它核对，不在缓存目录下的路径不删。路径不存在时返回 false。
    public static func isInsideCache(_ path: String, cacheDirectory: URL = defaultCacheDirectory()) -> Bool {
        BundleInstaller.isInsideCache(path, cacheRoot: cacheDirectory)
    }

    /// 本进程 Info.plist 的版本号，用于下载请求的 `User-Agent`；没有时是 0.0.0。
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "0.0.0"
    }

    /// 当前系统的版本，如 `27.0.0`。
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
