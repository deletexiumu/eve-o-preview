// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新功能的值类型（v1.1 设计 8.4 节）：发布信息、能否安装、下载结果、错误与界面阶段。
// 规则（解析、比较、决策）在 WP-3 的 ReleaseFeedParser、SemanticVersion、UpdatePolicy 里。

import Foundation

/// Release 的一个附件。
public struct ReleaseAsset: Sendable, Equatable, Codable {
    /// 附件名，如 `EVE-O-Preview-1.1.1.dmg`。
    public var name: String
    /// `browser_download_url`。
    public var downloadURL: String
    /// 附件声明的大小，单位是字节；没有时是 nil。
    public var size: Int?

    /// 用各字段建附件。
    public init(name: String, downloadURL: String, size: Int?) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }
}

/// 一个 Release 的发布信息（已解析、已过滤附件）。
public struct ReleaseInfo: Sendable, Equatable, Codable {
    /// tag 去掉开头的 `v` 后的规范写法，如 `1.1.1`。
    public var version: String
    /// 原始的 tag 名，如 `v1.1.1`。
    public var tagName: String
    /// Release 的标题。
    public var title: String
    /// Release 正文，最多保留 65,536 个字符。
    public var notes: String
    /// 发布页的地址（`html_url`）。
    public var pageURL: String
    /// 发布时刻；答复里没有时是 nil。
    public var publishedAt: Date?
    /// 答复里的 `prerelease`。
    public var isPrerelease: Bool
    /// 答复里的 `draft`。
    public var isDraft: Bool
    /// 通过 `UpdateFeed.accepts` 的附件，最多 100 个。
    public var assets: [ReleaseAsset]

    /// 用各字段建发布信息。
    public init(version: String, tagName: String, title: String, notes: String, pageURL: String,
                publishedAt: Date?, isPrerelease: Bool, isDraft: Bool, assets: [ReleaseAsset]) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.isDraft = isDraft
        self.assets = assets
    }
}

/// 不能自动安装的原因（9.1 节）。
public enum InstallBlocker: String, Sendable, Equatable, Codable, CaseIterable {
    /// 转移运行。
    case translocated
    /// 只读卷。
    case readOnlyVolume
    /// 当前用户不能改动应用所在的文件夹。
    case locationNotWritable
    /// 应用所在的卷不支持原子交换（`RENAME_SWAP`，不是 APFS），只能手动安装（v1.1 设计第 19 节）。
    case unsupportedVolume
    /// ad-hoc 签名，没有稳定的指定要求。
    case adHocSignature
    /// 本机证书签名的开发构建（使用测试地址时除外）。
    case developmentSignature
    /// 没有签名，或读签名失败。
    case unsigned
}

/// 这个构建能否自动安装更新（9.1 节）。
public enum InstallCapability: Sendable, Equatable {
    /// 能下载、核对并安装。
    case canInstall
    /// 只提示并打开发布页。
    case notifyOnly(InstallBlocker)
    /// 不是从 `.app` 运行，更新功能整个停用。
    case unavailable
}

/// 已下载并核对过的更新，记在 `state.json` 里。
public struct PreparedUpdate: Sendable, Equatable, Codable {
    /// 版本号。
    public var version: String
    /// 缓存目录里 dmg 的路径。
    public var imagePath: String
    /// dmg 的 SHA-256，小写十六进制。
    public var sha256: String
    /// 核对完成的时刻。
    public var preparedAt: Date

    /// 用各字段建一条记录。
    public init(version: String, imagePath: String, sha256: String, preparedAt: Date) {
        self.version = version
        self.imagePath = imagePath
        self.sha256 = sha256
        self.preparedAt = preparedAt
    }
}

/// 下载进度。
public struct UpdateProgress: Sendable, Equatable {
    /// 已收到的字节数。
    public var receivedBytes: Int64
    /// 总字节数；服务器没有给出时是 nil。
    public var totalBytes: Int64?

    /// 用各字段建进度。
    public init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

/// 安装成功的结果。
public struct InstallOutcome: Sendable, Equatable {
    /// 已安装的版本。
    public var installedVersion: String
    /// 换下来的旧包所在的暂存目录，下次启动时删除。
    public var stagingPath: String

    /// 用各字段建结果。
    public init(installedVersion: String, stagingPath: String) {
        self.installedVersion = installedVersion
        self.stagingPath = stagingPath
    }
}

/// 检查、下载与安装的错误（界面文字见 11.4 节的 `error(_:)`）。
public enum UpdateError: Error, Sendable, Equatable {
    /// 网络错误或超时，关联值是系统的说明。
    case network(String)
    /// 服务器返回了意外的状态码。
    case httpStatus(Int)
    /// 被限流，关联值是可以再试的时刻。
    case rateLimited(until: Date?)
    /// 发布信息解析不了，关联值是原因。
    case malformedFeed(String)
    /// 缺少附件，关联值是缺少的附件名。
    case assetMissing(String)
    /// 磁盘空间不足。
    case insufficientDiskSpace
    /// 下载超过 300 MiB 的上限。
    case downloadTooLarge
    /// 校验和文件无效。
    case checksumListInvalid
    /// 校验和文件里没有这个文件，关联值是文件名。
    case checksumEntryMissing(String)
    /// SHA-256 不符。
    case checksumMismatch
    /// 挂载 dmg 失败，关联值是原因。
    case imageMountFailed(String)
    /// dmg 里没有应用，或它是符号链接。
    case appMissingInImage
    /// 签名无效，关联值是 Security 框架的返回值。
    case signatureInvalid(status: Int32)
    /// 新版本不满足正在运行的应用的指定要求。
    case requirementNotSatisfied
    /// bundle id、可执行文件名或架构不符，关联值是不符的项目。
    case bundleMismatch(String)
    /// 新应用的版本号与发布的版本不同。
    case versionMismatch(expected: String, found: String)
    /// 新应用不比正在运行的新。
    case notNewer
    /// 新版本要求更高的系统版本。
    case unsupportedSystem(minimum: String)
    /// 这个构建不能自动安装。
    case blocked(InstallBlocker)
    /// 替换应用包失败，关联值是 errno。
    case swapFailed(code: Int32)
    /// 用户取消。界面不显示。
    case cancelled
}

/// 更新功能的界面阶段，由 `UpdateController` 持有，更新窗口与「通用」页按它显示。
public enum UpdatePhase: Sendable, Equatable {
    /// 还没有检查，或检查后什么也没发现、没有要显示的。
    case idle
    /// 检查中。
    case checking
    /// 已是最新，关联值是检查的时刻。
    case upToDate(checkedAt: Date)
    /// 有可用的新版本。
    case available(ReleaseInfo)
    /// 下载中。
    case downloading(ReleaseInfo, UpdateProgress)
    /// 核对中。
    case verifying(ReleaseInfo)
    /// 已下载并核对，等用户退出或点菜单项安装。
    case readyToInstall(ReleaseInfo)
    /// 安装中。
    case installing(ReleaseInfo)
    /// 安装完成，正在重新启动。
    case relaunching
    /// 失败。release 是失败时正在处理的版本，检查阶段失败时是 nil。
    case failed(UpdateError, release: ReleaseInfo?)
}
