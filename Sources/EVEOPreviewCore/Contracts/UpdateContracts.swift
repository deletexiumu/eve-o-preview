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
    /// 正式地址下，附件与发布页的地址应以它开头。
    public static let productionAssetPrefix = "https://github.com/deletexiumu/eve-o-preview-macos/releases/"
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

    /// 附件与发布页的地址是否可用：正式地址应以 productionAssetPrefix 开头；测试地址应与 feedURL 同源。
    ///
    /// 同源指协议、主机与端口都相同；端口省略时按协议的默认端口（http 80，https 443）比较。
    public func accepts(_ urlString: String) -> Bool {
        guard isTestFeed else { return urlString.hasPrefix(UpdateFeed.productionAssetPrefix) }
        guard let url = URL(string: urlString), let candidate = Origin(url), let own = Origin(feedURL) else {
            return false
        }
        return candidate == own
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
