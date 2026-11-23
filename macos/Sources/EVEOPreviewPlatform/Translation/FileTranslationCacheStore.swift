// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存文件（docs/design-intel-translate.md 7.8 节）：`~/Library/Application Support/EVE-O Preview/translation-cache.json`，
// 内容是 `{"format": 1, "entries": [...]}`。
// - 读：文件读不了、不是 JSON 或 format 不是 1 时返回空数组，从空缓存开始。
// - 写：目录权限 0700；先写同目录下的临时文件，建文件时权限就是 0600，再用 rename 原子替换，
//   文件在任何时刻都不会以更宽的权限出现。
// 文件里有聊天原文与译文（没有说话人与频道名），只留在本机，不进问题报告。读写由 App 在后台任务里调用。

import Foundation
import EVEOPreviewCore

/// 存在文件里的译文缓存。
public final class FileTranslationCacheStore: TranslationCacheStore {
    /// 文件格式的版本号。
    static let format = 1

    /// 缓存文件的位置。
    public let fileURL: URL

    /// 建存储；fileURL 默认是 Application Support 下的 translation-cache.json。
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileTranslationCacheStore.defaultURL()
    }

    /// 默认位置：`~/Library/Application Support/EVE-O Preview/translation-cache.json`。
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EVE-O Preview", isDirectory: true)
            .appendingPathComponent("translation-cache.json")
    }

    /// 文件的结构。
    private struct FileContent: Codable {
        var format: Int
        var entries: [TranslationCacheEntry]
    }

    /// 读全部条目；读不了或格式不对时返回空数组。
    public func load() -> [TranslationCacheEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = try? JSONDecoder().decode(FileContent.self, from: data),
              content.format == Self.format else { return [] }
        return content.entries
    }

    /// 原子写入全部条目（最近用过的在后）。
    public func save(_ entries: [TranslationCacheEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(FileContent(format: Self.format, entries: entries))
        let temporary = directory.appendingPathComponent(".translation-cache-\(UUID().uuidString).tmp")
        try Self.writeNewFile(data, path: temporary.path)
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// 新建文件并写入：open 时就带 0600（O_EXCL，已存在时失败），文件从一开始就只有本人可读写。
    private static func writeNewFile(_ data: Data, path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }
}
