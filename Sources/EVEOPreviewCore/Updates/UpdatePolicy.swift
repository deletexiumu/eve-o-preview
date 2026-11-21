// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的决策规则（v1.1 设计 8.3、8.5、8.6、9.1 节，9.3 节第 7 步）：
// - `comparableVersion`：正在运行的版本，先取构建标签，再取版本号。
// - `capability`：这个构建能否自动安装（9.1 节的表）。
// - `offer`：一个发布版要不要提示（8.6 节的表）。
// - `isCheckDue`：自动检查是否到时（8.5 节）。
// - `validate`：暂存目录里的新应用能否安装（9.3 节第 7 步）。
// 全部是纯函数，测试在 UpdatePolicyTests。

import Foundation

/// 不提示的原因（8.6 节）。
public enum UpdateSkipReason: Sendable, Equatable {
    /// 发布的版本不比正在运行的新。
    case notNewer
    /// 用户选了「跳过此版本」，且这次是自动检查。
    case skippedByUser
    /// 预发布版本。
    case prerelease
    /// 草稿。
    case draft
    /// 发布的版本或正在运行的版本解析不了。
    case unparsableVersion
}

/// 一次检查的决定。
public enum UpdateOffer: Sendable, Equatable {
    /// 不提示，关联值是原因。
    case none(UpdateSkipReason)
    /// 提示这个发布版。
    case offer(ReleaseInfo)
}

/// 暂存目录里新应用的 `Info.plist` 与架构，由 `BundleInstaller` 读出（9.3 节第 7 步）。
public struct StagedAppInfo: Sendable, Equatable {
    /// `CFBundleIdentifier`。
    public var bundleIdentifier: String?
    /// `CFBundleShortVersionString`。
    public var version: String?
    /// `EVEOBuildLabel`。
    public var buildLabel: String?
    /// `CFBundleExecutable`。
    public var executableName: String?
    /// `LSMinimumSystemVersion`。
    public var minimumSystemVersion: String?
    /// 可执行文件是否含本机架构。
    public var hasCurrentArchitecture: Bool

    /// 用各字段建信息。
    public init(bundleIdentifier: String?, version: String?, buildLabel: String?, executableName: String?,
                minimumSystemVersion: String?, hasCurrentArchitecture: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildLabel = buildLabel
        self.executableName = executableName
        self.minimumSystemVersion = minimumSystemVersion
        self.hasCurrentArchitecture = hasCurrentArchitecture
    }
}

/// 更新的决策规则。
public enum UpdatePolicy {
    /// 自动检查的间隔：24 小时。
    public static let checkInterval = 86_400.0
    /// 启动时的检查与上一次检查至少相隔 1 小时。
    public static let minimumLaunchGap = 3_600.0

    /// 正在运行的版本：先解析构建标签，失败时解析版本号，都失败时返回 nil（更新功能按 `unparsableVersion` 处理）。
    public static func comparableVersion(of environment: AppEnvironment) -> SemanticVersion? {
        SemanticVersion(environment.buildLabel) ?? SemanticVersion(environment.version)
    }

    /// 这个构建能否自动安装（9.1 节的表，按顺序取第一个成立的）。
    ///
    /// 签名的类别排在位置之前：ad-hoc 构建放在只读卷上时，说明签名的原因更有用（换位置也装不了）。
    public static func capability(for environment: AppEnvironment, isTestFeed: Bool) -> InstallCapability {
        if environment.location == .notBundled { return .unavailable }
        switch environment.signature.kind {
        case .unsigned, .unknown: return .notifyOnly(.unsigned)
        case .adHoc: return .notifyOnly(.adHocSignature)
        case .development where !isTestFeed: return .notifyOnly(.developmentSignature)
        case .development, .release: break
        }
        if environment.location == .translocated { return .notifyOnly(.translocated) }
        if environment.location == .readOnlyVolume { return .notifyOnly(.readOnlyVolume) }
        if !environment.isLocationWritable { return .notifyOnly(.locationNotWritable) }
        if !environment.volumeSupportsSwap { return .notifyOnly(.unsupportedVolume) }
        return .canInstall
    }

