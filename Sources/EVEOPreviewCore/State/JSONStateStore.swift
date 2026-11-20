// SPDX-License-Identifier: GPL-3.0-or-later
//
// `state.json` 的读写（v1.1 设计 3.3 节）。与配置文件不同：读不懂时直接退回默认状态，
// 不抛错、不隔离文件，下一次保存覆盖它（状态丢了只是多检查一次更新）。
//
// 日期用 ISO 8601 字符串编码。这种写法只到秒，写盘再读回的日期会丢掉不足 1 秒的部分。

import Foundation

/// 状态文件的错误。
public enum StateStoreError: Error, Sendable, Equatable {
    /// 写文件失败。
    case ioFailure(path: String, reason: String)
    /// 编码失败。
    case encodingFailure(String)
}

/// 状态的存储。
public protocol StateStore: Sendable {
    /// 状态文件的位置。
    var fileURL: URL { get }
    /// 文件不存在、损坏或 stateVersion 不认识时返回默认状态，不抛错，不隔离文件。
    func load() -> AppState
    /// 以原子方式写入。
    func save(_ state: AppState) throws(StateStoreError)
}

/// 把状态保存为一个 JSON 文件的存储。只做文件读写，不缓存；并发调用由 App 的 `StateController` 串行化。
public struct JSONStateStore: StateStore {
    /// 状态文件的位置。
    public let fileURL: URL

    /// 用状态文件的位置建一个存储。目录可以不存在，保存时创建。
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：`~/Library/Application Support/EVE-O Preview/state.json`。
    ///
    /// 环境变量 `EVEO_STATE_DIR` 与演示模式的 `state-fake.json` 由 App 处理，不在这里。
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EVE-O Preview", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    /// 读取状态。文件不存在、读不了、不是合法 JSON、结构不符或 `stateVersion` 不是 1 时返回默认状态。
    public func load() -> AppState {
        guard let data = try? Data(contentsOf: fileURL) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(AppState.self, from: data),
              state.stateVersion == AppState.currentVersion else { return AppState() }
        return state
    }

    /// 以原子方式写入状态：先写临时文件再替换。键按字母排序，便于手工查看。
    public func save(_ state: AppState) throws(StateStoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw .encodingFailure("编码状态失败：\(error)")
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw .ioFailure(path: fileURL.path, reason: error.localizedDescription)
        }
    }
}
