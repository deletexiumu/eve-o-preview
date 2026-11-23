// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新功能的契约（v1.1 设计 8.4 节）：检查地址 `UpdateFeed`（含实现）、检查结果与平台服务协议。
// 协议只含值类型，方法可以在任何线程调用；Platform 的实现是 `SystemUpdateService`，演示模式是 `FakeUpdateService`。

import Foundation

/// 更新检查的地址。
public struct UpdateFeed: Sendable, Equatable {
    /// 检查请求的地址。
    public var feedURL: URL
    /// 是否是环境变量 `EVEO_UPDATE_FEED_URL` 指定的测试地址。
    public var isTestFeed: Bool

    /// 正式的检查地址。
    public static let productionURL = URL(string: "https://api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest")!
    /// 正式的 Release 列表地址（8.8 节）。每页个数与 `ReleaseHistory.pageSize` 一致，由用例核对。
    /// 1.3.0 起每页 100 条：仓库以后同时发布 Windows 版（tag `win-v*`），30 条里会被它们占掉一部分。
    public static let productionHistoryURL =
        URL(string: "https://api.github.com/repos/deletexiumu/eve-o-preview-macos/releases?per_page=100")!
    /// 正式地址下，附件与发布页的地址应以它开头。仓库改名之前它也是打开发布页时的默认地址。
    public static let productionAssetPrefix = "https://github.com/deletexiumu/eve-o-preview-macos/releases/"
    /// 仓库计划改名后的附件与发布页前缀（1.3.0 起同样接受）。
    ///
    /// GitHub 改名后，检查地址仍会被重定向到新仓库，但答复里的 `html_url` 与 `browser_download_url` 换成新名字。
    /// ≤1.2.2 只认旧名字，所以改名后不能自动安装；1.3.0 先认上两个名字，改名才不会中断自动更新。
    public static let renamedAssetPrefix = "https://github.com/deletexiumu/eve-o-preview/releases/"
    /// 正式地址下，附件与发布页的主机。`html_url`、`browser_download_url` 与缓存的发布页都在这个主机上；
    /// 下载时重定向到的文件存储主机不经 `accepts` 核对（见 `UpdateDownloader`）。
    static let productionAssetHost = "github.com"
    /// 正式地址下，附件与发布页允许的路径前缀：旧仓库名与改名后的仓库名各一个，都以 `/releases/` 结尾，
    /// 所以 `eve-o-preview` 不会误配 `eve-o-preview-macos` 或 `eve-o-preview-fork` 这类名字。
    static let productionAssetPathPrefixes = ["/deletexiumu/eve-o-preview-macos/releases/",
                                              "/deletexiumu/eve-o-preview/releases/"]
    /// 测试地址用 `http` 时允许的主机（已去掉 IPv6 的方括号、转成小写）。
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// 用各字段建地址。一般用 `resolve(override:)`。
    public init(feedURL: URL, isTestFeed: Bool) {
        self.feedURL = feedURL
        self.isTestFeed = isTestFeed
    }

    /// override 是环境变量 EVEO_UPDATE_FEED_URL 的值。只接受 https，或主机是 127.0.0.1、localhost、::1 的 http。
    ///
    /// override 为 nil 或空串时用正式地址。不符合条件时也用正式地址，`isTestFeed` 为假；
    /// 是否记日志由调用方比较 override 与结果决定（8.4 节：App 记一条 `error`）。
    public static func resolve(override: String?) -> UpdateFeed {
        let production = UpdateFeed(feedURL: productionURL, isTestFeed: false)
        guard let override, !override.isEmpty,
              let url = URL(string: override), let origin = Origin(url) else { return production }
        switch origin.scheme {
        case "https":
            return UpdateFeed(feedURL: url, isTestFeed: true)
        case "http" where loopbackHosts.contains(origin.host):
            return UpdateFeed(feedURL: url, isTestFeed: true)
        default:
            return production
        }
    }

    /// Release 列表的地址，用来取中间版本的发布说明（8.8 节）。
    ///
    /// - 正式地址：只在 feedURL 正是 `productionURL` 时，取 `productionHistoryURL`。
    /// - 测试地址：地址没有查询串、最后一段以 `.json` 结尾时，把最后一段换成 `releases.json`，如
    ///   `http://127.0.0.1:8123/feed.json` → `http://127.0.0.1:8123/releases.json`，与 feedURL 同源
    ///   （`make-update-test-feed.sh` 会一起生成）。
    /// 其他情况返回 nil，调用方就不取中间版本，只显示最新版的说明。
    public var historyURL: URL? {
        if !isTestFeed { return feedURL == UpdateFeed.productionURL ? UpdateFeed.productionHistoryURL : nil }
        guard var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              feedURL.lastPathComponent.lowercased().hasSuffix(".json") else { return nil }
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        segments[segments.count - 1] = "releases.json"
        components.path = segments.joined(separator: "/")
        return components.url
    }

