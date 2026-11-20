// SPDX-License-Identifier: GPL-3.0-or-later
//
// 基于 JSON 文件的配置存储（架构文档 5.2 节 load() 表）：
// 文件不存在返回默认配置；损坏时改名隔离；旧版本先备份再迁移；新版本抛错且不碰文件。

import Foundation

/// 把配置保存为一个 JSON 文件的存储。
///
/// 只做文件读写，不缓存；并发调用由 App 的 `ConfigController` 串行化。
public struct JSONFileConfigStore: ConfigStore {
    /// 配置文件的位置。
    public let fileURL: URL

    /// 用配置文件的位置建一个存储。目录可以不存在，保存时创建。
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：`~/Library/Application Support/EVE-O Preview/config.json`。
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EVE-O Preview", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// 读取配置，结果已迁移到当前版本并经过 `ConfigValidator.normalized`。
    ///
    /// | 情况 | 行为 |
    /// | --- | --- |
    /// | 文件不存在 | 返回默认配置，警告 `createdDefault`，不写盘 |
    /// | JSON 损坏或结构不符 | 原文件改名为 `config.corrupt-<yyyyMMdd-HHmmss>.json`，返回默认配置 |
    /// | 版本较旧 | 先复制为 `config.v<旧版本>.bak.json`，再迁移，警告 `migrated`；迁移结果不写盘 |
    /// | 版本较新 | 抛 `.newerSchema`，文件不改名、不备份 |
    /// | 读文件失败（含路径是目录） | 抛 `.ioFailure` |
    ///
    /// 校验改正了值时追加警告 `valuesClamped`。
    public func load() throws(ConfigError) -> ConfigLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ConfigLoadResult(config: AppConfig.makeDefault(), warnings: [.createdDefault])
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw .ioFailure(.read, path: fileURL.path, reason: error.localizedDescription)
        }

        var warnings: [ConfigWarning] = []
        let decoded: (config: AppConfig, migratedFrom: Int?)
        do {
            decoded = try ConfigMigrator.decode(data)
        } catch {
            guard case .encodingFailure = error else { throw error }
            // 内容损坏：隔离原文件，让用户还能找回，然后用默认配置继续。
            let quarantined = try quarantineCorruptFile()
            warnings.append(.corruptFileQuarantined(path: quarantined.path))
            return finish(AppConfig.makeDefault(), warnings: warnings)
        }

        if let oldVersion = decoded.migratedFrom {
            try backUpBeforeMigration(version: oldVersion)
            warnings.append(.migrated(from: oldVersion, to: ConfigMigrator.currentSchemaVersion))
        }
        return finish(decoded.config, warnings: warnings)
    }

    /// 以原子方式写入配置：先写临时文件再替换，写到一半崩溃也不会留下半个文件。
    ///
    /// 编码用 `prettyPrinted` 与 `sortedKeys`，便于手工查看和比较；读时忽略的未知键在这里丢失。
    public func save(_ config: AppConfig) throws(ConfigError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw .encodingFailure("编码配置失败：\(error)")
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw .ioFailure(.write, path: fileURL.path, reason: error.localizedDescription)
        }
    }

    // MARK: - 文件命名

    /// 损坏文件隔离后的位置：与配置文件同目录，名为 `<基名>.corrupt-<yyyyMMdd-HHmmss>.json`。
    ///
    /// 时间按本地时区格式化。同一秒内已有同名文件时，在时间后追加 `-2`、`-3` 等序号。
    public func quarantineURL(at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(baseName).corrupt-\(formatter.string(from: date))"
        return uniqueURL(stem: stem)
    }

    /// 迁移前备份的位置：与配置文件同目录，名为 `<基名>.v<旧版本>.bak.json`。已存在时覆盖。
    public func backupURL(forVersion version: Int) -> URL {
        directory.appendingPathComponent("\(baseName).v\(version).bak.json", isDirectory: false)
    }

    // MARK: - 私有

    /// 配置文件所在目录。
    private var directory: URL { fileURL.deletingLastPathComponent() }

    /// 配置文件去掉扩展名后的名字，默认是 `config`。
    private var baseName: String { fileURL.deletingPathExtension().lastPathComponent }

    /// 在 stem 后加 `.json`；重名时追加序号，直到找到不存在的文件名。
    private func uniqueURL(stem: String) -> URL {
        var candidate = directory.appendingPathComponent("\(stem).json", isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix).json", isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    /// 把损坏的配置文件改名隔离，返回新位置。改名失败时抛 `.ioFailure`，
    /// 否则下次保存会覆盖用户可能想找回的内容。
    private func quarantineCorruptFile() throws(ConfigError) -> URL {
        let target = quarantineURL(at: Date())
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
        } catch {
            throw .ioFailure(.quarantine, path: fileURL.path, reason: error.localizedDescription)
        }
        return target
    }

    /// 迁移前把原文件复制一份。备份失败时抛 `.ioFailure`，不在没有备份的情况下迁移。
    private func backUpBeforeMigration(version: Int) throws(ConfigError) {
        let target = backupURL(forVersion: version)
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: target.path) {
                try manager.removeItem(at: target)
            }
            try manager.copyItem(at: fileURL, to: target)
        } catch {
            throw .ioFailure(.backup, path: target.path, reason: error.localizedDescription)
        }
    }

    /// 校验配置，有改正时追加 `valuesClamped` 警告，组装结果。
    private func finish(_ config: AppConfig, warnings: [ConfigWarning]) -> ConfigLoadResult {
        let normalized = ConfigValidator.normalized(config)
        var allWarnings = warnings
        if !normalized.clamped.isEmpty {
            allWarnings.append(.valuesClamped(normalized.clamped))
        }
        return ConfigLoadResult(config: normalized.config, warnings: allWarnings)
    }
}
