// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名缓存文件（docs/design-intel-translate.md 6.10 节）：`~/Library/Application Support/EVE-O Preview/pilot-names.json`，
// 内容是 `{"format": 1, "entries": [...]}`，每项有 key、characterID、name、time，只存查到的角色。
// 权限 0600，原子写入：先在同一目录用 0600 建临时文件写好，再改名替换。读不了或格式不对时从空缓存开始。
// 文件里有其他玩家的角色名与角色 ID（游戏的公开数据），只留在本机，不进问题报告。日志只写条数。
// 线程：读写都是同步的，调用方在后台任务里调用（应用退出时的最后一次存盘除外）。

import Foundation
import EVEOPreviewCore

/// 存在文件里的人名缓存。
public final class FilePilotNameCacheStore: PilotNameCacheStore {
    /// 文件的格式版本。
    static let format = 1
    /// 缓存文件的位置。
    public let fileURL: URL
    private static var log: LogChannel { PlatformLog.logger("Intel") }

    /// 文件的结构。
    private struct File: Codable {
        var format: Int
        var entries: [PilotNameCacheEntry]
    }

    /// 建存储。fileURL 为 nil 时用默认位置（与 state.json 同目录）。
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? JSONStateStore.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent("pilot-names.json", isDirectory: false)
    }

    /// 读全部条目。文件不存在、读不了、格式版本不对或结构不符时返回空数组。
    public func load() -> [PilotNameCacheEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == Self.format else {
            Self.log.notice("人名缓存文件读不懂，从空缓存开始")
            return []
        }
        return file.entries
    }

    /// 写全部条目：0600 的临时文件写好后改名替换。
    public func save(_ entries: [PilotNameCacheEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(File(format: Self.format, entries: entries))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".pilot-names-\(UUID().uuidString).tmp", isDirectory: false)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        Self.log.info("人名缓存已保存：\(entries.count) 条")
    }
}
