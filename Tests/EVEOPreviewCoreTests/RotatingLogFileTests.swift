// SPDX-License-Identifier: GPL-3.0-or-later
//
// RotatingLogFile 与 LogFileLayout.existingURLs 的用例（v1.1 设计 5.2 节，14.1 节）：
// 目录不存在时创建、追加到已有文件、到上限时轮转且序号递增、超过旧文件个数时删最旧的、
// 一行就超过上限时仍写入、权限 0600 与 0700。每个用例使用独立的临时目录，结束时删除。
// 上限用很小的值（几十字节），不用真的写 1 MiB。

import Foundation
import Testing
import EVEOPreviewCore

/// 带轮转的日志文件。
struct RotatingLogFileTests {
    /// 本用例的临时目录（不预先创建，日志目录在它下面）。
    private let root: URL
    /// 日志所在的目录，第一次写入时才创建。
    private let layout: LogFileLayout

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eveo-log-tests-\(UUID().uuidString)", isDirectory: true)
        layout = LogFileLayout(directory: root.appendingPathComponent("Logs/EVE-O Preview", isDirectory: true))
    }

    /// 删除临时目录。swift-testing 的结构体没有 deinit，所以每个用例末尾调用。
    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 读一个文件的全文；不存在时返回 nil。
    private func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// 目录里的文件名，排序后返回。
    private func fileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.directory.path)) ?? []).sorted()
    }

    /// 文件或目录的权限位。
    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    /// 目录不存在时连同上级目录一起创建，目录权限 0700，文件权限 0600，每行末尾一个换行符。
    @Test func createsDirectoryAndFileWithPermissions() throws {
        defer { cleanUp() }
        let file = RotatingLogFile(layout: layout, policy: .standard)
        try file.append("第一行")
        try file.append("second")
        file.close()
        #expect(contents(layout.currentURL) == "第一行\nsecond\n")
        #expect(try permissions(layout.directory) == 0o700)
        #expect(try permissions(layout.currentURL) == 0o600)
    }

    /// 已有文件时追加到末尾，不在打开时轮转；已有文件的权限改成 0600。
    @Test func appendsToExistingFileWithoutRotatingOnOpen() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
        try Data("old run\n".utf8).write(to: layout.currentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: layout.currentURL.path)
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 100, maxArchives: 4))
        try file.append("new run")
        file.close()
        #expect(contents(layout.currentURL) == "old run\nnew run\n")
        #expect(fileNames() == ["eve-o-preview.log"])
        #expect(try permissions(layout.currentURL) == 0o600)
    }

    /// 上限按字节算（含换行符）：正好等于上限时不轮转，多 1 个字节就轮转。
    @Test func rotatesWhenNextLineWouldExceedLimit() throws {
        defer { cleanUp() }
        // 每行 "aaaa\n" 5 个字节，上限 10 字节：两行正好 10 字节。
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 10, maxArchives: 4))
        try file.append("aaaa")
        try file.append("bbbb")
        #expect(fileNames() == ["eve-o-preview.log"])
        try file.append("cccc")
        file.close()
        #expect(contents(layout.archiveURL(1)) == "aaaa\nbbbb\n")
        #expect(contents(layout.currentURL) == "cccc\n")
    }

    /// 连续轮转时序号递增：最新的旧文件总是 .1；超过 4 个旧文件时删掉最旧的，不出现 .5。
    @Test func archivesShiftAndOldestIsDeleted() throws {
        defer { cleanUp() }
        // 每行 "line-N\n" 7 个字节，上限 7 字节：每行一个文件。
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 7, maxArchives: 4))
        for index in 0..<7 {
            try file.append("line-\(index)")
        }
        file.close()
        #expect(fileNames() == ["eve-o-preview.1.log", "eve-o-preview.2.log", "eve-o-preview.3.log",
                                "eve-o-preview.4.log", "eve-o-preview.log"])
        #expect(contents(layout.currentURL) == "line-6\n")
        #expect(contents(layout.archiveURL(1)) == "line-5\n")
        #expect(contents(layout.archiveURL(4)) == "line-2\n")
    }

    /// 一行就超过上限时仍写进空文件；下一行再轮转。
    @Test func oversizedLineIsWrittenToEmptyFile() throws {
        defer { cleanUp() }
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 4, maxArchives: 2))
        try file.append("much longer than four bytes")
        #expect(contents(layout.currentURL) == "much longer than four bytes\n")
        #expect(fileNames() == ["eve-o-preview.log"])
        try file.append("x")
        file.close()
        #expect(contents(layout.archiveURL(1)) == "much longer than four bytes\n")
        #expect(contents(layout.currentURL) == "x\n")
    }

    /// 旧文件序号有空缺时，存在的照常后移，不补齐空缺。
    @Test func gapsInArchiveNumbersAreKept() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
        try Data("current\n".utf8).write(to: layout.currentURL)
        try Data("three\n".utf8).write(to: layout.archiveURL(3))
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 8, maxArchives: 4))
        try file.append("next")
        file.close()
        #expect(fileNames() == ["eve-o-preview.1.log", "eve-o-preview.4.log", "eve-o-preview.log"])
        #expect(contents(layout.archiveURL(1)) == "current\n")
        #expect(contents(layout.archiveURL(4)) == "three\n")
    }

    /// close 之后再 append 会重新打开并接着写，大小从文件里重新读出。
    @Test func reopensAfterClose() throws {
        defer { cleanUp() }
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 10, maxArchives: 1))
        try file.append("aaaa")
        file.close()
        try file.append("bbbb")
        file.close()
        #expect(contents(layout.currentURL) == "aaaa\nbbbb\n")
        try file.append("cccc")
        file.close()
        #expect(contents(layout.archiveURL(1)) == "aaaa\nbbbb\n")
        #expect(contents(layout.currentURL) == "cccc\n")
    }

    /// 目录建不了（上级是一个普通文件）时抛错，不崩溃。
    @Test func failsWhenDirectoryCannotBeCreated() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("Logs")
        try Data("not a directory".utf8).write(to: blocker)
        let file = RotatingLogFile(layout: layout, policy: .standard)
        #expect(throws: RotatingLogFileError.self) { try file.append("x") }
    }

    /// existingURLs：最新的在前，当前文件然后 .1、.2……；别的文件不算。
    @Test func existingURLsAreNewestFirst() throws {
        defer { cleanUp() }
        let file = RotatingLogFile(layout: layout, policy: LogRotationPolicy(maxFileBytes: 7, maxArchives: 4))
        for index in 0..<4 {
            try file.append("line-\(index)")
        }
        file.close()
        try Data().write(to: layout.directory.appendingPathComponent("other.log"))
        try Data().write(to: layout.directory.appendingPathComponent("eve-o-preview.01.log"))
        #expect(layout.existingURLs().map(\.lastPathComponent) == ["eve-o-preview.log", "eve-o-preview.1.log",
                                                                   "eve-o-preview.2.log", "eve-o-preview.3.log"])
    }

    /// 默认参数是设计里的 1 MiB 与 4 个旧文件。
    @Test func standardPolicyMatchesDesign() {
        #expect(LogRotationPolicy.standard == LogRotationPolicy(maxFileBytes: 1_048_576, maxArchives: 4))
    }
}
