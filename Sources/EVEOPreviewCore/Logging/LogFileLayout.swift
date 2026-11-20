// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志的目录与文件名（v1.1 设计 5.2 节）。当前文件是 `eve-o-preview.log`，
// 旧文件是 `eve-o-preview.1.log`～`eve-o-preview.4.log`，序号 1 最新。
// 本类型只管命名与列出已有文件；轮转与写入在 `RotatingLogFile`（WP-1）。

import Foundation

/// 一组轮转日志文件的位置与命名。
public struct LogFileLayout: Sendable, Equatable {
    /// 日志所在的目录。
    public var directory: URL
    /// 文件名的基名，默认 `eve-o-preview`。
    public var baseName: String

    /// 用目录与基名建一个布局。目录可以不存在。
    public init(directory: URL, baseName: String = "eve-o-preview") {
        self.directory = directory
        self.baseName = baseName
    }

    /// 默认目录：`~/Library/Logs/EVE-O Preview`。环境变量 `EVEO_LOG_DIR` 的覆盖由 App 处理，不在这里。
    public static func defaultDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("EVE-O Preview", isDirectory: true)
    }

    /// 当前文件：`<基名>.log`。
    public var currentURL: URL {
        directory.appendingPathComponent("\(baseName).log", isDirectory: false)
    }

    /// 第 index 个旧文件：`<基名>.<index>.log`，1 最新。
    public func archiveURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(baseName).\(index).log", isDirectory: false)
    }

    /// 目录里属于本布局的文件，最新的在前：当前文件，然后旧文件按序号从小到大。
    ///
    /// 只认 `<基名>.log` 与 `<基名>.<正整数>.log`，别的文件（包括序号带前导零或不是数字的）不算。
    /// 目录不存在或读不了时返回空数组。
    public func existingURLs() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var hasCurrent = false
        var archives: [Int] = []
        for name in names {
            if name == "\(baseName).log" {
                hasCurrent = true
            } else if let index = archiveIndex(of: name) {
                archives.append(index)
            }
        }
        var result = hasCurrent ? [currentURL] : []
        result += archives.sorted().map(archiveURL)
        return result
    }

    /// 文件名是 `<基名>.<正整数>.log` 时返回序号，否则返回 nil。
    private func archiveIndex(of name: String) -> Int? {
        let prefix = "\(baseName)."
        let suffix = ".log"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        // 只接受规范写法的正整数：没有前导零，不含符号。
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), digits.first != "0",
              let index = Int(digits), index > 0 else { return nil }
        return index
    }
}
