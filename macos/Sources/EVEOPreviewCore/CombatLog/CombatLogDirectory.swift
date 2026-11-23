// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志目录的查找与文件的取舍（反馈文档 7.3 节）。只做纯计算，读目录与文件由平台层的 CombatLogTailer 做。
// 除了 7.2 节列出的 candidates，这里还放跟踪服务的几条纯规则，便于单元测试：
// - isRecent：只看修改时间在最近 48 小时内的文件。
// - selectFollowed：同一个收听者只跟踪文件名最大的文件，总数至多 16 个。
// - startsAtEnd：跟踪开始前已有的文件从末尾读起，跟踪开始后才建的文件从头读起。
// - readStart：文件变短时视为被截断，从头重读。

import Foundation

/// 游戏日志目录与文件的规则。
public enum CombatLogDirectory {
    /// 同时跟踪的文件数上限（7.3 节第 6 条）。
    public static let maxFollowedFiles = 16
    /// 只看修改时间在这么多秒以内的文件：48 小时（7.3 节第 2 条）。
    public static let recentWindow: Double = 48 * 3_600
    /// 判断「跟踪开始前已有的文件」时，给启动时刻留的余量：2 秒。
    public static let startGrace: Double = 2

    /// 按优先顺序返回可能的 Gamelogs 目录路径。
    ///
    /// - configured 为 nil 或空白：返回 `<home>/Documents/EVE/logs/Gamelogs`（L1）。
    /// - configured 有值：先展开开头的 `~`。最后一段是 `Gamelogs`（不区分大小写）时只返回它自己；
    ///   否则返回 `[<configured>/Gamelogs, <configured>]`，用户选 `logs` 目录或 `Gamelogs` 目录都能用。
    public static func candidates(configured: String?, homeDirectory: String) -> [String] {
        let home = trimmedTrailingSlashes(homeDirectory)
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return [home + "/Documents/EVE/logs/Gamelogs"]
        }
        var path = trimmed
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst(1)
        }
        path = trimmedTrailingSlashes(path)
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last.lowercased() == "gamelogs" {
            return [path]
        }
        let joined = path == "/" ? "/Gamelogs" : path + "/Gamelogs"
        return [joined, path]
    }

    /// 文件名是否像游戏日志：以 `.txt` 结尾（不区分大小写），不以 `.` 开头。
    public static func isLogFileName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(".txt")
    }

    /// 修改时间是否在最近 48 小时内。时间都是 1970 年以来的秒数。
    public static func isRecent(modifiedAt: Double, now: Double) -> Bool {
        now - modifiedAt <= recentWindow
    }

    /// 一个有收听者的候选文件。
    public struct Candidate: Sendable, Equatable {
        /// 文件名（不含目录）。
        public var name: String
        /// 文件头里的收听者。
        public var listener: String

        /// 用文件名与收听者建一个候选。
        public init(name: String, listener: String) {
            self.name = name
            self.listener = listener
        }
    }

    /// 选出要跟踪的文件名，按文件名从大到小排列。
    ///
    /// 同一个收听者有多个文件时只取文件名最大的（文件名以 UTC 时间开头，最大即最新，L2）；
    /// 总数超过 `limit` 时保留文件名最大的 `limit` 个。
    public static func selectFollowed(_ candidates: [Candidate], limit: Int = maxFollowedFiles) -> [String] {
        var newest: [String: String] = [:]
        for candidate in candidates {
            if let current = newest[candidate.listener], current >= candidate.name { continue }
            newest[candidate.listener] = candidate.name
        }
        return Array(newest.values.sorted(by: >).prefix(max(0, limit)))
    }

    /// 开始跟踪一个文件时是否从文件末尾读起。
    ///
    /// 文件的创建时间早于跟踪服务的启动时刻减 2 秒时，是启动前已有的文件，历史内容不读、不触发提醒；
    /// 否则是启动后才建的新文件，从头读起。读不到创建时间（nil）时按已有文件处理。
    ///
    /// 启动后建的文件也可能晚跟踪（目录权限恢复、16 个文件的上限腾出名额），从头读起会带出旧历史；
    /// 这部分由 `CombatLogReplayGuard` 按行里的时间过滤，不在这里判断。
    public static func startsAtEnd(createdAt: Double?, tailerStartedAt: Double) -> Bool {
        guard let createdAt else { return true }
        return createdAt < tailerStartedAt - startGrace
    }

    /// 一次读取的起点。文件长度小于已读偏移量时视为被截断，返回 0 与 `truncated = true`，
    /// 调用方应同时重置分行器。
    public static func readStart(offset: Int64, fileSize: Int64) -> (offset: Int64, truncated: Bool) {
        fileSize < offset ? (0, true) : (offset, false)
    }

    /// 去掉路径末尾多余的 `/`，根目录保留。
    static func trimmedTrailingSlashes(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1, result.hasSuffix("/") { result = result.dropLast() }
        return String(result)
    }
}
