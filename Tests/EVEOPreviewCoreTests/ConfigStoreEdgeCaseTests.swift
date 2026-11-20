// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置存储的补充用例（架构文档 5.2 节 load() 表）。测试方于 2026-11-20 补写，
// 覆盖原有用例没有检查的边界：空文件、迁移与夹取同时发生、同一秒内两次隔离、
// 目录不可写时隔离与保存失败、旧备份被覆盖、未知键在保存后丢失、文件不可读、
// 超出整数范围的新版本号（2026-11-20 修复后由已知问题转为普通用例）。每个用例用自己的临时目录，结束时删除并恢复权限。

import Foundation
import Testing
import EVEOPreviewCore

/// JSONFileConfigStore 的边界用例。
struct ConfigStoreEdgeCaseTests {
    /// 本用例的临时目录与其中的 config.json。
    private let directory: URL
    private let store: JSONFileConfigStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eveo-config-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = JSONFileConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    }

    /// 恢复目录与文件的权限后删除临时目录。改过权限的用例也能清理干净。
    private func cleanUp() {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        try? manager.removeItem(at: directory)
    }

    /// 目录里的文件名，排序后返回。
    private func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// 写一段文本到 config.json。
    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: store.fileURL)
    }

    /// 期望抛 ioFailure；抛别的错或没抛错都记为失败。
    /// 闭包里无法推断带类型的 throws，所以按 any Error 接收，再转成 ConfigError 判断。
    private func expectIOFailure(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("应抛出 ioFailure，实际没有抛错")
        } catch {
            guard case .ioFailure? = error as? ConfigError else {
                Issue.record("应抛出 ioFailure，实际：\(error)")
                return
            }
        }
    }

    /// 空文件（0 字节）不是合法 JSON：隔离并返回默认配置。
    @Test func emptyFileIsQuarantined() throws {
        defer { cleanUp() }
        try writeConfig("")
        let result = try store.load()
        guard case .corruptFileQuarantined = result.warnings.first else {
            Issue.record("应隔离空文件，实际警告：\(result.warnings)")
            return
        }
        #expect(result.config.profiles.map(\.name) == ["Default"])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// 旧版本且有越界值：先给 migrated，再给 valuesClamped；备份是原文件。
    @Test func migrationAndClampingTogether() throws {
        defer { cleanUp() }
        let original = #"{"schemaVersion":0,"activeProfileID":"p1","profiles":[{"id":"p1","name":"Main","thumbnail":{"opacity":5}}]}"#
        try writeConfig(original)
        let result = try store.load()
        #expect(result.warnings == [.migrated(from: 0, to: 1), .valuesClamped(["profiles[0].thumbnail.opacity"])])
        #expect(result.config.profiles[0].thumbnail.opacity == 1.0)
        #expect(try String(contentsOf: store.backupURL(forVersion: 0), encoding: .utf8) == original)
    }

    /// 已有的旧备份被本次迁移前的备份覆盖。
    @Test func staleBackupIsReplaced() throws {
        defer { cleanUp() }
        try Data("stale".utf8).write(to: store.backupURL(forVersion: 0))
        let original = #"{"schemaVersion":0,"activeProfileID":"p1","profiles":[{"id":"p1","name":"Main"}]}"#
        try writeConfig(original)
        _ = try store.load()
        #expect(try String(contentsOf: store.backupURL(forVersion: 0), encoding: .utf8) == original)
    }

    /// 连续两次读到损坏的文件：两份都保留，各自内容不变，文件名不冲突。
    @Test func twoQuarantinesKeepBothFiles() throws {
        defer { cleanUp() }
        try writeConfig("{ first")
        let first = try store.load()
        try writeConfig("{ second")
        let second = try store.load()
        let names = try fileNames()
        #expect(names.count == 2)
        for name in names {
            #expect(name.wholeMatch(of: /config\.corrupt-\d{8}-\d{6}(-\d+)?\.json/) != nil)
        }
        guard case .corruptFileQuarantined(let firstPath) = first.warnings.first,
              case .corruptFileQuarantined(let secondPath) = second.warnings.first else {
            Issue.record("两次都应隔离，实际：\(first.warnings) / \(second.warnings)")
            return
        }
        #expect(firstPath != secondPath)
        #expect(try String(contentsOfFile: firstPath, encoding: .utf8) == "{ first")
        #expect(try String(contentsOfFile: secondPath, encoding: .utf8) == "{ second")
    }

    /// 目录不可写时损坏的文件改不了名：抛 ioFailure，不返回默认配置，原文件保留。
    /// 否则之后的保存会覆盖用户可能想找回的内容。
    @Test func quarantineFailureThrowsIOFailure() throws {
        defer { cleanUp() }
        try writeConfig("{ broken")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        expectIOFailure { _ = try store.load() }
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ broken")
    }

    /// 文件没有读权限：抛 ioFailure。
    @Test func unreadableFileThrowsIOFailure() throws {
        defer { cleanUp() }
        try writeConfig("{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        expectIOFailure { _ = try store.load() }
    }

    /// 目录不可写时保存失败：抛 ioFailure，目录里不留下临时文件。
    @Test func saveIntoReadOnlyDirectoryThrows() throws {
        defer { cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        expectIOFailure { try store.save(AppConfig.makeDefault()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(try fileNames().isEmpty)
    }

    /// 读时忽略的未知键在下次保存时丢失，已知的值保留。
    @Test func unknownKeysDroppedOnSave() throws {
        defer { cleanUp() }
        try writeConfig(#"{"futureTop":1,"activeProfileID":"p1","profiles":[{"id":"p1","name":"Main","futureKey":"x","hiddenCharacters":["Pilot Alpha"]}]}"#)
        let loaded = try store.load()
        try store.save(loaded.config)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("futureTop") && !text.contains("futureKey"))
        #expect(text.contains("Pilot Alpha"))
        #expect(try store.load().config == loaded.config)
    }

    /// 当前版本、没有越界值的文件：没有警告，也不产生备份或隔离文件。
    @Test func cleanCurrentFileHasNoSideEffects() throws {
        defer { cleanUp() }
        try store.save(AppConfig.makeDefault())
        let before = try Data(contentsOf: store.fileURL)
        let result = try store.load()
        #expect(result.warnings.isEmpty)
        #expect(try fileNames() == ["config.json"])
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    /// 新版本号写成 2.0（JSON 里的浮点写法）仍按整数 2 识别为新版本。
    @Test func newerSchemaAsWholeDouble() throws {
        defer { cleanUp() }
        try writeConfig(#"{"schemaVersion":2.0}"#)
        #expect(throws: ConfigError.newerSchema(found: 2, supported: 1)) { try store.load() }
        #expect(try fileNames() == ["config.json"])
    }

    /// 规格 5.2 节 load() 表第 4 行：schemaVersion 大于当前版本时抛 newerSchema、不碰文件。
    /// 版本号超出 Int 范围（如 1e20）时同样按新版本处理，found 记为 Int.max，文件不被隔离。
    @Test func hugeSchemaVersionTreatedAsNewer() throws {
        defer { cleanUp() }
        try writeConfig(#"{"schemaVersion":100000000000000000000}"#)
        #expect(throws: ConfigError.newerSchema(found: Int.max, supported: 1)) { try store.load() }
        #expect(try fileNames() == ["config.json"])
    }

    /// 超出 Int 范围只对非负整数按新版本处理：带小数、为负、超大的负数仍视为损坏。
    @Test func malformedSchemaVersionsAreCorrupt() {
        for text in [#"{"schemaVersion":1.5}"#, #"{"schemaVersion":-1}"#, #"{"schemaVersion":-1e20}"#,
                     #"{"schemaVersion":"1"}"#, #"{"schemaVersion":true}"#] {
            do {
                _ = try ConfigMigrator.decode(Data(text.utf8))
                Issue.record("\(text) 应视为损坏，实际解码成功")
            } catch {
                guard case .encodingFailure = error else {
                    Issue.record("\(text) 应视为损坏，实际：\(error)")
                    continue
                }
            }
        }
    }
}
