// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的分人（docs/macos/design-intel-translate.md 6.9 节）。IntelParser 推断的人名段经 ESI 核对后，
// 按查到的角色名重新分人；结果在显示时套用，IntelReport 本身不变。
//
// - runs：报告里的人名段。相邻两个 pilot 段之间只有一段正好一个空格的 plain 时属于同一段（6.4 节第 6 条把
//   超过 3 个词的一串切成几段，这里接回）。两个以上的空格、标点与术语都是边界。
// - candidates：要发给 ESI 的名字。只有一个词的人名段没有候选名字（用户的要求：单个词就是一个人，不查）；
//   两个词以上的段取连续的 1～3 个词，只留 3～37 个字符、只含英文字母、数字、' - 与空格的组合（E7），按比较键去重。
// - segment：给一个人名段分人。可用的名字（directory 里是 matched）先取 2～3 个词的，让盖住的词最多；
//   一样多时名字少的优先；仍相同时从左起 3 个词的优先于 2 个词的，取名字优先于空着。没盖住的一串词（空缺）
//   每个词单独都可用时每词一人，否则按 6.4 节每 3 个词一人、状态是没查到。
// - resolve：整条消息的人名与敌对数量。新的人数是分出的人数；hostileCount 取原数量与新人数里较大的一个。
//   「查到」只说明有角色叫这个名字（R44），所以数量来自人名时不算写明。

import Foundation

/// 一个人名的核对状态。
public enum PilotStatus: Sendable, Equatable {
    /// 还没有 ESI 的结果，或者这个人名段不查。
    case unchecked
    /// ESI 有同名的角色。
    case matched(characterID: Int)
    /// 查过，没有同名的角色（含有歧义与被筛掉的组合）。
    case notFound
}

/// 分出的一个人。
public struct IntelPilot: Sendable, Equatable {
    /// 查到的用 ESI 返回的写法，其余用原文的写法。
    public var name: String
    /// 核对状态。
    public var status: PilotStatus

    /// 用名字与状态建一个人。
    public init(name: String, status: PilotStatus) {
        self.name = name
        self.status = status
    }
}

/// 整条消息核对后的人名与敌对数量。
public struct ResolvedPilots: Sendable, Equatable {
    /// 各人，按出现顺序。
    public var pilots: [IntelPilot]
    /// 敌对数量；nil 表示判断不出。
    public var hostileCount: Int?
    /// 数量来自消息里写明的数字。
    public var countIsExplicit: Bool

    /// 用各字段建结果。
    public init(pilots: [IntelPilot], hostileCount: Int?, countIsExplicit: Bool) {
        self.pilots = pilots
        self.hostileCount = hostileCount
        self.countIsExplicit = countIsExplicit
    }
}

/// 核对的结果表：比较键 → 结果。
public struct PilotDirectory: Sendable, Equatable {
    /// 没有任何结果（开关关着，或还没查过）。
    public static let empty = PilotDirectory()

    /// 键是 `PilotLookupAnswer.key(for:)` 的结果。
    private let outcomes: [String: PilotLookupOutcome]

    /// 用比较键到结果的表建目录。
    public init(_ outcomes: [String: PilotLookupOutcome] = [:]) {
        self.outcomes = outcomes
    }

    /// 某个名字的结果；没有时为 nil。
    public func outcome(for name: String) -> PilotLookupOutcome? {
        outcomes[PilotLookupAnswer.key(for: name)]
    }

    /// 没有任何结果。
    public var isEmpty: Bool { outcomes.isEmpty }
}

/// 人名段的分人。
public enum PilotSegmenter {
    /// 一个角色名至多几个词（E7）。
    public static let maxNameWords = 3
    /// 角色名的长度范围（E7）。
    public static let nameLengthRange: ClosedRange<Int> = 3...37

