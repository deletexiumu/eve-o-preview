// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置文件的顶层结构（架构文档 5.2 节）。一个 config.json 装下全部配置方案。
// 解码一律用 decodeIfPresent：缺失的键取默认值，多余的键被忽略。

import Foundation

/// 配置文件的顶层结构。
///
/// 取值范围与一致性（至少 1 个配置方案、`activeProfileID` 有效）由 `ConfigValidator` 保证，
/// 解码本身不做校验。
public struct AppConfig: Sendable, Equatable, Codable {
    /// 配置结构的版本，当前是 1（`ConfigMigrator.currentSchemaVersion`）。
    public var schemaVersion: Int
    /// 当前使用的配置方案的 id。
    public var activeProfileID: String
    /// 全部配置方案，至少 1 个，按用户看到的顺序排列。
    public var profiles: [Profile]
    /// 与配置方案无关的全局设置。
    public var general: GeneralSettings

    /// 用各字段建一份配置。
    public init(schemaVersion: Int = ConfigMigrator.currentSchemaVersion, activeProfileID: String,
                profiles: [Profile], general: GeneralSettings = GeneralSettings()) {
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.general = general
    }

    /// 默认配置：一个名为 `Default` 的配置方案，其余取默认值。每次调用生成新的 UUID。
    public static func makeDefault() -> AppConfig {
        let profile = Profile(name: Profile.defaultName)
        return AppConfig(activeProfileID: profile.id, profiles: [profile])
    }

    /// 解码时缺失的键取默认值：版本取当前版本，配置方案取空数组（由 `ConfigValidator` 补上）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ConfigMigrator.currentSchemaVersion
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? ""
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
    }
}

// MARK: - 当前配置方案

extension AppConfig {
    /// 当前配置方案在 `profiles` 里的下标。`activeProfileID` 无效时取 0；没有配置方案时返回 nil。
    public var activeProfileIndex: Int? {
        if let index = profiles.firstIndex(where: { $0.id == activeProfileID }) { return index }
        return profiles.isEmpty ? nil : 0
    }

    /// 当前配置方案。`activeProfileID` 无效时取第一个；没有任何配置方案时返回一个临时的默认方案。
    ///
    /// 经过 `ConfigValidator.normalized` 的配置总有有效的当前方案，最后一种情况只是兜底。
    public var activeProfile: Profile {
        guard let index = activeProfileIndex else { return Profile(name: Profile.defaultName) }
        return profiles[index]
    }

    /// 就地修改当前配置方案。没有任何配置方案时什么也不做。
    public mutating func updateActiveProfile(_ body: (inout Profile) -> Void) {
        guard let index = activeProfileIndex else { return }
        body(&profiles[index])
    }

    /// 按 id 查找配置方案。
    public func profile(withID id: String) -> Profile? {
        profiles.first { $0.id == id }
    }
}

/// 与配置方案无关的全局设置。
public struct GeneralSettings: Sendable, Equatable, Codable {
    /// 轮询窗口列表的间隔，单位是毫秒。新增项，默认 1000，范围 300～2000。
    public var pollIntervalMs: Int
    /// 是否已完成首次启动引导。新增项，默认 false；为 false 时启动后打开权限页。
    public var onboardingCompleted: Bool
    /// 界面语言的选项，对全部配置方案生效。第一轮反馈新增，默认 `en`（反馈文档 5.1 节）。
    public var language: LanguagePreference
    /// 游戏日志目录；nil 表示自动查找 `~/Documents/EVE/logs/Gamelogs`。第一轮反馈新增，默认 nil。
    /// 去掉首尾空白后是空串时由 `ConfigValidator` 改成 nil。
    public var eveLogDirectory: String?
    /// 是否在启动时与每 24 小时自动检查更新。v1.1 新增，默认 true（v1.1 设计 3.1 节、8.5 节）。
    public var checkForUpdates: Bool
    /// 是否在后台下载更新、退出时安装。v1.1 新增，默认 false（9.5 节）。
    /// 为真而 `checkForUpdates` 为假时不改值，行为按不检查处理。
    public var autoInstallUpdates: Bool
    /// 写进文件日志的最低级别。v1.1 新增，默认 `.info`，只接受 `.info` 与 `.debug`；
    /// 其他取值由 `ConfigValidator` 改回 `.info`（3.1 节、5.3 节）。
    public var logLevel: LogLevel

    /// 用各字段建全局设置，默认值见各属性。
    public init(pollIntervalMs: Int = 1000, onboardingCompleted: Bool = false,
                language: LanguagePreference = .en, eveLogDirectory: String? = nil,
                checkForUpdates: Bool = true, autoInstallUpdates: Bool = false, logLevel: LogLevel = .info) {
        self.pollIntervalMs = pollIntervalMs
        self.onboardingCompleted = onboardingCompleted
        self.language = language
        self.eveLogDirectory = eveLogDirectory
        self.checkForUpdates = checkForUpdates
        self.autoInstallUpdates = autoInstallUpdates
        self.logLevel = logLevel
    }

    /// 解码时缺失的键取默认值；`language` 与 `logLevel` 不认识或类型不对时取默认值，不抛错。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        pollIntervalMs = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? d.pollIntervalMs
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)
            ?? d.onboardingCompleted
        language = LenientDecoding.value(LanguagePreference.self, in: c, forKey: .language, default: d.language)
        eveLogDirectory = try c.decodeIfPresent(String.self, forKey: .eveLogDirectory)
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        autoInstallUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? d.autoInstallUpdates
        logLevel = LenientDecoding.value(LogLevel.self, in: c, forKey: .logLevel, default: d.logLevel)
    }
}
