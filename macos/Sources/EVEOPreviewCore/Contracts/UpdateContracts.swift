// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新功能的契约（v1.1 设计 8.4 节）：检查地址 `UpdateFeed`（含实现）、检查结果与平台服务协议。
// 协议只含值类型，方法可以在任何线程调用；Platform 的实现是 `SystemUpdateService`，演示模式是 `FakeUpdateService`。
//
// 1.5.0 起检查读签名的更新清单（docs/update-manifest.md）：正式地址有两个源（R2 的 CDN 在前、GitHub 在后），
// 依次尝试；测试地址只有一个源。发布页与附件的地址分开核对：发布页要在浏览器里打开，仍只认本仓库的 GitHub
// Release 地址（`accepts`）；附件来自验过签的清单、真伪由清单里的 SHA-256 保证，只要求是干净的 https（`acceptsAsset`）。

import Foundation

/// 更新检查的地址。
public struct UpdateFeed: Sendable, Equatable {
    /// 第一个清单地址：正式地址下是 R2 的地址，测试地址下是 `EVEO_UPDATE_FEED_URL` 的值。
    public var feedURL: URL
    /// 是否是环境变量 `EVEO_UPDATE_FEED_URL` 指定的测试地址。
    public var isTestFeed: Bool

    /// 正式的清单地址，按顺序尝试：R2 的自定义域名（经 Cloudflare 的 CDN），然后是 GitHub 最新 Release 的附件。
    /// R2 的地址与 release.yml 的 `R2_PUBLIC_BASE_URL` 一致；换域名时要先发一个同时内置新旧地址的版本。
    public static let productionManifestURLs = [
        URL(string: "https://eveo.deepai.wiki/update-manifest.json")!,
        URL(string: "https://github.com/deletexiumu/eve-o-preview/releases/latest/download/update-manifest.json")!,
    ]
    /// 正式地址下，附件与发布页的地址应以它开头，也是打开发布页时的默认地址。2026-11-23 仓库由
    /// `eve-o-preview-macos` 改名为 `eve-o-preview`，GitHub 答复里的 `html_url` 与 `browser_download_url` 都是新名字。
    public static let productionAssetPrefix = "https://github.com/deletexiumu/eve-o-preview/releases/"
    /// 改名前的附件与发布页前缀，仍然接受：state.json 里缓存的发布页与旧版本留下的地址带的是旧名字，
    /// GitHub 也会把它重定向到新仓库。1.3.0 起两个名字都接受，所以改名没有中断 1.3.0 及以上的自动更新。
    public static let legacyAssetPrefix = "https://github.com/deletexiumu/eve-o-preview-macos/releases/"
    /// 正式地址下，附件与发布页的主机。`html_url`、`browser_download_url` 与缓存的发布页都在这个主机上；
    /// 下载时重定向到的文件存储主机不经 `accepts` 核对（见 `UpdateDownloader`）。
    static let productionAssetHost = "github.com"
    /// 正式地址下，附件与发布页允许的路径前缀：现在的仓库名与改名前的仓库名各一个，都以 `/releases/` 结尾，
    /// 所以 `eve-o-preview` 不会误配 `eve-o-preview-macos` 或 `eve-o-preview-fork` 这类名字。
    static let productionAssetPathPrefixes = ["/deletexiumu/eve-o-preview/releases/",
                                              "/deletexiumu/eve-o-preview-macos/releases/"]
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
        let production = UpdateFeed(feedURL: productionManifestURLs[0], isTestFeed: false)
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

    /// 要依次尝试的清单地址：正式地址下是 `productionManifestURLs`，测试地址下只有 feedURL 一个。
    public var manifestURLs: [URL] {
        isTestFeed ? [feedURL] : UpdateFeed.productionManifestURLs
    }

    /// 发布页（与 1.4.x 及更早版本缓存的附件）的地址是否可用。测试地址下应与 feedURL 同源。正式地址下同时满足：
    /// - 原文以 productionAssetPrefix 或 legacyAssetPrefix 开头，不含反斜杠、`%2e`（编码的点，不分大小写）、`%2f`、`%5c`；
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

    /// 清单里附件的地址是否可用（docs/update-manifest.md 第 4 节第 7 条）。测试地址下应与 feedURL 同源；
    /// 正式地址下只要求：协议是 https、有主机、没有用户名与密码、原文里没有反斜杠与控制字符。
    /// 不限主机：地址来自验过签的清单，下载的文件还要与清单里的 SHA-256 相符，源本身不需要被信任。
    public func acceptsAsset(_ urlString: String) -> Bool {
        guard isTestFeed else { return UpdateFeed.isCleanHTTPS(urlString) }
        return accepts(urlString)
    }

    /// 正式地址下附件的规则，见 `acceptsAsset`。
    static func isCleanHTTPS(_ urlString: String) -> Bool {
        let hasControl = urlString.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        guard !hasControl, !urlString.contains("\\"),
              let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        return true
    }

    /// 正式地址下的规则，见 `accepts`。先查原文：`URLComponents.path` 会解码百分号编码，解码后再查就晚了。
    static func isProductionAsset(_ urlString: String) -> Bool {
        let knownPrefix = [productionAssetPrefix, legacyAssetPrefix].contains { urlString.hasPrefix($0) }
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

/// 一次检查的结果（docs/update-manifest.md 第 4 节）。
public enum ReleaseFetchResult: Sendable, Equatable {
    /// 拿到并验过签的清单里有改动了本平台的版本。sequence 是清单的序号，只在正式地址下给出，调用方记下它防回退。
    case release(ReleaseInfo, sequence: UInt64?)
    /// 清单里没有本平台的版本。
    case noRelease(sequence: UInt64?)
    /// 所有源都失败，关联值是最后一个源的错误。
    case failed(UpdateError)
}

/// 更新的平台服务。方法可以在任何线程调用。
public protocol UpdateService: Sendable {
    /// 依次请求各个清单源，验签并解析，返回改动了本平台的最新正式版。minimumSequence 是接受过的最大序号
    /// （正式地址下），序号更小的清单按这个源失败处理；appVersion 用于 `User-Agent`。
    func fetchLatestRelease(feed: UpdateFeed, minimumSequence: UInt64?, appVersion: String) async -> ReleaseFetchResult
    /// 改动了本平台的各正式版的说明，供显示中间版本（8.8 节）。取自最近一次检查拿到的清单；没有时（如重启后
    /// 从缓存恢复的提示）重新取一次清单。尽力而为：失败时返回 nil，不影响检查与安装。
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
    /// 默认不取中间版本的说明：没有实现它的服务（如测试替身）只显示最新版的说明。
    public func fetchReleaseHistory(feed: UpdateFeed, appVersion: String) async -> ReleaseHistoryPage? { nil }
}
