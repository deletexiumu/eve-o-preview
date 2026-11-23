// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置版本识别与迁移（架构文档 5.2 节）。先只读出 schemaVersion，
// 版本更新时直接报错，不做结构解码；版本较旧时在 JSON 字典上逐版本升级，再整体解码。

import Foundation

/// 配置文件的版本识别与迁移。
public enum ConfigMigrator {
    /// 当前的配置结构版本。
    public static let currentSchemaVersion = 1

    /// 读出 schemaVersion，逐版本升级到当前版本后解码。
    ///
    /// - 顶层没有 `schemaVersion` 键时按当前版本处理（手写的最小配置也能读）。
    /// - 版本 0 是开发期的预发布格式，与版本 1 的结构相同，升级只改版本号。
    /// - Returns: 解码出的配置（`schemaVersion` 已是当前版本），以及迁移前的版本；没有迁移时为 nil。
    /// - Throws: 版本大于当前版本时抛 `.newerSchema`；不是 JSON 对象、版本号不是非负整数、
    ///   结构与模型不符时抛 `.encodingFailure`，调用方据此判定文件损坏。
    public static func decode(_ data: Data) throws(ConfigError) -> (config: AppConfig, migratedFrom: Int?) {
        var object = try jsonObject(from: data)
        let version = try schemaVersion(in: object)
        if version > currentSchemaVersion {
            throw .newerSchema(found: version, supported: currentSchemaVersion)
        }
        // 逐版本升级：每一步只负责从 v 到 v + 1，便于以后追加新版本。
        for from in version..<currentSchemaVersion {
            object = upgrade(object, from: from)
        }
        var config = try decodeModel(object)
        config.schemaVersion = currentSchemaVersion
        return (config, version < currentSchemaVersion ? version : nil)
    }

    /// 把数据解析成 JSON 对象（字典）。顶层不是对象时视为损坏。
    private static func jsonObject(from data: Data) throws(ConfigError) -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .encodingFailure("不是合法的 JSON：\(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw .encodingFailure("顶层不是 JSON 对象")
        }
        return object
    }

    /// 读出版本号。缺失时取当前版本；不是非负整数时视为损坏。
    ///
    /// 超出 `Int` 范围的非负整数（如 `1e20`）一定大于当前版本，直接抛 `.newerSchema`，
    /// `found` 记为 `Int.max`；带小数或为负的值仍视为损坏。
    private static func schemaVersion(in object: [String: Any]) throws(ConfigError) -> Int {
        guard let raw = object["schemaVersion"] else { return currentSchemaVersion }
        // JSONSerialization 把数字读成 NSNumber；布尔值也是 NSNumber，应排除。
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw .encodingFailure("schemaVersion 不是非负整数")
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value.rounded(.towardZero) == value else {
            throw .encodingFailure("schemaVersion 不是非负整数")
        }
        guard let version = Int(exactly: value) else {
            throw .newerSchema(found: Int.max, supported: currentSchemaVersion)
        }
        return version
    }

    /// 从版本 from 升级到 from + 1。新增版本时在这里追加一个分支。
    private static func upgrade(_ object: [String: Any], from: Int) -> [String: Any] {
        var result = object
        switch from {
        case 0:
            // 版本 0 与版本 1 的结构相同，只改版本号。
            result["schemaVersion"] = 1
        default:
            break
        }
        return result
    }

    /// 把升级后的字典重新编码，再用模型的 Codable 解码。
    private static func decodeModel(_ object: [String: Any]) throws(ConfigError) -> AppConfig {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw .encodingFailure("结构与配置模型不符：\(error)")
        }
    }
}
