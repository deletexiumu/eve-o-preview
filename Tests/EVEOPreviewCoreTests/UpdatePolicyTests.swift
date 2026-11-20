// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdatePolicy 的用例（v1.1 设计 8.3、8.5、8.6、9.1 节，9.3 节第 7 步，14.1 节）。

import Foundation
import Testing
import EVEOPreviewCore

/// 能否安装、是否提示、何时检查、新应用能否安装。
struct UpdatePolicyTests {
    private typealias F = UpdateFixtures

    // MARK: - comparableVersion

    /// 先取构建标签，标签解析不了时取版本号，都不行时是 nil。
    @Test func comparableVersionPrefersLabel() {
        #expect(UpdatePolicy.comparableVersion(of: F.environment(version: "1.1.0", label: "1.1.0-pr.12.abc1234"))
            == SemanticVersion("1.1.0-pr.12.abc1234"))
        #expect(UpdatePolicy.comparableVersion(of: F.environment(version: "1.1.0", label: "garbage"))
            == SemanticVersion("1.1.0"))
        #expect(UpdatePolicy.comparableVersion(of: F.environment(version: "dev", label: "dev")) == nil)
    }

    // MARK: - capability（9.1 节的 8 行）

    /// 表的每一行，按顺序取第一个成立的。
    @Test func capabilityTable() {
        let cap = UpdatePolicy.capability
        #expect(cap(F.environment(location: .notBundled), false) == .unavailable)
        #expect(cap(F.environment(kind: .unsigned), false) == .notifyOnly(.unsigned))
        #expect(cap(F.environment(kind: .unknown), false) == .notifyOnly(.unsigned))
        #expect(cap(F.environment(kind: .adHoc), false) == .notifyOnly(.adHocSignature))
        #expect(cap(F.environment(kind: .development), false) == .notifyOnly(.developmentSignature))
        #expect(cap(F.environment(location: .translocated), false) == .notifyOnly(.translocated))
        #expect(cap(F.environment(location: .readOnlyVolume), false) == .notifyOnly(.readOnlyVolume))
        #expect(cap(F.environment(writable: false), false) == .notifyOnly(.locationNotWritable))
        #expect(cap(F.environment(), false) == .canInstall)
        #expect(cap(F.environment(location: .userApplications), false) == .canInstall)
        #expect(cap(F.environment(location: .other), false) == .canInstall)
    }

    /// 开发证书在测试地址下可装；ad-hoc 与未签名在测试地址下仍不可装。
    @Test func capabilityWithTestFeed() {
        let cap = UpdatePolicy.capability
        #expect(cap(F.environment(kind: .development), true) == .canInstall)
        #expect(cap(F.environment(kind: .adHoc), true) == .notifyOnly(.adHocSignature))
        #expect(cap(F.environment(kind: .unsigned), true) == .notifyOnly(.unsigned))
        #expect(cap(F.environment(kind: .development, writable: false), true) == .notifyOnly(.locationNotWritable))
    }

    /// 顺序：没有包优先于签名；签名优先于位置。
    @Test func capabilityOrder() {
        let cap = UpdatePolicy.capability
        #expect(cap(F.environment(kind: .adHoc, location: .notBundled), false) == .unavailable)
        #expect(cap(F.environment(kind: .adHoc, location: .translocated, writable: false), false)
            == .notifyOnly(.adHocSignature))
        #expect(cap(F.environment(location: .translocated, writable: false), false) == .notifyOnly(.translocated))
    }

    // MARK: - offer（8.6 节的 6 行）

    /// 草稿、预发布（标志或版本号）、解析不了、不更新、跳过、提示。
    @Test func offerTable() {
        let running = F.environment(version: "1.1.0")
        func offer(_ release: ReleaseInfo, skipped: String? = nil, user: Bool = false,
                   env: AppEnvironment? = nil) -> UpdateOffer {
            UpdatePolicy.offer(release: release, running: env ?? running, skippedVersion: skipped, userInitiated: user)
        }
        #expect(offer(F.release("1.2.0", prerelease: true, draft: true)) == .none(.draft))
        #expect(offer(F.release("1.2.0", prerelease: true)) == .none(.prerelease))
        #expect(offer(F.release("1.2.0-beta.1")) == .none(.prerelease))
        #expect(offer(F.release("latest")) == .none(.unparsableVersion))
        #expect(offer(F.release("1.2.0"), env: F.environment(version: "x", label: "y")) == .none(.unparsableVersion))
        #expect(offer(F.release("1.1.0")) == .none(.notNewer))
        #expect(offer(F.release("1.0.9")) == .none(.notNewer))
        #expect(offer(F.release("1.1.1"), skipped: "1.1.1") == .none(.skippedByUser))
        #expect(offer(F.release("1.1.1")) == .offer(F.release("1.1.1")))
    }

    /// 跳过的版本在用户发起时仍提示；更新的版本不受跳过影响。
    @Test func skippedVersionRules() {
        let running = F.environment(version: "1.1.0")
        #expect(UpdatePolicy.offer(release: F.release("1.1.1"), running: running, skippedVersion: "1.1.1",
                                   userInitiated: true) == .offer(F.release("1.1.1")))
        #expect(UpdatePolicy.offer(release: F.release("1.1.2"), running: running, skippedVersion: "1.1.1",
                                   userInitiated: false) == .offer(F.release("1.1.2")))
    }

    /// CI 构建的标签小于同版本号的正式版，所以会收到提示；本机构建的标签等于版本号，不提示同版本。
    @Test func buildLabelDrivesOffer() {
        let pr = F.environment(version: "1.1.0", label: "1.1.0-pr.12.abc1234")
        #expect(UpdatePolicy.offer(release: F.release("1.1.0"), running: pr, skippedVersion: nil,
                                   userInitiated: false) == .offer(F.release("1.1.0")))
        let local = F.environment(version: "1.1.0")
        #expect(UpdatePolicy.offer(release: F.release("1.1.0"), running: local, skippedVersion: nil,
                                   userInitiated: true) == .none(.notNewer))
    }

    // MARK: - isCheckDue（8.5 节）

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 限流期间不检查，即使从未检查过。
    @Test func rateLimitBlocks() {
        #expect(!UpdatePolicy.isCheckDue(now: now, lastCheckAt: nil, rateLimitedUntil: now.addingTimeInterval(1),
                                         atLaunch: true))
        #expect(UpdatePolicy.isCheckDue(now: now, lastCheckAt: nil, rateLimitedUntil: now.addingTimeInterval(-1),
                                        atLaunch: false))
    }

    /// 从未检查过，或上次检查晚于现在（时钟被调回）时检查。
    @Test func neverCheckedOrClockMovedBack() {
        #expect(UpdatePolicy.isCheckDue(now: now, lastCheckAt: nil, rateLimitedUntil: nil, atLaunch: false))
        #expect(UpdatePolicy.isCheckDue(now: now, lastCheckAt: now.addingTimeInterval(600), rateLimitedUntil: nil,
                                        atLaunch: false))
    }

    /// 启动时看 1 小时，之后看 24 小时；边界上算到时。
    @Test func intervals() {
        func due(_ ago: TimeInterval, launch: Bool) -> Bool {
            UpdatePolicy.isCheckDue(now: now, lastCheckAt: now.addingTimeInterval(-ago), rateLimitedUntil: nil,
                                    atLaunch: launch)
        }
        #expect(!due(3_599, launch: true))
        #expect(due(3_600, launch: true))
        #expect(!due(3_600, launch: false))
        #expect(!due(86_399, launch: false))
        #expect(due(86_400, launch: false))
        #expect(UpdatePolicy.checkInterval == 86_400 && UpdatePolicy.minimumLaunchGap == 3_600)
    }

    // MARK: - validate（9.3 节第 7 步）

    private func staged(id: String? = "io.github.deletexiumu.eveopreview-macos", version: String? = "1.1.1",
                        label: String? = "1.1.1", executable: String? = "EVEOPreview", minimum: String? = "14.0",
                        arch: Bool = true) -> StagedAppInfo {
        StagedAppInfo(bundleIdentifier: id, version: version, buildLabel: label, executableName: executable,
                      minimumSystemVersion: minimum, hasCurrentArchitecture: arch)
    }

    private func validate(_ info: StagedAppInfo, release: String = "1.1.1", running: AppEnvironment? = nil,
                          system: String = "27.0.0") throws(UpdateError) {
        try UpdatePolicy.validate(staged: info, releaseVersion: release, running: running ?? F.environment(),
                                  systemVersion: system)
    }

    /// 全部通过。
    @Test func validatePasses() throws {
        try validate(staged())
        try validate(staged(label: nil))
        try validate(staged(minimum: nil))
        try validate(staged(minimum: "27.0"), system: "27.0")
    }

    /// 每种错误，按核对顺序。
    @Test func validateErrors() {
        #expect(throws: UpdateError.bundleMismatch("bundleIdentifier")) { try validate(staged(id: "com.other")) }
        #expect(throws: UpdateError.bundleMismatch("bundleIdentifier")) { try validate(staged(id: nil)) }
        #expect(throws: UpdateError.bundleMismatch("executableName")) { try validate(staged(executable: "Other")) }
        #expect(throws: UpdateError.versionMismatch(expected: "1.2.0", found: "1.1.1")) {
            try validate(staged(), release: "1.2.0")
        }
        #expect(throws: UpdateError.versionMismatch(expected: "1.1.1", found: "")) { try validate(staged(version: nil)) }
        #expect(throws: UpdateError.notNewer) { try validate(staged(), running: F.environment(version: "1.1.1")) }
        #expect(throws: UpdateError.notNewer) { try validate(staged(), running: F.environment(version: "1.2.0")) }
        #expect(throws: UpdateError.unsupportedSystem(minimum: "28.0")) { try validate(staged(minimum: "28.0")) }
        #expect(throws: UpdateError.unsupportedSystem(minimum: "27.0.1")) {
            try validate(staged(minimum: "27.0.1"), system: "27.0")
        }
        #expect(throws: UpdateError.bundleMismatch("architecture")) { try validate(staged(arch: false)) }
    }

    /// 副本的标签参与「比正在运行的新」：PR 构建换成同版本号的正式版可以装；标签更旧时不能装。
    @Test func validateUsesLabels() throws {
        try validate(staged(version: "1.1.0", label: "1.1.0"), release: "1.1.0",
                     running: F.environment(version: "1.1.0", label: "1.1.0-pr.12.abc1234"))
        #expect(throws: UpdateError.notNewer) {
            try validate(staged(version: "1.1.0", label: "1.1.0-dev.abc1234"), release: "1.1.0",
                         running: F.environment(version: "1.1.0", label: "1.1.0-pr.12.abc1234"))
        }
    }
}
