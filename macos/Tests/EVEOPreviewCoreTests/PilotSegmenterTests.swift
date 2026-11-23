// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对分人的测试（docs/macos/design-intel-translate.md 6.9 节、14.1 节）。人名都是虚构的。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct PilotSegmenterTests {
    /// 只列可用（matched）的名字建目录；查过的其余组合是 notFound。角色 ID 按顺序编。
    private func directory(run: [String], matched: [String], ambiguous: [String] = []) -> PilotDirectory {
        var outcomes: [String: PilotLookupOutcome] = [:]
        for name in PilotSegmenter.combinations(of: run) {
            outcomes[PilotLookupAnswer.key(for: name)] = .notFound
        }
        for (index, name) in matched.enumerated() {
            outcomes[PilotLookupAnswer.key(for: name)] = .matched(characterID: 1_000 + index, name: name)
        }
        for name in ambiguous { outcomes[PilotLookupAnswer.key(for: name)] = .ambiguous }
        return PilotDirectory(outcomes)
    }

    /// 分人结果的简写：(名字, 是否查到)。未核对记 nil。
    private func split(_ run: String, matched: [String], ambiguous: [String] = []) -> [(String, Bool?)] {
        let words = run.split(separator: " ").map(String.init)
        return PilotSegmenter.segment(run: words, directory: directory(run: words, matched: matched,
                                                                       ambiguous: ambiguous)).map { pilot in
            switch pilot.status {
            case .matched: (pilot.name, true)
            case .notFound: (pilot.name, false)
            case .unchecked: (pilot.name, nil)
            }
        }
    }

    /// 把 pilot 段与 plain 段拼成报告。
    private func report(_ parts: [(String, IntelSegmentKind)]) -> IntelReport {
        IntelReport(segments: parts.map { IntelSegment(text: $0.0, kind: $0.1) })
    }

    // MARK: - 人名段

    @Test func runsJoinAndSplit() {
        // 被 6.4 节切开的 4 个词接回一串；隔两个空格、标点或术语时分开。
        let value = report([("Brenn Ostvar Tyra", .pilot), (" ", .plain), ("Kelloway", .pilot),
                            ("  ", .plain), ("Mira Voss", .pilot), (", ", .plain), ("Kael", .pilot),
                            (" ", .plain), ("Stabber", .ship(typeID: 622)), (" ", .plain), ("Jorn", .pilot)])
        #expect(PilotSegmenter.runs(in: value) == [["Brenn", "Ostvar", "Tyra", "Kelloway"], ["Mira", "Voss"],
                                                   ["Kael"], ["Jorn"]])
    }

    // MARK: - 候选名字

    @Test func candidateCounts() {
        // 一个词的人名段没有候选名字：单个词就是一个人，不发给 ESI。
        #expect(PilotSegmenter.candidates(in: report([("Mira", .pilot)])).isEmpty)
        #expect(PilotSegmenter.candidates(in: report([("Mira", .pilot), ("  ", .plain), ("Kael", .pilot)])).isEmpty)
        // 2 个词 3 个组合，4 个词 9 个组合。
        #expect(PilotSegmenter.candidates(in: report([("Kael Doran", .pilot)])) == ["Kael", "Kael Doran", "Doran"])
        let four = report([("Brenn Ostvar Tyra", .pilot), (" ", .plain), ("Kelloway", .pilot)])
        #expect(PilotSegmenter.candidates(in: four).count == 9)
    }

    @Test func candidateFilteringAndDedup() {
        // 按比较键去重；长度不足 3 个字符或含不允许的字符的组合去掉。
        let value = report([("Kael Doran", .pilot), ("  ", .plain), ("KAEL DORAN", .pilot)])
        #expect(PilotSegmenter.candidates(in: value) == ["Kael", "Kael Doran", "Doran"])
        #expect(PilotSegmenter.candidates(in: report([("Al Bo", .pilot)])) == ["Al Bo"])
        #expect(PilotSegmenter.candidates(in: report([("Ka_el Doran", .pilot)])) == ["Doran"])
        #expect(PilotSegmenter.candidates(in: report([("Kael O'Doran-Vex", .pilot)])).contains("Kael O'Doran-Vex"))
    }

    // MARK: - 6.9 节样例表的 9 行

    @Test func sampleTable() {
        #expect(split("Brenn Ostvar Tyra Kelloway", matched: ["Brenn Ostvar", "Tyra Kelloway", "Brenn", "Tyra"])
            .map(\.0) == ["Brenn Ostvar", "Tyra Kelloway"])
        #expect(split("Kael Doran Mira Voss", matched: ["Kael Doran", "Mira Voss"]).map(\.0)
            == ["Kael Doran", "Mira Voss"])
        #expect(split("Jorn Halden Brask", matched: ["Jorn Halden Brask", "Jorn Halden", "Brask"]).map(\.0)
            == ["Jorn Halden Brask"])
        let partial = split("Jorn Halden Brask", matched: ["Jorn Halden", "Halden Brask"])
        #expect(partial.map(\.0) == ["Jorn Halden", "Brask"])
        #expect(partial.map(\.1) == [true, false])
        let singles = split("Tarn Vex Ilya", matched: ["Tarn", "Vex", "Ilya"])
        #expect(singles.map(\.0) == ["Tarn", "Vex", "Ilya"])
        #expect(singles.allSatisfy { $0.1 == true })
        #expect(split("Ilya Morrow Tarn", matched: ["Ilya Morrow", "Tarn"]).map(\.0) == ["Ilya Morrow", "Tarn"])
        let typo = split("Kael Dorann", matched: ["Kael"])
        #expect(typo.map(\.0) == ["Kael Dorann"])
        #expect(typo.map(\.1) == [false])
        // 有候选名字还没有结果：整段未核对。
        let pending = PilotSegmenter.segment(run: ["Jorn", "Halden"],
                                             directory: PilotDirectory(["other": .notFound]))
        #expect(pending == [IntelPilot(name: "Jorn Halden", status: .unchecked)])
        // 一个词的人名段不查：一人，未核对。
        #expect(PilotSegmenter.segment(run: ["Mira"], directory: directory(run: ["Mira"], matched: ["Mira"]))
                == [IntelPilot(name: "Mira", status: .unchecked)])
    }

    // MARK: - 选法的细则

    @Test func tieBreaks() {
        // 盖住的词一样多时名字少的优先：6 个词既能分成 3+3，也能分成 2+2+2，取 2 个名字的分法。
        #expect(split("Aa Bb Cc Dd Ee Ff", matched: ["Aa Bb", "Cc Dd", "Ee Ff", "Aa Bb Cc", "Dd Ee Ff"]).map(\.0)
            == ["Aa Bb Cc", "Dd Ee Ff"])
        // 盖住的词更多的分法优先：「Aa Bb Cc」盖 3 个词，胜过「Aa Bb」加空缺。
        #expect(split("Aa Bb Cc", matched: ["Aa Bb Cc", "Aa Bb"]).map(\.0) == ["Aa Bb Cc"])
        // 盖住的词与名字个数都相同时，从左起 3 个词的名字优先：「Aa Bb Cc」+「Dd Ee」胜过「Aa Bb」+「Cc Dd Ee」。
        #expect(split("Aa Bb Cc Dd Ee", matched: ["Aa Bb Cc", "Dd Ee", "Aa Bb", "Cc Dd Ee"]).map(\.0)
            == ["Aa Bb Cc", "Dd Ee"])
        // 完全相同时左边取长的：A B 与 B C 都可用。
        #expect(split("Aa Bb Cc", matched: ["Aa Bb", "Bb Cc"]).map(\.0) == ["Aa Bb", "Cc"])
    }

    @Test func ambiguousAndPartialGaps() {
        // ambiguous 不可用。
        let value = split("Kael Doran", matched: ["Kael", "Doran"], ambiguous: ["Kael Doran"])
        #expect(value.map(\.0) == ["Kael", "Doran"])
        // 空缺里只有部分词可用时不拆。
        let gap = split("Mira Voss Kael Doran Tarn", matched: ["Mira Voss", "Kael"])
        #expect(gap.map(\.0) == ["Mira Voss", "Kael Doran Tarn"])
        #expect(gap.map(\.1) == [true, false])
        // ESI 返回的写法替换原文的大小写。
        let words = ["kael", "doran"]
        let dir = PilotDirectory(["kael": .notFound, "doran": .notFound,
                                  "kael doran": .matched(characterID: 7, name: "Kael Doran")])
        #expect(PilotSegmenter.segment(run: words, directory: dir) == [IntelPilot(name: "Kael Doran",
                                                                                  status: .matched(characterID: 7))])
    }

    // MARK: - resolve

    @Test func resolveCounts() {
        let base = report([("Jita", .system(id: 1)), (" ", .plain), ("Kael Doran Mira", .pilot), (" ", .plain),
                           ("Voss", .pilot)])
        var inferred = base
        inferred.pilots = ["Kael Doran Mira", "Voss"]
        inferred.hostileCount = 2
        // directory 为空时与 report 相同。
        let unchanged = PilotSegmenter.resolve(inferred, directory: .empty)
        #expect(unchanged.pilots == [IntelPilot(name: "Kael Doran Mira", status: .unchecked),
                                     IntelPilot(name: "Voss", status: .unchecked)])
        #expect(unchanged.hostileCount == 2)
        // 新的人数大于原数量：取新的人数，不算写明。
        let run = ["Kael", "Doran", "Mira", "Voss"]
        let more = PilotSegmenter.resolve(inferred, directory: directory(run: run, matched: ["Kael", "Doran", "Mira",
                                                                                            "Voss"]))
        #expect(more.pilots.count == 4)
        #expect(more.hostileCount == 4)
        #expect(!more.countIsExplicit)
        // 新的人数不大于写明的数量：数量与 countIsExplicit 不变。
        var explicit = inferred
        explicit.hostileCount = 6
        explicit.countIsExplicit = true
        let same = PilotSegmenter.resolve(explicit, directory: directory(run: run, matched: ["Kael Doran",
                                                                                            "Mira Voss"]))
        #expect(same.pilots.map(\.name) == ["Kael Doran", "Mira Voss"])
        #expect(same.hostileCount == 6)
        #expect(same.countIsExplicit)
        // isClear 且没有人名时仍是 0。
        let clear = IntelReport(segments: [IntelSegment(text: "Jita", kind: .system(id: 1))], systemIDs: [1],
                                hostileCount: 0, isClear: true)
        #expect(PilotSegmenter.resolve(clear, directory: PilotDirectory(["x": .notFound])).hostileCount == 0)
    }
}