    /// 一个发布版要不要提示（8.6 节的表，按顺序取第一个成立的）。
    ///
    /// 「跳过此版本」只影响自动检查：userInitiated 为真时仍提示。
    public static func offer(release: ReleaseInfo, running: AppEnvironment, skippedVersion: String?,
                             userInitiated: Bool) -> UpdateOffer {
        if release.isDraft { return .none(.draft) }
        let releaseVersion = SemanticVersion(release.version)
        if release.isPrerelease || releaseVersion?.isPrerelease == true { return .none(.prerelease) }
        guard let releaseVersion, let runningVersion = comparableVersion(of: running) else {
            return .none(.unparsableVersion)
        }
        guard runningVersion < releaseVersion else { return .none(.notNewer) }
        if !userInitiated, let skippedVersion, SemanticVersion(skippedVersion) == releaseVersion {
            return .none(.skippedByUser)
        }
        return .offer(release)
    }

    /// 自动检查是否到时（8.5 节，按顺序）：
    /// 1. `rateLimitedUntil` 晚于现在时不到时。
    /// 2. `lastCheckAt` 为 nil 或晚于现在（时钟被调回）时到时。
    /// 3. atLaunch 为真时看是否已过 1 小时，否则看是否已过 24 小时。
    public static func isCheckDue(now: Date, lastCheckAt: Date?, rateLimitedUntil: Date?, atLaunch: Bool) -> Bool {
        if let rateLimitedUntil, rateLimitedUntil > now { return false }
        guard let lastCheckAt, lastCheckAt <= now else { return true }
        let gap = atLaunch ? minimumLaunchGap : checkInterval
        return now.timeIntervalSince(lastCheckAt) >= gap
    }

    /// 核对暂存目录里的新应用：bundle id、可执行文件名、版本号等于发布版本且比正在运行的新、系统版本够、含本机架构。
    ///
    /// 依次核对，第一项不成立时抛出：
    /// 1. bundle id 与可执行文件名和正在运行的应用相同（`bundleMismatch`）。
    /// 2. `CFBundleShortVersionString` 等于发布的版本（`versionMismatch`）。
    /// 3. 副本的标签（没有时取版本号）大于正在运行的版本（`notNewer`）。
    /// 4. `LSMinimumSystemVersion` 不高于当前系统（`unsupportedSystem`）。
    /// 5. 可执行文件含本机架构（`bundleMismatch`）。
    ///
    /// - Parameter systemVersion: 当前系统的版本，如 `27.0` 或 `15.1.1`。
    public static func validate(staged: StagedAppInfo, releaseVersion: String, running: AppEnvironment,
                                systemVersion: String) throws(UpdateError) {
        guard staged.bundleIdentifier == running.bundleIdentifier else { throw .bundleMismatch("bundleIdentifier") }
        guard staged.executableName == running.executableName else { throw .bundleMismatch("executableName") }
        let found = staged.version ?? ""
        guard let foundVersion = SemanticVersion(found), let expected = SemanticVersion(releaseVersion),
              foundVersion == expected else {
            throw .versionMismatch(expected: releaseVersion, found: found)
        }
        let label = staged.buildLabel.flatMap { $0.isEmpty ? nil : $0 } ?? found
        guard let stagedVersion = SemanticVersion(label), let runningVersion = comparableVersion(of: running),
              runningVersion < stagedVersion else { throw .notNewer }
        if let minimum = staged.minimumSystemVersion, !minimum.isEmpty,
           !isSystemVersion(systemVersion, atLeast: minimum) {
            throw .unsupportedSystem(minimum: minimum)
        }
        guard staged.hasCurrentArchitecture else { throw .bundleMismatch("architecture") }
    }

    /// 系统版本是否不低于 minimum。按 `.` 分段逐段比较数值，缺的段按 0；有解析不了的段时按「不够」处理。
    static func isSystemVersion(_ system: String, atLeast minimum: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = pieces.compactMap { Int($0) }
            return numbers.count == pieces.count && !numbers.isEmpty ? numbers : nil
        }
        guard let have = parts(system), let need = parts(minimum) else { return false }
        for index in 0..<max(have.count, need.count) {
            let left = index < have.count ? have[index] : 0
            let right = index < need.count ? need[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}
