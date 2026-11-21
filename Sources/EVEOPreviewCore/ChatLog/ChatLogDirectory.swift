// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志目录的查找与文件的取舍（docs/design-intel-translate.md 5.2 节、5.4 节）。只做纯计算，
// 读目录与文件由平台层的 ChatLogTailer 做。
// - candidates：general.eveLogDirectory 可能指向 logs、Gamelogs 或 Chatlogs，都换算成 Chatlogs 的候选。
// - gameLogCandidates：位置线索要读的游戏日志目录，交给 CombatLogDirectory.candidates 之前把 Chatlogs 换成 Gamelogs。
// - parseFileName：文件名是 `<频道名>_<yyyyMMdd>_<HHmmss>_<数字>.txt`，频道名里可以有 `.`、`+`、`_`，所以从右边解析（C1）。
// - selectFollowed：每个（收听者，频道 ID）只跟踪最新的文件，至多 48 个。
// - alignedOffset、backfillStart：UTF-16 的偏移量都取偶数，否则之后的每个字符都错位。

import Foundation

/// 聊天日志目录与文件的规则。
public enum ChatLogDirectory {
    /// 文件名解析出的三部分。
    public struct FileName: Sendable, Equatable {
        /// 文件名里的频道名。
        public var channel: String
        /// 时间戳 `yyyyMMdd_HHmmss`，可按字符串比较新旧。
        public var stamp: String
        /// 末尾的数字。
        public var suffix: String

        /// 用各部分建一个结果。
        public init(channel: String, stamp: String, suffix: String) {
            self.channel = channel
            self.stamp = stamp
            self.suffix = suffix
        }
    }

    /// 一个读过文件头的候选文件。
    public struct Candidate: Sendable, Equatable {
        /// 文件名（不含目录）。
        public var name: String
        /// 文件名里的时间戳 `yyyyMMdd_HHmmss`。
        public var stamp: String
        /// 文件头的收听者。
        public var listener: String
        /// 文件头的 Channel ID。
        public var channelID: String

        /// 用各字段建一个候选。
        public init(name: String, stamp: String, listener: String, channelID: String) {
            self.name = name
            self.stamp = stamp
            self.listener = listener
            self.channelID = channelID
        }
    }

    /// 同时跟踪的聊天日志文件数上限。
    public static let maxFollowedFiles = 48
    /// 只看修改时间在这么多秒以内的文件：48 小时。
    public static let recentSeconds = 172_800.0

    /// 按优先顺序返回可能的 Chatlogs 目录路径。configured 是 `general.eveLogDirectory`：
    /// - nil 或空白：返回 `<home>/Documents/EVE/logs/Chatlogs`（C1）。
    /// - 先展开开头的 `~`，去掉末尾的 `/`。最后一段是 `Chatlogs`（不区分大小写）：只返回它自己。
    /// - 最后一段是 `Gamelogs`：返回同级的 `Chatlogs`。
    /// - 其他：返回 `[<configured>/Chatlogs, <configured>]`。
    public static func candidates(configured: String?, homeDirectory: String) -> [String] {
        let home = CombatLogDirectory.trimmedTrailingSlashes(homeDirectory)
        guard let path = expanded(configured, home: home) else {
            return [home + "/Documents/EVE/logs/Chatlogs"]
        }
        switch lastComponent(path).lowercased() {
        case "chatlogs":
            return [path]
        case "gamelogs":
            return [sibling(of: path, named: "Chatlogs")]
        default:
            return [joined(path, "Chatlogs"), path]
        }
    }

