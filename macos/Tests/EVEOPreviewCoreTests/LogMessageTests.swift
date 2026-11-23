// SPDX-License-Identifier: GPL-3.0-or-later
//
// LogMessage、LogLevel 与 LogFileLayout 的用例（v1.1 设计 5.1、5.2 节，14.1 节）。
// 插值的默认隐私应与 os.Logger 相同：整数、浮点数、布尔值公开，字符串与其他类型私有。

import Foundation
import Testing
import EVEOPreviewCore

/// 日志消息：分段、默认隐私、显式标注、浮点格式、两种渲染。
struct LogMessageTests {
    /// 用于「其他类型」插值的样例类型。
    private struct Probe: CustomStringConvertible {
        var description: String { "probe-42" }
    }

    /// 字面量与插值按顺序分段，相邻字面量合并，空字面量不保存。
    @Test func segmentsFollowSourceOrder() {
        let name = "Alpha"
        let message: LogMessage = "客户端 \(name) 的数量 \(3)"
        #expect(message.segments == [.literal("客户端 "), .value("Alpha", .private), .literal(" 的数量 "),
                                     .value("3", .public)])
        let plain: LogMessage = "只有字面量"
        #expect(plain.segments == [.literal("只有字面量")])
        let empty: LogMessage = ""
        #expect(empty.segments.isEmpty)
        let adjacent: LogMessage = "\(1)\(2)"
        #expect(adjacent.segments == [.value("1", .public), .value("2", .public)])
    }

    /// 整数（含 Int32、UInt32）、浮点数、布尔值默认公开。
    @Test func numbersAndBoolsArePublicByDefault() {
        let pid: Int32 = 90_001
        let windowID: UInt32 = 70_001
        let ratio = 1.5
        let message: LogMessage = "\(pid) \(windowID) \(ratio) \(true)"
        #expect(message.rendered(includingPrivate: false) == "90001 70001 1.5 true")
        let single: Float = 0.25
        let floats: LogMessage = "\(single) \(ratio, privacy: .public) \(ratio, privacy: .private)"
        #expect(floats.segments == [.value("0.25", .public), .literal(" "), .value("1.5", .public), .literal(" "),
                                    .value("1.5", .private)])
    }

    /// 字符串与其他类型默认私有，渲染成 `<private>`。
    @Test func stringsAndOtherTypesArePrivateByDefault() {
        let title = "EVE - Pilot"
        let message: LogMessage = "标题 \(title)，值 \(Probe())，数组 \([1, 2])"
        #expect(message.rendered(includingPrivate: false) == "标题 <private>，值 <private>，数组 <private>")
        #expect(message.rendered(includingPrivate: true) == "标题 EVE - Pilot，值 probe-42，数组 [1, 2]")
    }

    /// 显式的 privacy 覆盖默认值。
    @Test func explicitPrivacyOverridesDefault() {
        let path = "/Users/x/config.json"
        let count = 7
        let message: LogMessage = "\(path, privacy: .public) \(count, privacy: .private) \(Probe(), privacy: .public)"
        #expect(message.rendered(includingPrivate: false) == "/Users/x/config.json <private> probe-42")
        let flag: LogMessage = "\(false, privacy: .private)"
        #expect(flag.rendered(includingPrivate: false) == "<private>")
    }

    /// `format: .fixed(precision:)` 固定小数位，可与 privacy 同用；负的位数按 0 处理。
    @Test func fixedPrecisionFormat() {
        let value = 2.0 / 3.0
        let message: LogMessage = "\(value, format: .fixed(precision: 2)) \(value, format: .fixed(precision: 0))"
        #expect(message.rendered(includingPrivate: false) == "0.67 1")
        let hidden: LogMessage = "\(value, format: .fixed(precision: 3), privacy: .private)"
        #expect(hidden.rendered(includingPrivate: true) == "0.667")
        #expect(hidden.rendered(includingPrivate: false) == "<private>")
        let negative: LogMessage = "\(1.25, format: .fixed(precision: -1))"
        #expect(negative.rendered(includingPrivate: false) == "1")
    }

    /// 多行字符串（含行尾 `\` 续行）的插值与单行相同。
    @Test func multilineLiteral() {
        let added = 2
        let removed = 1
        let message: LogMessage = """
            客户端变化：新增 \(added)，\
            移除 \(removed)
            """
        #expect(message.rendered(includingPrivate: false) == "客户端变化：新增 2，移除 1")
    }

    /// 私有值的占位符是 `<private>`。
    @Test func placeholderText() {
        #expect(LogMessage.privatePlaceholder == "<private>")
    }
}

/// 日志级别：按严重程度排序，不按原始值的字母顺序。
struct LogLevelTests {
    /// 顺序是 debug < info < notice < error < fault；按字母序 error 会排在 info 前面，这里排除这种错误。
    @Test func orderedBySeverity() {
        #expect(LogLevel.allCases == [.debug, .info, .notice, .error, .fault])
        #expect(LogLevel.allCases.sorted() == [.debug, .info, .notice, .error, .fault])
        #expect(LogLevel.info < .error)
        #expect(LogLevel.error >= .info)
        #expect(!(LogLevel.fault < .debug))
        #expect(LogLevel.debug < .info)
    }

    /// 原始值是小写英文，与配置文件的写法一致。
    @Test func rawValues() {
        #expect(LogLevel.allCases.map(\.rawValue) == ["debug", "info", "notice", "error", "fault"])
    }
}

/// 文件日志的命名（v1.1 设计 5.2 节）。轮转本身由 WP-1 的 RotatingLogFileTests 覆盖，这里只测命名与列出。
struct LogFileLayoutTests {
    /// 本用例的临时目录。
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("eveo-log-layout-tests-\(UUID().uuidString)", isDirectory: true)

    /// 在临时目录里建空文件。
    private func touch(_ names: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }
    }

    /// 当前文件与旧文件的名字。
    @Test func fileNames() {
        let layout = LogFileLayout(directory: directory)
        #expect(layout.baseName == "eve-o-preview")
        #expect(layout.currentURL.lastPathComponent == "eve-o-preview.log")
        #expect(layout.archiveURL(1).lastPathComponent == "eve-o-preview.1.log")
        #expect(layout.archiveURL(4).deletingLastPathComponent().path == directory.path)
        #expect(LogFileLayout.defaultDirectory().path.hasSuffix("/Library/Logs/EVE-O Preview"))
    }

    /// 当前文件在前，旧文件按序号从小到大（1 最新）；别的文件不算。
    @Test func existingURLsOrder() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch(["eve-o-preview.3.log", "eve-o-preview.log", "eve-o-preview.10.log", "eve-o-preview.1.log",
                   "eve-o-preview.01.log", "eve-o-preview.x.log", "eve-o-preview.0.log", "eve-o-preview..log",
                   "other.1.log", "eve-o-preview.1.txt", "eve-o-preview.-1.log"])
        let names = LogFileLayout(directory: directory).existingURLs().map(\.lastPathComponent)
        #expect(names == ["eve-o-preview.log", "eve-o-preview.1.log", "eve-o-preview.3.log", "eve-o-preview.10.log"])
    }

    /// 没有当前文件时只列旧文件；目录不存在时返回空数组。
    @Test func missingCurrentOrDirectory() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(LogFileLayout(directory: directory).existingURLs().isEmpty)
        try touch(["eve-o-preview.2.log"])
        #expect(LogFileLayout(directory: directory).existingURLs().map(\.lastPathComponent) == ["eve-o-preview.2.log"])
    }
}
