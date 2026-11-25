// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跨版本的发布说明（v1.1 设计 8.8 节）。
//
// 用户跳过了几个版本（如正在运行 1.1.1、最新是 1.1.3）时，更新窗口还要显示中间版本（1.1.2）的说明。
// 1.5.0 起各版本的说明在更新清单的 `releases` 里（`UpdateManifest.historyPage`，只含改动了本平台的版本），
// 由这里挑出「正在运行的版本 < v < 最新版」的各个版本。1.4.x 及更早的版本另请求 GitHub 的 Release 列表，
// 那部分解析已去掉。
//
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

/// 一组版本的说明（来自更新清单），供挑出中间版本。
public struct ReleaseHistoryPage: Sendable, Equatable {
    /// 各正式版的说明，保持清单里的顺序。
    public var entries: [ReleaseNotesEntry]
    /// 是否可能还有没列出的更早版本（为真且没有覆盖到正在运行的版本时，窗口提示到发布页看更早的版本）。
    /// 清单已含需要的全部版本，`UpdateManifest.historyPage` 总是给假。
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

/// 中间版本的挑选。
public enum ReleaseHistory {
    /// 最多保留的中间版本数。落后更多的用户只看到最近的这些，其余请看发布页。
    public static let maxEntries = 10
    /// 保留的中间版本说明的总字符数上限，约 256 KB：这些说明存在 state.json 里，每次写状态都要重写。
    public static let maxTotalCharacters = 262_144

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
        // 不依赖输入的顺序（1.4.x 的 Release 列表按创建时间排序，补发的旧版本可能排在前面），按版本号重新排。
        return picked.sorted { $0.version > $1.version }.map(\.entry)
    }

    /// 由一页列表得出要存的记录：中间版本最多 `maxEntries` 个、总字符数不超过 `maxTotalCharacters`（超出时留较新的），
    /// 并判断是否还有没列出的更早版本。
    ///
    /// page.isFull 为真、且其中没有不比正在运行的版本新的版本时，更早的中间版本可能没列出，`hasMore` 为真。
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
}