    /// 游戏日志目录的候选（位置线索用，5.6 节）：configured 的最后一段是 `Chatlogs` 时先换成同级的 `Gamelogs`，
    /// 再交给 `CombatLogDirectory.candidates`。
    public static func gameLogCandidates(configured: String?, homeDirectory: String) -> [String] {
        let home = CombatLogDirectory.trimmedTrailingSlashes(homeDirectory)
        guard let path = expanded(configured, home: home), lastComponent(path).lowercased() == "chatlogs" else {
            return CombatLogDirectory.candidates(configured: configured, homeDirectory: homeDirectory)
        }
        return CombatLogDirectory.candidates(configured: sibling(of: path, named: "Gamelogs"),
                                             homeDirectory: homeDirectory)
    }

    /// 解析聊天日志的文件名。以 `.txt` 结尾（不区分大小写）；去掉扩展名后从右边取 3 段：一段数字、6 位数字、
    /// 8 位数字，各由 `_` 隔开；再往左的全部内容是频道名，不能为空。不符合时返回 nil。
    public static func parseFileName(_ name: String) -> FileName? {
        guard name.count > 4, name.lowercased().hasSuffix(".txt") else { return nil }
        let base = String(name.dropLast(4))
        let parts = base.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let suffix = parts[parts.count - 1]
        let time = parts[parts.count - 2]
        let date = parts[parts.count - 3]
        guard isDigits(suffix, count: nil), isDigits(time, count: 6), isDigits(date, count: 8) else { return nil }
        let channel = parts[..<(parts.count - 3)].joined(separator: "_")
        guard !channel.isEmpty else { return nil }
        return FileName(channel: channel, stamp: "\(date)_\(time)", suffix: String(suffix))
    }

    /// 选出要跟踪的文件名：每个（收听者，频道 ID）只留时间戳最大的文件（相同时取文件名大的），
    /// 再按时间戳从新到旧取前 limit 个。
    public static func selectFollowed(_ candidates: [Candidate], limit: Int = maxFollowedFiles) -> [String] {
        /// 分组的键：收听者与频道 ID。
        struct Key: Hashable { var listener: String; var channelID: String }
        var newest: [Key: Candidate] = [:]
        for candidate in candidates {
            let key = Key(listener: candidate.listener, channelID: candidate.channelID)
            if let current = newest[key], !isNewer(candidate, than: current) { continue }
            newest[key] = candidate
        }
        let ordered = newest.values.sorted { isNewer($0, than: $1) }
        return Array(ordered.prefix(max(0, limit)).map(\.name))
    }

    /// 把字节偏移量向下取成偶数（UTF-16 的码元边界）。负数取 0。
    public static func alignedOffset(_ offset: Int64) -> Int64 {
        max(0, offset) & ~1
    }

    /// 补读的起点：文件长度减 maxBytes，不小于 0，取偶数。
    public static func backfillStart(fileSize: Int64, maxBytes: Int64) -> Int64 {
        alignedOffset(fileSize - max(0, maxBytes))
    }

    // MARK: - 内部

    /// 去掉首尾空白、展开开头的 `~`、去掉末尾的 `/`；空白返回 nil。
    private static func expanded(_ configured: String?, home: String) -> String? {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        var path = trimmed
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst(1)
        }
        return CombatLogDirectory.trimmedTrailingSlashes(path)
    }

    /// 路径的最后一段。
    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// 同级目录：把最后一段换成 name。
    private static func sibling(of path: String, named name: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return name }
        let parent = path[..<slash]
        return parent.isEmpty ? "/" + name : parent + "/" + name
    }

    /// 拼接子目录，根目录不重复 `/`。
    private static func joined(_ path: String, _ child: String) -> String {
        path == "/" ? "/" + child : path + "/" + child
    }

    /// 是否全是 ASCII 数字；count 不为 nil 时还要求长度相同（为 nil 时至少 1 位）。
    private static func isDigits(_ text: Substring, count: Int?) -> Bool {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return count.map { text.count == $0 } ?? true
    }

    /// a 是否比 b 新：先比时间戳，相同时比文件名。
    private static func isNewer(_ a: Candidate, than b: Candidate) -> Bool {
        a.stamp != b.stamp ? a.stamp > b.stamp : a.name > b.name
    }
}
