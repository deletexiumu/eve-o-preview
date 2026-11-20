// SPDX-License-Identifier: GPL-3.0-or-later
//
// LogLineFormatter 的用例（v1.1 设计 5.2 节，14.1 节）：UTC 毫秒时间、级别大写、换行与回车的转义、
// 4,096 个字符的截短、一条记录只占一行。

import Foundation
import Testing
import EVEOPreviewCore

/// 文件日志一行的格式。
struct LogLineFormatterTests {
    /// 2026-11-21T04:05:06.789Z。
    private let sampleDate = Date(timeIntervalSince1970: 1_795_233_906.789)

    /// 用文字与级别建一条记录。
    private func record(_ text: String, level: LogLevel = .error, category: String = "Capture") -> LogRecord {
        LogRecord(date: sampleDate, level: level, category: category, text: text)
    }

    /// 整行的格式与设计里的例子一致。
    @Test func lineMatchesDesignExample() {
        #expect(LogLineFormatter.line(for: record("打开流失败")) == "2026-11-21T04:05:06.789Z ERROR [Capture] 打开流失败")
    }

    /// 时间是 UTC，毫秒三位，四舍五入不受浮点误差影响。
    @Test func timestampIsUTCWithMilliseconds() {
        #expect(LogLineFormatter.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(LogLineFormatter.timestamp(sampleDate) == "2026-11-21T04:05:06.789Z")
        #expect(LogLineFormatter.timestamp(Date(timeIntervalSince1970: 1_795_233_906.005)) == "2026-11-21T04:05:06.005Z")
        // 闰日与年末。
        #expect(LogLineFormatter.timestamp(Date(timeIntervalSince1970: 1_709_164_800)) == "2024-02-29T00:00:00.000Z")
        #expect(LogLineFormatter.timestamp(Date(timeIntervalSince1970: 1_798_761_599.999)) == "2026-12-31T23:59:59.999Z")
        // 1970 年以前的时刻：毫秒仍非负。
        #expect(LogLineFormatter.timestamp(Date(timeIntervalSince1970: -0.25)) == "1969-12-31T23:59:59.750Z")
    }

    /// 时间与系统的 ISO 8601 格式化结果一致（随机抽样，覆盖不同的年月日）。
    @Test func timestampAgreesWithFoundation() {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!)
        for seconds in stride(from: 946_684_800, to: 4_102_444_800, by: 7_777_777) {
            let date = Date(timeIntervalSince1970: TimeInterval(seconds) + 0.5)
            #expect(LogLineFormatter.timestamp(date) == date.formatted(style))
        }
    }

    /// 五种级别都写成大写。
    @Test func levelIsUppercased() {
        let names = LogLevel.allCases.map { level in
            LogLineFormatter.line(for: record("x", level: level)).split(separator: " ")[1]
        }
        #expect(names == ["DEBUG", "INFO", "NOTICE", "ERROR", "FAULT"])
    }

    /// 换行、回车与 "\r\n"（Swift 里是一个字符）都写成两个字符的转义，结果只有一行。
    @Test func newlinesAndCarriageReturnsAreEscaped() {
        let line = LogLineFormatter.line(for: record("a\nb\rc\r\nd"))
        #expect(line.hasSuffix(#"a\nb\rc\r\nd"#))
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(!line.unicodeScalars.contains("\n"))
        #expect(!line.unicodeScalars.contains("\r"))
    }

    /// 多行字符串（如 `String(describing: error)`）也只占一行。
    @Test func multilineTextIsOneLine() {
        let text = """
        第一行
        第二行
        """
        let line = LogLineFormatter.line(for: record(text, level: .info, category: "Config"))
        #expect(line == #"2026-11-21T04:05:06.789Z INFO [Config] 第一行\n第二行"#)
    }

    /// 超过 4,096 个字符时截短，末尾是截短标记，整行正好 4,096 个字符；不超过时原样。
    @Test func longLinesAreTruncated() {
        let prefixLength = LogLineFormatter.line(for: record("")).count
        let exact = String(repeating: "x", count: LogLineFormatter.maxLineLength - prefixLength)
        #expect(LogLineFormatter.line(for: record(exact)).count == LogLineFormatter.maxLineLength)
        #expect(!LogLineFormatter.line(for: record(exact)).hasSuffix(LogLineFormatter.truncationMarker))

        let long = LogLineFormatter.line(for: record(exact + "y"))
        #expect(long.count == LogLineFormatter.maxLineLength)
        #expect(long.hasSuffix("…[truncated]"))

        // 按字符数而不是字节数：中文每个字 3 个字节，2,000 个字不截短。
        let chinese = String(repeating: "字", count: 2000)
        #expect(LogLineFormatter.line(for: record(chinese)).hasSuffix(chinese))
        let manyChinese = LogLineFormatter.line(for: record(String(repeating: "字", count: 5000)))
        #expect(manyChinese.count == LogLineFormatter.maxLineLength)
    }

    /// 截短发生在转义之后：转义后的长度才是写进文件的长度，截短后仍没有真正的换行。
    @Test func truncationAppliesAfterEscaping() {
        let line = LogLineFormatter.line(for: record(String(repeating: "\n", count: 5000)))
        #expect(line.count == LogLineFormatter.maxLineLength)
        #expect(!line.unicodeScalars.contains("\n"))
    }
}