    /// 报告里的各个人名段，每段是一串只隔一个空格的词。
    public static func runs(in report: IntelReport) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        // 上一段是 pilot 之后，是否只隔着一段正好一个空格的 plain。
        var linkable = false
        for segment in report.segments {
            switch segment.kind {
            case .pilot:
                if !linkable, !current.isEmpty {
                    runs.append(current)
                    current = []
                }
                current += segment.text.split(separator: " ").map(String.init)
                linkable = false
            case .plain where segment.text == " " && !current.isEmpty && !linkable:
                linkable = true
            default:
                if !current.isEmpty { runs.append(current) }
                current = []
                linkable = false
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// 要向 ESI 查的名字：两个词以上的人名段里 1～3 个词的连续组合，按比较键去重，保留先出现的。
    public static func candidates(in report: IntelReport) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for run in runs(in: report) {
            for name in combinations(of: run) where seen.insert(PilotLookupAnswer.key(for: name)).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// 给一个人名段分人。
    public static func segment(run: [String], directory: PilotDirectory) -> [IntelPilot] {
        let combos = combinations(of: run)
        // 第 1～3 条：没有结果、没有候选名字、或有候选名字还没有结果时，按 6.4 节分人，状态是未核对。
        if directory.isEmpty || combos.isEmpty || combos.contains(where: { directory.outcome(for: $0) == nil }) {
            return chunked(run, status: .unchecked)
        }
        // 可用的名字：组合合规且结果是 matched。被筛掉的组合不可用。
        func usable(_ start: Int, _ count: Int) -> (id: Int, name: String)? {
            let name = run[start..<(start + count)].joined(separator: " ")
            guard isAcceptable(name), case .matched(let id, let esiName) = directory.outcome(for: name) else {
                return nil
            }
            return (id, esiName)
        }
        let picks = bestCover(wordCount: run.count) { start, count in usable(start, count) != nil }
        var pilots: [IntelPilot] = []
        var gapStart: Int?
        var index = 0
        func flushGap(until end: Int) {
            guard let start = gapStart else { return }
            gapStart = nil
            let singles = (start..<end).map { usable($0, 1) }
            if singles.allSatisfy({ $0 != nil }) {
                pilots += singles.compactMap { $0 }.map { IntelPilot(name: $0.name, status: .matched(characterID: $0.id)) }
            } else {
                pilots += chunked(Array(run[start..<end]), status: .notFound)
            }
        }
        while index < run.count {
            if let count = picks[index], let found = usable(index, count) {
                flushGap(until: index)
                pilots.append(IntelPilot(name: found.name, status: .matched(characterID: found.id)))
                index += count
            } else {
                if gapStart == nil { gapStart = index }
                index += 1
            }
        }
        flushGap(until: run.count)
        return pilots
    }

    /// 整条消息的人名与敌对数量。
    public static func resolve(_ report: IntelReport, directory: PilotDirectory) -> ResolvedPilots {
        guard !directory.isEmpty else {
            return ResolvedPilots(pilots: report.pilots.map { IntelPilot(name: $0, status: .unchecked) },
                                  hostileCount: report.hostileCount, countIsExplicit: report.countIsExplicit)
        }
        let pilots = runs(in: report).flatMap { segment(run: $0, directory: directory) }
        let hostileCount = pilots.isEmpty ? report.hostileCount : max(report.hostileCount ?? 0, pilots.count)
        let explicit = hostileCount == report.hostileCount ? report.countIsExplicit : false
        return ResolvedPilots(pilots: pilots, hostileCount: hostileCount, countIsExplicit: explicit)
    }

    // MARK: - 内部

    /// 一个人名段的候选名字：只有一个词时没有；否则取连续的 1～3 个词，只留合规的组合。
    static func combinations(of run: [String]) -> [String] {
        guard run.count >= 2 else { return [] }
        var result: [String] = []
        for start in run.indices {
            for count in 1...maxNameWords where start + count <= run.count {
                let name = run[start..<(start + count)].joined(separator: " ")
                if isAcceptable(name) { result.append(name) }
            }
        }
        return result
    }

    /// 组合是否合规：3～37 个字符，只含英文字母、数字、`'`、`-` 与空格（E7）。
    static func isAcceptable(_ name: String) -> Bool {
        nameLengthRange.contains(name.count) && name.allSatisfy { character in
            (character.isASCII && (character.isLetter || character.isNumber)) || "'- ".contains(character)
        }
    }

    /// 6.4 节的分法：从左起每 3 个词一个人。
    static func chunked(_ words: [String], status: PilotStatus) -> [IntelPilot] {
        stride(from: 0, to: words.count, by: maxNameWords).map { start in
            let chunk = words[start..<min(start + maxNameWords, words.count)]
            return IntelPilot(name: chunk.joined(separator: " "), status: status)
        }
    }

    /// 第 4～6 条：选一组互不重叠的 2～3 个词的可用名字，盖住的词最多；一样多时名字少的优先；仍相同时从左起
    /// 3 个词的优先于 2 个词的，取名字优先于空着。从右到左算，后一种选法严格更好时才替换前一种。
    /// 返回每个起点选中的词数（没选中的位置为 nil）。
    static func bestCover(wordCount: Int, usable: (Int, Int) -> Bool) -> [Int?] {
        /// 从某个位置到末尾的最好选法：盖住的词数、名字个数、这个位置取几个词（nil 是空着）。
        struct Best { var covered: Int; var names: Int; var take: Int? }
        /// 盖住的词更多，或一样多而名字更少。
        func isBetter(_ candidate: Best, than current: Best) -> Bool {
            if candidate.covered != current.covered { return candidate.covered > current.covered }
            return candidate.names < current.names
        }
        var best = [Best](repeating: Best(covered: 0, names: 0, take: nil), count: wordCount + 1)
        for start in stride(from: wordCount - 1, through: 0, by: -1) {
            var choice: Best?
            for take in [3, 2] where start + take <= wordCount && usable(start, take) {
                let rest = best[start + take]
                let option = Best(covered: rest.covered + take, names: rest.names + 1, take: take)
                if let current = choice, !isBetter(option, than: current) { continue }
                choice = option
            }
            let skip = Best(covered: best[start + 1].covered, names: best[start + 1].names, take: nil)
            if let current = choice, !isBetter(skip, than: current) {
                best[start] = current
            } else {
                best[start] = skip
            }
        }
        // 从左往右走一遍，取出各起点的选择。
        var picks = [Int?](repeating: nil, count: wordCount)
        var index = 0
        while index < wordCount {
            if let take = best[index].take {
                picks[index] = take
                index += take
            } else {
                index += 1
            }
        }
        return picks
    }
}
