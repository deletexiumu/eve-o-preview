// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置读写的协议、错误与警告类型（架构文档 5.2 节）。
// 实现见 Config/JSONFileConfigStore.swift。

import Foundation

/// 读配置时出现、但不妨碍继续运行的情况，由设置窗口提示用户。
public enum ConfigWarning: Sendable, Equatable {
    /// 配置文件不存在，返回了默认配置（尚未写盘）。
    case createdDefault
    /// 配置从旧版本迁移到了当前版本，原文件已备份。
    case migrated(from: Int, to: Int)
    /// 配置文件损坏，已改名隔离，关联值是隔离后文件的完整路径。
    case corruptFileQuarantined(path: String)
    /// 有越界或不一致的值被改正，关联值是字段路径，如 `profiles[0].thumbnail.opacity`。
    case valuesClamped([String])
}

/// 读写配置文件时出错的那一步。界面按它显示本地化的说明，Core 不拼界面文字。
public enum ConfigFileOperation: String, Sendable, Equatable {
    /// 读配置文件。
    case read
    /// 写配置文件。
    case write
    /// 把损坏的配置文件改名隔离。
    case quarantine
    /// 迁移前备份旧版本的配置文件。
    case backup
}

/// 读写配置的错误。
public enum ConfigError: Error, Sendable, Equatable {
    /// 配置文件来自更新的版本。应用用默认配置运行，本次会话不写盘。
    case newerSchema(found: Int, supported: Int)
    /// 读写文件失败：出错的那一步、涉及的文件路径、系统给出的说明（系统按用户的语言给出）。
    case ioFailure(ConfigFileOperation, path: String, reason: String)
    /// 编码或解码失败，关联值是说明。
    ///
    /// `ConfigMigrator.decode` 抛出它表示文件内容损坏（不是合法 JSON 或结构不符），
    /// `JSONFileConfigStore.load()` 据此隔离文件，不会把它抛给调用方。
    /// 关联值是给开发者看的技术说明，只写日志，界面不显示。
    case encodingFailure(String)
}

/// `ConfigStore.load()` 的结果：已迁移、已校验的配置与警告。
public struct ConfigLoadResult: Sendable {
    /// 可直接使用的配置，已经过 `ConfigValidator.normalized`。
    public var config: AppConfig
    /// 读取过程中的警告，按发生顺序。
    public var warnings: [ConfigWarning]

    /// 用配置与警告建一个结果。
    public init(config: AppConfig, warnings: [ConfigWarning]) {
        self.config = config
        self.warnings = warnings
    }
}

/// 配置的持久化存储。
public protocol ConfigStore: Sendable {
    /// 配置文件的位置。
    var fileURL: URL { get }
    /// 读取配置。行为见 `JSONFileConfigStore.load()`。
    func load() throws(ConfigError) -> ConfigLoadResult
    /// 以原子方式写入配置；目录不存在时创建。
    func save(_ config: AppConfig) throws(ConfigError)
}
