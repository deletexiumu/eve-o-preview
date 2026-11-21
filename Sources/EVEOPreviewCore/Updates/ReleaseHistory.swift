// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跨版本的发布说明（v1.1 设计 8.8 节）。
//
// 检查只请求 `releases/latest`，答复里只有最新版的说明。用户跳过了几个版本（如正在运行 1.1.1、最新是 1.1.3）时，
// 更新窗口还要显示中间版本（1.1.2）的说明。为此在决定提示某个最新版之后，另请求一次 Release 列表
// （`UpdateFeed.historyURL`），由这里解析并挑出「正在运行的版本 < v < 最新版」的各个版本。
//
// 解析规则：
// - 顶层是 JSON 数组，超过 2 MiB 时按 `malformedFeed` 处理。数组的元素不是对象时跳过这一项。
// - 跳过草稿、预发布，以及 tag 解析不了或带预发布标识的项（与 `UpdatePolicy.offer` 的口径一致）。
// - `body` 超过 65,536 个字符时截短，缺失或为 null 时取空串。
// 挑选与上限见 `intermediate(from:running:latest:)` 与 `record(from:running:latest:)`。全部是纯函数，测试在 ReleaseHistoryTests。

import Foundation

/// 一个版本的发布说明，只含版本号与正文（正文是 Release 的原文，含各语言的块）。
public struct ReleaseNotesEntry: Sendable, Equatable, Codable {
    /// tag 去掉开头的 `v` 后的规范写法，如 `1.1.2`。
    public var version: String
    /// Release 正文，最多 65,536 个字符。
    public var notes: String

    /// 用各字段建一项。
    public init(version: String, notes: String) {
        self.version = version
        self.notes = notes
    }
}

/// 一页 Release 列表的解析结果。
public struct ReleaseHistoryPage: Sendable, Equatable {
    /// 页里的正式版（已去掉草稿、预发布与 tag 解析不了的项），保持答复里的顺序。
    public var entries: [ReleaseNotesEntry]
    /// 答复的项数（去掉之前）是否达到每页的个数：达到时可能还有下一页。
    public var isFull: Bool

    /// 用各字段建一页。
    public init(entries: [ReleaseNotesEntry], isFull: Bool) {
        self.entries = entries
        self.isFull = isFull
    }
}

/// 某个最新版对应的中间版本说明，存在 `state.json` 的 `updates.intermediateNotes`。
///
/// 只存中间版本（一般 1～3 个），不存整个列表；最新版自己的说明在 `cachedRelease` 里。
public struct IntermediateReleaseNotes: Sendable, Equatable, Codable {
    /// 这些说明是为哪个最新版取的。最新版变了就要重取。
    public var latestVersion: String
    /// 取的时候正在运行的版本，即这些说明覆盖的下界。用户换了更旧的版本（极少见）时要重取；
    /// 换了更新的版本时显示前再过滤即可。
    public var runningVersion: String
    /// 中间版本的说明，新版在前。
    public var entries: [ReleaseNotesEntry]
    /// 是否还有更早的中间版本没有列出（列表一页没覆盖到正在运行的版本，或超过了条数与大小的上限）。
    /// 为真时窗口在最后提示到发布页看更早的版本。
    public var hasMore: Bool

    /// 用各字段建记录。
    public init(latestVersion: String, runningVersion: String, entries: [ReleaseNotesEntry], hasMore: Bool) {
        self.latestVersion = latestVersion
        self.runningVersion = runningVersion
        self.entries = entries
        self.hasMore = hasMore
    }
}

/// Release 列表的解析与中间版本的挑选。
public enum ReleaseHistory {
    /// 列表答复正文的上限：2 MiB。每个 Release 的正文约 10～15 KB，加上附件信息，30 个约 0.6 MiB。
    public static let maxListBytes = 2_097_152
    /// 列表请求每页的个数（与 `UpdateFeed.productionHistoryURL` 的 `per_page` 一致）。预发布版本也占位置。
    public static let pageSize = 30
    /// 最多保留的中间版本数。落后更多的用户只看到最近的这些，其余请看发布页。
    public static let maxEntries = 10
    /// 保留的中间版本说明的总字符数上限，约 256 KB：这些说明存在 state.json 里，每次写状态都要重写。
    public static let maxTotalCharacters = 262_144

    /// 解析列表接口（`GET /releases`）的 200 答复。内容不符合规则时抛 `malformedFeed`。
    public static func parse(_ data: Data) throws(UpdateError) -> ReleaseHistoryPage {
        guard data.count <= maxListBytes else { throw .malformedFeed("release list larger than 2 MiB") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .malformedFeed("release list is not JSON")
        }
        guard let items = object as? [Any] else { throw .malformedFeed("release list is not an array") }
        return ReleaseHistoryPage(entries: items.compactMap(entry(from:)), isFull: items.count >= pageSize)
    }

    /// 从列表里挑出 running < v < latest 的版本，按版本号从新到旧排，同一版本只留第一次出现的。
    /// `record(from:running:latest:)` 用它挑选；显示前也用它按当时正在运行的版本再过滤一次存下的记录。
    public static func intermediate(from entries: [ReleaseNotesEntry], running: SemanticVersion,
                                    latest: SemanticVersion) -> [ReleaseNotesEntry] {
        var seen = Set<SemanticVersion>()
        var picked: [(version: SemanticVersion, entry: ReleaseNotesEntry)] = []
        for entry in entries {
            guard let version = SemanticVersion(entry.version), running < version, version < latest,
                  seen.insert(version).inserted else { continue }
            picked.append((version, entry))
        }
        // 列表接口按创建时间排序，补发的旧版本可能排在前面，所以这里按版本号重新排。
        return picked.sorted { $0.version > $1.version }.map(\.entry)
    }

    /// 由一页列表得出要存的记录：中间版本最多 `maxEntries` 个、总字符数不超过 `maxTotalCharacters`（超出时留较新的），
    /// 并判断是否还有没列出的更早版本。
    ///
    /// 列表只有一页：如果整页都是比正在运行的版本新的版本，且页是满的，说明更早的中间版本可能在下一页，`hasMore` 为真。
    public static func record(from page: ReleaseHistoryPage, running: SemanticVersion,
                              latest: SemanticVersion) -> IntermediateReleaseNotes {
        let all = intermediate(from: page.entries, running: running, latest: latest)
        var kept: [ReleaseNotesEntry] = []
        var total = 0
        for entry in all.prefix(maxEntries) {
            guard total + entry.notes.count <= maxTotalCharacters else { break }
            total += entry.notes.count
            kept.append(entry)
        }
        // 这一页里有不比正在运行的版本新的正式版，说明下界已覆盖到；否则满页时可能还有更早的。
        let reachedRunning = page.entries.contains { SemanticVersion($0.version).map { $0 <= running } ?? false }
        let hasMore = kept.count < all.count || (page.isFull && !reachedRunning)
        return IntermediateReleaseNotes(latestVersion: latest.description, runningVersion: running.description,
                                        entries: kept, hasMore: hasMore)
    }

    /// 列表里的一项；不是对象、草稿、预发布或 tag 解析不了时返回 nil。
    private static func entry(from value: Any) -> ReleaseNotesEntry? {
        guard let object = value as? [String: Any],
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String, let version = SemanticVersion(tag),
              !version.isPrerelease else { return nil }
        let notes = (object["body"] as? String).map { String($0.prefix(ReleaseFeedParser.maxNotesCharacters)) } ?? ""
        return ReleaseNotesEntry(version: version.description, notes: notes)
    }
}