    /// 附件与发布页的地址是否可用。测试地址下应与 feedURL 同源。正式地址下同时满足：
    /// - 原文以 productionAssetPrefix 或 renamedAssetPrefix 开头，不含反斜杠、`%2e`（编码的点，不分大小写）、`%2f`、`%5c`；
    /// - 按地址解析后协议是 https，主机正好是 `github.com`，没有用户名与密码，端口省略或是 443；
    /// - 路径以本仓库（新旧两个名字之一）的 `/releases/` 开头，没有 `.` 或 `..` 段（如 `…/releases/../../../evil/repo/…`）。
    ///
    /// 同源指协议、主机与端口都相同；端口省略时按协议的默认端口（http 80，https 443）比较。
    public func accepts(_ urlString: String) -> Bool {
        guard isTestFeed else { return UpdateFeed.isProductionAsset(urlString) }
        guard let url = URL(string: urlString), let candidate = Origin(url), let own = Origin(feedURL) else {
            return false
        }
        return candidate == own
    }

    /// 正式地址下的规则，见 `accepts`。先查原文：`URLComponents.path` 会解码百分号编码，解码后再查就晚了。
    static func isProductionAsset(_ urlString: String) -> Bool {
        let knownPrefix = [productionAssetPrefix, renamedAssetPrefix].contains { urlString.hasPrefix($0) }
        guard knownPrefix, !urlString.contains("\\") else { return false }
        let lowered = urlString.lowercased()
        guard !["%2e", "%2f", "%5c"].contains(where: lowered.contains) else { return false }
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == productionAssetHost,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return false }
        let path = components.percentEncodedPath
        // 原文前缀与路径前缀分开核对：原文查的是未解析的字符串，路径查的是解析后的结果，两者都要命中。
        guard productionAssetPathPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.contains { $0 == "." || $0 == ".." }
    }

    /// 地址的源：协议、主机与端口，都已规范化。
    struct Origin: Equatable {
        /// 小写的协议。
        var scheme: String
        /// 小写的主机，IPv6 地址去掉方括号。
        var host: String
        /// 端口；地址里省略时取协议的默认端口。
        var port: Int?

        /// 从地址取源；没有协议或主机时返回 nil。
        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  var host = components.host?.lowercased(), !host.isEmpty else { return nil }
            // URLComponents 对 IPv6 主机是否保留方括号随系统版本不同，这里统一去掉。
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            self.scheme = scheme
            self.host = host
            switch (components.port, scheme) {
            case (let port?, _): self.port = port
            case (nil, "http"): self.port = 80
            case (nil, "https"): self.port = 443
            default: self.port = nil
            }
        }
    }
}

/// 一次检查请求的结果（8.4 节答复的处理表）。
public enum ReleaseFetchResult: Sendable, Equatable {
    /// 200：解析出的发布信息与答复的 ETag。
    case release(ReleaseInfo, etag: String?)
    /// 304：与上次相同，用缓存的发布信息。
    case notModified
    /// 404：仓库还没有正式版。
    case noRelease
    /// 被限流，关联值是可以再试的时刻。
    case rateLimited(until: Date?)
    /// 其他失败。
    case failed(UpdateError)
}

/// 更新的平台服务。方法可以在任何线程调用。
public protocol UpdateService: Sendable {
    /// 请求最新的正式版。etag 是上次答复的 ETag；appVersion 用于 `User-Agent`。
    func fetchLatestRelease(feed: UpdateFeed, etag: String?, appVersion: String) async -> ReleaseFetchResult
    /// 请求 Release 列表（`feed.historyURL`），返回各正式版的说明，供显示中间版本（8.8 节）。
    /// 尽力而为：地址拼不出来、网络错误、非 200、限流或解析失败时都返回 nil，不影响检查与安装。
    func fetchReleaseHistory(feed: UpdateFeed, appVersion: String) async -> ReleaseHistoryPage?
    /// 下载校验和文件与 dmg，核对 SHA-256，返回放在缓存目录里的 dmg。
    func prepare(_ release: ReleaseInfo, feed: UpdateFeed,
                 progress: @escaping @Sendable (UpdateProgress) -> Void) async -> Result<PreparedUpdate, UpdateError>
    /// 取消进行中的 `prepare`；它随后返回 `.cancelled`。
    func cancelPreparation()
    /// 挂载、复制、验证并替换已安装的应用。不重新启动。
    func install(_ prepared: PreparedUpdate, environment: AppEnvironment) async -> Result<InstallOutcome, UpdateError>
    /// 删除缓存目录里除 prepared 之外的文件，以及上次安装换下来的旧包。
    func removeLeftovers(keeping prepared: PreparedUpdate?, staleStagingPath: String?) async
}

extension UpdateService {
    /// 默认不取 Release 列表：没有实现它的服务（如测试替身）只显示最新版的说明。
    public func fetchReleaseHistory(feed: UpdateFeed, appVersion: String) async -> ReleaseHistoryPage? { nil }
}
