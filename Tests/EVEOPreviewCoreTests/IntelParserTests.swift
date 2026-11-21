// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息分段的测试（docs/design-intel-translate.md 6.4 节、14.1 节）。人名都是虚构的；
// 星系与舰船取自 StaticDataFixtures，与用户的日志无关。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct IntelParserTests {
    /// 夹具的星图数据。
    private let data: EVEStaticData
    init() throws { data = try StaticDataFixtures.data() }

    /// 解析一条消息，并核对各段拼起来等于原文。
    private func parse(_ text: String) -> IntelReport {
        let report = IntelParser.parse(text, data: data)
        #expect(report.segments.map(\.text).joined() == text, "各段拼起来应与原文相同：\(text)")
        return report
    }

    /// 舰船数量的简写：(种类, 数量)。
    private func ships(_ report: IntelReport) -> [(TermKind, Int)] {
        report.ships.map { ($0.kind, $0.count) }
    }

    // MARK: - 6.4 节样例表的 8 行

    @Test func sampleChineseShipsWithCounts() {
        typealias F = StaticDataFixtures
        let report = parse("1DQ1-A ess 娜迦级海军型 3  剑齿虎级 1门口有泡泡")
        #expect(report.systemIDs == [F.oneDQ])
        #expect(report.ships == [IntelShipMention(kind: .ship(typeID: F.nagaNavyIssue), count: 3),
                                 IntelShipMention(kind: .ship(typeID: F.sabre), count: 1)])
        #expect(report.pilots.isEmpty)
        #expect(report.hostileCount == 4)
        #expect(report.countIsExplicit)
        #expect(!report.isClear && !report.isNoVisual)
        // `1门口有泡泡` 里的 1 成为一段人数，其余是普通文字。
        #expect(report.segments.contains(IntelSegment(text: "1", kind: .count(1))))
        #expect(report.segments.last == IntelSegment(text: "门口有泡泡", kind: .plain))
    }

    @Test func samplePilotsWithShipsInParentheses() {
        typealias F = StaticDataFixtures
        let report = parse("Kael Doran (Stabber)  Mira Voss (Astarte)  T5ZI-S* wh")
        #expect(report.systemIDs == [F.t5zi])
        #expect(report.ships == [IntelShipMention(kind: .ship(typeID: F.stabber), count: 1),
                                 IntelShipMention(kind: .ship(typeID: F.astarte), count: 1)])
        #expect(report.pilots == ["Kael Doran", "Mira Voss"])
        #expect(report.hostileCount == 2)
        #expect(!report.countIsExplicit)
    }

    @Test func samplePilotsSeparatedByDoubleSpaces() {
        typealias F = StaticDataFixtures
        let report = parse("HED-GP*  Tarn Vex  Ilya Morrow  长剑级*  黑鸦级*")
        #expect(report.systemIDs == [F.hedGP])
        #expect(report.ships == [IntelShipMention(kind: .ship(typeID: F.rapier), count: 1),
                                 IntelShipMention(kind: .ship(typeID: F.crow), count: 1)])
        #expect(report.pilots == ["Tarn Vex", "Ilya Morrow"])
        #expect(report.hostileCount == 2)
        #expect(!report.countIsExplicit)
    }

    @Test func samplePilotNoVisual() {
        let report = parse("T5ZI-S Jorn Halden nv")
        #expect(report.systemIDs == [StaticDataFixtures.t5zi])
        #expect(report.ships.isEmpty)
        #expect(report.pilots == ["Jorn Halden"])
        #expect(report.hostileCount == 1)
        #expect(!report.countIsExplicit)
        #expect(report.isNoVisual && !report.isClear)
    }

    @Test func sampleClear() {
        let report = parse("HED-GP* clr")
        #expect(report.systemIDs == [StaticDataFixtures.hedGP])
        #expect(report.pilots.isEmpty)
        #expect(report.hostileCount == 0)
        #expect(report.isClear)
    }

    @Test func samplePlusCount() {
        let report = parse("1DQ1-A +5")
        #expect(report.systemIDs == [StaticDataFixtures.oneDQ])
        #expect(report.hostileCount == 5)
        #expect(report.countIsExplicit)
    }

    @Test func sampleLeadingCountForShip() {
        typealias F = StaticDataFixtures
        let report = parse("3x Naga Jita gate")
        #expect(report.systemIDs == [F.jita])
        #expect(report.ships == [IntelShipMention(kind: .ship(typeID: F.nagaShip), count: 3)])
        #expect(report.pilots.isEmpty)
        #expect(report.hostileCount == 3)
        #expect(report.countIsExplicit)
    }

    @Test func sampleLowercaseChat() {
        let report = parse("anyone want to roam to Jita later")
        #expect(report.systemIDs == [StaticDataFixtures.jita])
        #expect(report.pilots.isEmpty)
        #expect(report.hostileCount == nil)
    }

    // MARK: - 人数

    /// 13 种人数写法。
    @Test(arguments: ["+3", "＋3", "x3", "X3", "×3", "3", "3x", "3×", "3+", "3人", "3个", "3只", "3艘", "3名"])
    func countForms(_ word: String) {
        let report = parse("Jita \(word)")
        #expect(report.segments.contains(IntelSegment(text: word, kind: .count(3))))
        #expect(report.hostileCount == 3)
        #expect(report.countIsExplicit)
    }

    /// 数值是 0 与 501、超过 3 位时不算人数；末尾的标点不算在人数里。
    @Test func countBounds() {
        #expect(parse("Jita 0").hostileCount == nil)
        #expect(parse("Jita 501").hostileCount == nil)
        #expect(parse("Jita 1000").hostileCount == nil)
        let report = parse("Jita 500,")
        #expect(report.hostileCount == 500)
        #expect(report.segments.contains(IntelSegment(text: "500", kind: .count(500))))
    }

    /// 两个数字分别归给前后的舰船；没有归属的人数取最大的独立人数。
    @Test func countAttribution() {
        typealias F = StaticDataFixtures
        let report = parse("2 Naga 3 Machariel")
        #expect(report.ships == [IntelShipMention(kind: .ship(typeID: F.nagaShip), count: 2),
                                 IntelShipMention(kind: .ship(typeID: F.machariel), count: 3)])
        #expect(report.hostileCount == 5)
        let mixed = parse("Jita +2 Rifter +7")
        #expect(mixed.ships == [IntelShipMention(kind: .ship(typeID: F.rifter), count: 7)])
        #expect(mixed.hostileCount == 7)
        // 前缀写法（+3）不归给后面的舰船。
        let prefix = parse("Jita +3 Rifter")
        #expect(prefix.ships.first?.count == 1)
        #expect(prefix.hostileCount == 3)
    }

    // MARK: - 人名

    /// 隔两个空格的人名不合并；一个人名至多 3 个词，超出的另成一段，中间的空格单独成一段 plain。
    @Test func pilotGrouping() {
        let report = parse("Jita  Brenn Ostvar Tyra Kelloway")
        #expect(report.pilots == ["Brenn Ostvar Tyra", "Kelloway"])
        #expect(report.segments.suffix(3) == [IntelSegment(text: "Brenn Ostvar Tyra", kind: .pilot),
                                              IntelSegment(text: " ", kind: .plain),
                                              IntelSegment(text: "Kelloway", kind: .pilot)])
        #expect(report.hostileCount == 2)
        #expect(parse("Jita Kael  Doran").pilots == ["Kael", "Doran"])
    }

    /// 标点把人名分开，标点本身是普通文字。
    @Test func punctuationSplitsPilots() {
        let report = parse("Jita Mira, Voss")
        #expect(report.pilots == ["Mira", "Voss"])
        #expect(report.segments.contains(IntelSegment(text: ",", kind: .plain)) == false)
        #expect(report.segments.contains { $0.kind == .plain && $0.text.contains(",") })
    }

    /// 全小写的句子没有人名；没有认出星系或舰船时不推断人名。
    @Test func pilotPreconditions() {
        #expect(parse("Jita gate camp hostile").pilots.isEmpty)
        let noTerms = parse("Kael Doran says hello")
        #expect(noTerms.pilots.isEmpty)
        #expect(noTerms.segments == [IntelSegment(text: "Kael Doran says hello", kind: .plain)])
        // 中文词与 nonPilotWords 里的词不是人名；含数字的词是人名。
        #expect(parse("Jita 有人 Gate RED").pilots.isEmpty)
        #expect(parse("Jita K4el").pilots == ["K4el"])
    }

    /// remainder：人名超过 3 个词时含人名。
    @Test func remainderIncludesLongPilotRuns() {
        let short = parse("Jita Kael Doran gate")
        #expect(IntelParser.remainder(of: short) == "gate")
        let long = parse("Jita Kael Doran Mira Voss gate")
        #expect(IntelParser.remainder(of: long).contains("Kael Doran Mira"))
    }

    /// 没有术语的消息只有一段 plain；空文字没有段。
    @Test func plainMessages() {
        #expect(parse("hello  there").segments == [IntelSegment(text: "hello  there", kind: .plain)])
        #expect(IntelParser.parse("", data: data).segments.isEmpty)
    }
}
