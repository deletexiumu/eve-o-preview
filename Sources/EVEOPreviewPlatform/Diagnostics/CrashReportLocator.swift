// SPDX-License-Identifier: GPL-3.0-or-later
//
// 列出与读取系统的崩溃报告（v1.1 设计 6.2 节）。目录是 `~/Library/Logs/DiagnosticReports/` 及其 `Retired/` 子目录。
//
// - 列出：文件名以可执行文件名开头的普通文件，带修改时间、大小与第一行（最多 4,096 字节）。
//   严格的文件名规则、时间窗口与文件头的判断在 Core 的 `CrashReportMatcher`，这里只做便宜的前缀筛选。
// - 两个目录里有同名文件时只取前一个目录里的（读取时也按同样的顺序找）。
// - 读取：只接受不含 `/` 的文件名（名字来自 state.json，不能让它指到别的目录），不跟随符号链接。
// - 目录或文件读不了（不存在、没有权限）时返回空数组或 nil，不报错：崩溃提示不出现，手动报告照常可用（V18）。
//
// 2026-11-21 在 macOS 27.0.1 上核对过：报告的权限是 0600、属于当前用户，目录是 0700（V17）。

import Foundation
import EVEOPreviewCore

/// 崩溃报告目录的读取。
struct CrashReportLocator: Sendable {
    /// 第一行最多读多少字节。
    static let firstLineMaxBytes = 4096

    /// 要查找的目录，按顺序。
    let directories: [URL]

    /// 默认目录：`~/Library/Logs/DiagnosticReports` 与它的 `Retired` 子目录。
    static func defaultDirectories() -> [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let reports = library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// 用目录列表建读取器，默认是系统的崩溃报告目录。
    init(directories: [URL] = CrashReportLocator.defaultDirectories()) {
        self.directories = directories
    }

    /// 文件名以 executableName 开头的报告，带修改时间、大小与第一行。
    func candidates(executableName: String) -> [CrashReportCandidate] {
        guard !executableName.isEmpty else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var seen = Set<String>()
        var result: [CrashReportCandidate] = []
        for directory in directories {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles])
            } catch {
                // 目录不存在是常态（如没有 Retired），不记。目录在但列不出（如没有权限，V18）时记一条，
                // 否则日志里分不清「没有报告」与「读不了」。
                if FileManager.default.fileExists(atPath: directory.path) {
                    PlatformLog.logger("CrashReports").notice("列不出崩溃报告目录：\(directory.path, privacy: .public)，\(String(describing: error), privacy: .public)")
                }
                continue
            }
            for url in urls {
                let name = url.lastPathComponent
                guard name.hasPrefix(executableName), !seen.contains(name),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate else { continue }
                seen.insert(name)
                result.append(CrashReportCandidate(fileName: name, modifiedAt: modified, byteCount: values.fileSize ?? 0,
                                                   firstLine: CrashReportLocator.firstLine(of: url)))
            }
        }
        return result
    }

    /// 读一个报告，最多 maxBytes 字节；找不到或读不了时返回 nil。
    func read(named fileName: String, maxBytes: Int) -> Data? {
        guard CrashReportLocator.isPlainFileName(fileName), maxBytes > 0, let url = locate(fileName) else { return nil }
        return CrashReportLocator.readPrefix(of: url, maxBytes: maxBytes)
    }

    /// 文件名是否只是一个名字：不空，不含 `/`，不是 `.` 或 `..`。
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// 按目录顺序找到第一个同名的普通文件（不是符号链接）。
    private func locate(_ fileName: String) -> URL? {
        for directory in directories {
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            return url
        }
        return nil
    }

    /// 文件的第一行（不含换行符），最多 `firstLineMaxBytes` 字节；读不了时是 nil。
    private static func firstLine(of url: URL) -> String? {
        guard let data = readPrefix(of: url, maxBytes: firstLineMaxBytes) else { return nil }
        let lineBytes = data.prefix { $0 != UInt8(ascii: "\n") }
        return String(decoding: lineBytes, as: UTF8.self)
    }

    /// 读文件开头最多 maxBytes 字节。
    private static func readPrefix(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes) ?? Data()
    }
}
