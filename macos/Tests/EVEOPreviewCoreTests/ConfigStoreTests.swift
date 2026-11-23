// SPDX-License-Identifier: GPL-3.0-or-later
//
// JSONFileConfigStore 与 ConfigMigrator 的用例（架构文档 5.2 节 load() 表、10.2 节）。
// 每个用例使用独立的临时目录，结束时删除。

import Foundation
import Testing
import EVEOPreviewCore

/// 配置文件读写：load() 的 5 种情况、原子保存、备份与隔离文件的命名。
struct ConfigStoreTests {
    /// 本用例的临时目录与其中的 config.json。
    private let directory: URL
    private let store: JSONFileConfigStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eveo-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = JSONFileConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    }

    /// 删除临时目录。swift-testing 的结构体没有 deinit，所以每个用例末尾调用。
    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 目录里的文件名，排序后返回。
    private func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// 写一段文本到 config.json。
    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: store.fileURL)
    }

    /// 文件不存在：返回默认配置，警告 createdDefault，不写盘。
    @Test func missingFileReturnsDefault() throws {
        defer { cleanUp() }
        let result = try store.load()
        #expect(result.warnings == [.createdDefault])
        #expect(result.config.profiles.map(\.name) == ["Default"])
        #expect(try fileNames().isEmpty)
    }

    /// JSON 损坏：原文件改名隔离，内容保留，返回默认配置。
    @Test func corruptJSONIsQuarantined() throws {
        defer { cleanUp() }
        try writeConfig("{ not json")
        let result = try store.load()
        let names = try fileNames()
        #expect(names.count == 1)
        let name = try #require(names.first)
        #expect(name.wholeMatch(of: /config\.corrupt-\d{8}-\d{6}\.json/) != nil)
        let quarantined = directory.appendingPathComponent(name)
        #expect(result.warnings == [.corruptFileQuarantined(path: quarantined.path)])
        #expect(try String(contentsOf: quarantined, encoding: .utf8) == "{ not json")
        #expect(result.config.profiles.map(\.name) == ["Default"])
    }

    /// 合法 JSON 但结构不符（类型错误、顶层是数组）同样隔离。
    @Test(arguments: [#"{"profiles": 5}"#, "[1, 2]", #"{"schemaVersion": "one"}"#])
    func structuralMismatchIsQuarantined(text: String) throws {
        defer { cleanUp() }
        try writeConfig(text)
        let result = try store.load()
        guard case .corruptFileQuarantined = result.warnings.first else {
            Issue.record("应隔离文件，实际警告：\(result.warnings)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// 旧版本：先备份为 config.v0.bak.json（内容与原文件相同），再迁移；原文件不改写。
    @Test func olderSchemaIsBackedUpAndMigrated() throws {
        defer { cleanUp() }
        let original = #"{"schemaVersion":0,"activeProfileID":"p1","profiles":[{"id":"p1","name":"Main"}]}"#
        try writeConfig(original)
        let result = try store.load()
        #expect(result.warnings == [.migrated(from: 0, to: 1)])
        #expect(result.config.schemaVersion == 1)
        #expect(result.config.profiles.map(\.name) == ["Main"])
        #expect(try fileNames() == ["config.json", "config.v0.bak.json"])
        #expect(try String(contentsOf: store.backupURL(forVersion: 0), encoding: .utf8) == original)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == original)
    }

    /// 新版本：抛 newerSchema，文件不改名、不备份。
    @Test func newerSchemaThrowsAndLeavesFileAlone() throws {
        defer { cleanUp() }
        try writeConfig(#"{"schemaVersion":2,"profiles":"whatever"}"#)
        #expect(throws: ConfigError.newerSchema(found: 2, supported: 1)) {
            try store.load()
        }
        #expect(try fileNames() == ["config.json"])
    }

    /// 读文件失败（路径是目录）：抛 ioFailure。
    @Test func unreadablePathThrowsIOFailure() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        do {
            _ = try store.load()
            Issue.record("应抛出 ioFailure")
        } catch {
            guard case .ioFailure = error else {
                Issue.record("应抛出 ioFailure，实际：\(error)")
                return
            }
        }
    }

    /// 越界值在读取时被改正，并给出 valuesClamped 警告。
    @Test func clampedValuesProduceWarning() throws {
        defer { cleanUp() }
        try writeConfig(#"{"activeProfileID":"p1","profiles":[{"id":"p1","name":"A","thumbnail":{"opacity":5}}]}"#)
        let result = try store.load()
        #expect(result.warnings == [.valuesClamped(["profiles[0].thumbnail.opacity"])])
        #expect(result.config.profiles[0].thumbnail.opacity == 1.0)
    }

    /// 保存：创建缺失的目录，原子写入后只留下 config.json，读回结果相同且没有警告。
    @Test func saveIsAtomicAndRoundTrips() throws {
        defer { cleanUp() }
        let nested = JSONFileConfigStore(fileURL: directory.appendingPathComponent("sub/dir/config.json"))
        var config = AppConfig.makeDefault()
        config.profiles[0].hiddenCharacters = ["Pilot Alpha"]
        try nested.save(config)
        config.general.pollIntervalMs = 500
        try nested.save(config)
        let entries = try FileManager.default.contentsOfDirectory(atPath: nested.fileURL.deletingLastPathComponent().path)
        #expect(entries == ["config.json"])
        let loaded = try nested.load()
        #expect(loaded.config == config)
        #expect(loaded.warnings.isEmpty)
        // 编码用 prettyPrinted 与 sortedKeys：缩进存在，activeProfileID 排在 general 之前。
        let text = try String(contentsOf: nested.fileURL, encoding: .utf8)
        #expect(text.contains("\n  \""))
        let active = try #require(text.range(of: "\"activeProfileID\""))
        let general = try #require(text.range(of: "\"general\""))
        #expect(active.lowerBound < general.lowerBound)
    }

    /// 隔离文件名：本地时间格式化；同名已存在时追加序号。备份文件名带版本号。
    @Test func fileNaming() throws {
        defer { cleanUp() }
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 11, 20)
        (components.hour, components.minute, components.second) = (9, 5, 7)
        let date = try #require(Calendar.current.date(from: components))
        let first = store.quarantineURL(at: date)
        #expect(first.lastPathComponent == "config.corrupt-20261120-090507.json")
        try Data().write(to: first)
        #expect(store.quarantineURL(at: date).lastPathComponent == "config.corrupt-20261120-090507-2.json")
        #expect(store.backupURL(forVersion: 3).lastPathComponent == "config.v3.bak.json")
    }

    /// 默认位置在 Application Support/EVE-O Preview 下。
    @Test func defaultLocation() {
        let url = JSONFileConfigStore.defaultFileURL()
        #expect(url.lastPathComponent == "config.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "EVE-O Preview")
        #expect(url.path.contains("Application Support"))
        cleanUp()
    }

    /// 迁移器：缺失版本号按当前版本处理，不算迁移；布尔值或负数的版本号视为损坏。
    @Test func migratorVersionHandling() throws {
        defer { cleanUp() }
        let decoded = try ConfigMigrator.decode(Data(#"{"profiles":[]}"#.utf8))
        #expect(decoded.migratedFrom == nil)
        #expect(decoded.config.schemaVersion == 1)
        for text in [#"{"schemaVersion":true}"#, #"{"schemaVersion":-1}"#, #"{"schemaVersion":1.5}"#] {
            #expect(throws: ConfigError.self) { try ConfigMigrator.decode(Data(text.utf8)) }
        }
    }
}
