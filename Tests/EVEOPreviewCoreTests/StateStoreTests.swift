// SPDX-License-Identifier: GPL-3.0-or-later
//
// JSONStateStore 的用例（v1.1 设计 3.3 节、14.1 节）。每个用例使用独立的临时目录，结束时删除。
// 日期用 ISO 8601 编码，只到秒，所以样例的日期都取整秒。

import Foundation
import Testing
import EVEOPreviewCore

/// 状态文件读写：读不懂时返回默认状态、往返一致、日期格式、缺键、原子写入。
struct StateStoreTests {
    /// 本用例的临时目录与其中的 state.json。
    private let directory: URL
    private let store: JSONStateStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eveo-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = JSONStateStore(fileURL: directory.appendingPathComponent("state.json"))
    }

    /// 删除临时目录。swift-testing 的结构体没有 deinit，所以每个用例末尾调用。
    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 写一段文本到 state.json。
    private func writeState(_ text: String) throws {
        try Data(text.utf8).write(to: store.fileURL)
    }

    /// 字段都填上的样例状态，日期取整秒。
    private func sampleState() -> AppState {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let release = ReleaseInfo(version: "1.1.1", tagName: "v1.1.1", title: "EVE-O Preview 1.1.1", notes: "notes",
                                  pageURL: "https://github.com/deletexiumu/eve-o-preview-macos/releases/tag/v1.1.1",
                                  publishedAt: date, isPrerelease: false, isDraft: false,
                                  assets: [ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: "https://x/y", size: nil)])
        let updates = UpdateState(lastCheckAt: date, etag: "W/\"abc\"", cachedRelease: release,
                                  rateLimitedUntil: date.addingTimeInterval(3600), skippedVersion: "1.1.0",
                                  prepared: PreparedUpdate(version: "1.1.1", imagePath: "/tmp/a.dmg",
                                                           sha256: String(repeating: "a", count: 64), preparedAt: date),
                                  lastInstall: InstallRecord(version: "1.1.0", fromVersion: "1.0.0", at: date,
                                                             succeeded: false, errorCode: "checksumMismatch"),
                                  staleStagingPath: "/private/var/folders/x/TemporaryItems/y")
        let diagnostics = DiagnosticsState(pendingCrash: PendingCrash(sessionID: "s1", appVersion: "1.1.0",
                                                                      startedAt: date, detectedAt: date,
                                                                      reportFileNames: ["EVEOPreview-1.ips"]),
                                           dismissedSessionIDs: ["s0"])
        return AppState(updates: updates, diagnostics: diagnostics)
    }

    /// 文件不存在：返回默认状态，不建文件。
    @Test func missingFileReturnsDefault() throws {
        defer { cleanUp() }
        #expect(store.load() == AppState())
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// 不是合法 JSON：返回默认状态，原文件原样留着（不隔离）。
    @Test func corruptFileReturnsDefaultAndIsKept() throws {
        defer { cleanUp() }
        try writeState("{ not json")
        #expect(store.load() == AppState())
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ not json")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    }

    /// 结构不符（字段类型不对、嵌套记录缺必需字段）：返回默认状态。
    @Test(arguments: [#"{"stateVersion":"1"}"#, #"{"updates":{"prepared":{"version":"1.1.1"}}}"#, "[]"])
    func mismatchedStructureReturnsDefault(json: String) throws {
        defer { cleanUp() }
        try writeState(json)
        #expect(store.load() == AppState())
    }

    /// stateVersion 是 2（以后的版本写的）：返回默认状态。
    @Test func newerVersionReturnsDefault() throws {
        defer { cleanUp() }
        try writeState(#"{"stateVersion":2,"updates":{"skippedVersion":"9.9.9"}}"#)
        #expect(store.load() == AppState())
    }

    /// 写入再读出，结果相同。
    @Test func roundTrip() throws {
        defer { cleanUp() }
        let state = sampleState()
        try store.save(state)
        #expect(store.load() == state)
    }

    /// 日期写成 ISO 8601 字符串，键按字母排序。
    @Test func datesAreISO8601Strings() throws {
        defer { cleanUp() }
        try store.save(sampleState())
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let updates = try #require(object["updates"] as? [String: Any])
        #expect(updates["lastCheckAt"] as? String == "2026-11-18T11:06:40Z")
        #expect(object["stateVersion"] as? Int == 1)
        // sortedKeys：顶层的键按字母顺序出现。
        let positions = ["diagnostics", "stateVersion", "updates"].compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
    }

    /// 缺键取默认值：空对象、只有部分字段。
    @Test func missingKeysUseDefaults() throws {
        defer { cleanUp() }
        try writeState("{}")
        #expect(store.load() == AppState())
        try writeState(#"{"stateVersion":1,"updates":{"skippedVersion":"1.1.1"},"diagnostics":{}}"#)
        let state = store.load()
        #expect(state.updates == UpdateState(skippedVersion: "1.1.1"))
        #expect(state.diagnostics == DiagnosticsState())
    }

    /// 原子写入：覆盖已有文件后内容完整，目录里不留临时文件；目录不存在时自动创建。
    @Test func atomicWriteLeavesCompleteFile() throws {
        defer { cleanUp() }
        try writeState("{ not json")
        try store.save(sampleState())
        #expect(store.load() == sampleState())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
        let nested = JSONStateStore(fileURL: directory.appendingPathComponent("a/b/state.json"))
        try nested.save(AppState())
        #expect(nested.load() == AppState())
    }

    /// 写到不能写的位置（路径是一个已存在的文件下面）时抛 ioFailure。
    @Test func unwritableLocationThrows() throws {
        defer { cleanUp() }
        try writeState("{}")
        let blocked = JSONStateStore(fileURL: store.fileURL.appendingPathComponent("state.json"))
        #expect(throws: StateStoreError.self) { try blocked.save(AppState()) }
    }

    /// 默认位置在 Application Support 的 EVE-O Preview 目录下。
    @Test func defaultLocation() {
        let url = JSONStateStore.defaultFileURL()
        #expect(url.lastPathComponent == "state.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "EVE-O Preview")
    }
}
