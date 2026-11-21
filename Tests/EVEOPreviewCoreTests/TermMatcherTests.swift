// SPDX-License-Identifier: GPL-3.0-or-later
//
// 术语匹配的测试（docs/design-intel-translate.md 6.3 节、14.1 节）。星图数据用 StaticDataFixtures，
// 名称与 ID 取自 SDE；聊天文字是编的。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct TermMatcherTests {
    /// 夹具的星图数据。
    private let data: EVEStaticData
    init() throws { data = try StaticDataFixtures.data() }

    /// 匹配到的原文与种类，便于逐项比较。
    private func found(_ text: String) -> [(String, TermKind)] {
        data.matcher.matches(in: text).map { (String(text[$0.range]), $0.kind) }
    }

    /// 只看种类。
    private func kinds(_ text: String) -> [TermKind] {
        found(text).map(\.1)
    }

    /// 英文与中文的星系、舰船、舰船分组。
    @Test func basicTerms() {
        typealias F = StaticDataFixtures
        #expect(kinds("Jita") == [.system(id: F.jita)])
        #expect(kinds("吉他") == [.system(id: F.jita)])
        #expect(kinds("Rifter") == [.ship(typeID: F.rifter)])
        #expect(kinds("裂谷级") == [.ship(typeID: F.rifter)])
        #expect(kinds("Interceptor") == [.shipGroup(groupID: F.interceptorGroup)])
        #expect(kinds("截击舰") == [.shipGroup(groupID: F.interceptorGroup)])
        #expect(kinds("伏尔戈") == [.region(id: F.theForge)])
        #expect(kinds("The Forge") == [.region(id: F.theForge)])
    }

    /// 多个词的名称与最长匹配；名称后的 `*` 并入范围。
    @Test func multiWordAndStars() {
        typealias F = StaticDataFixtures
        let result = found("New Caldari* Vexor Navy Issue")
        #expect(result.map(\.0) == ["New Caldari*", "Vexor Navy Issue"])
        #expect(result.map(\.1) == [.system(id: F.newCaldari), .ship(typeID: F.vexorNavyIssue)])
        #expect(found("娜迦级海军型**").map(\.0) == ["娜迦级海军型**"])
        #expect(kinds("娜迦级海军型") == [.ship(typeID: F.nagaNavyIssue)])
        #expect(found("T5ZI-S* wh").map(\.0) == ["T5ZI-S*"])
    }

    /// 范围是原文的下标：大小写与原文一致，切出来的文字就是原文。
    @Test func rangesPointIntoOriginal() {
        let text = "  hek* and JITA"
        let matches = data.matcher.matches(in: text)
        #expect(matches.map { String(text[$0.range]) } == ["hek*", "JITA"])
        #expect(matches[1].name(in: .zh) == "吉他")
        #expect(matches[1].english == "Jita")
    }

    /// 复数回退：去掉 s 或 es 后再查。
    @Test func pluralFallback() {
        typealias F = StaticDataFixtures
        #expect(kinds("2 crows") == [.ship(typeID: F.crow)])
        #expect(kinds("Machariels") == [.ship(typeID: F.machariel)])
        #expect(kinds("Logisticses") == [.shipGroup(groupID: F.logisticsGroup)])
    }

    /// 虚词、2 个字符的词、纯数字不匹配；3 个字母的名称只在首字母大写或带 `*` 时匹配。
    @Test func singleWordRules() {
        typealias F = StaticDataFixtures
        #expect(kinds("hek").isEmpty)
        #expect(kinds("Hek") == [.system(id: F.hek)])
        #expect(kinds("HEK") == [.system(id: F.hek)])
        #expect(kinds("hek*") == [.system(id: F.hek)])
        #expect(kinds("to be or not 42 ab").isEmpty)
    }

    /// 第 4 条单独核对：名字恰好是虚词、2 个字符或纯数字的星系，首字母大写也不匹配；多个词时不受限。
    @Test func ruleFourWithMatchingNames() {
        let systems = [SolarSystem(id: 1, name: "Not", kind: .known), SolarSystem(id: 2, name: "Ab", kind: .known),
                       SolarSystem(id: 3, name: "42", kind: .known), SolarSystem(id: 4, name: "Not Ab", kind: .known)]
        let matcher = TermMatcher(systems: systems, regions: [], ships: [])
        #expect(matcher.matches(in: "Not").isEmpty)
        #expect(matcher.matches(in: "AB*").isEmpty)
        #expect(matcher.matches(in: "42").isEmpty)
        #expect(matcher.matches(in: "Not Ab").map(\.kind) == [.system(id: 4)])
    }

    /// 中文情报用语按字符键匹配，没有词的边界：「无人机」里的「无人」、「不安全」里的「安全」也认作「安全」。
    /// 这是 6.3 节规则的现状（字符键不看边界），由 WP-B 的回报列为风险；这里把行为钉住，改规则时这条用例要跟着改。
    @Test func chineseClearWordsHaveNoBoundary() {
        #expect(kinds("无人机") == [.intelWord(.clear)])
        #expect(kinds("不安全") == [.intelWord(.clear)])
    }

    /// ambiguousShortNames 里的名称：小写不算，首字母大写算。
    @Test func ambiguousNames() {
        typealias F = StaticDataFixtures
        #expect(IntelLexicon.ambiguousShortNames.contains("perimeter"))
        #expect(kinds("inside the perimeter").isEmpty)
        #expect(kinds("Perimeter gate") == [.system(id: F.perimeter)])
    }

    /// 与舰船同名的星系认作舰船；日文名相同的两个星系取 ID 小的。
    @Test func priorities() {
        typealias F = StaticDataFixtures
        #expect(kinds("Naga") == [.ship(typeID: F.nagaShip)])
        #expect(kinds("纳伽") == [.system(id: F.nagaSystem)])
        #expect(kinds("オンスー") == [.system(id: F.onsooh)])
    }

    /// 缩写表的词：小写也算（不受第 5 条限制），找到对应的舰船分组。
    @Test func aliases() {
        typealias F = StaticDataFixtures
        #expect(kinds("dic") == [.shipGroup(groupID: F.interdictorGroup)])
        #expect(kinds("2 dictors") == [.shipGroup(groupID: F.interdictorGroup)])
        #expect(kinds("ceptors") == [.shipGroup(groupID: F.interceptorGroup)])
        #expect(kinds("logi") == [.shipGroup(groupID: F.logisticsGroup)])
        #expect(kinds("mach") == [.ship(typeID: F.machariel)])
        #expect(kinds("vni") == [.ship(typeID: F.vexorNavyIssue)])
        // 夹具里没有 Stealth Bomber，这一项不收。
        #expect(kinds("bomber").isEmpty)
        #expect(IntelLexicon.shipAliases["bs"] == nil)
    }

    /// 情报用语：clr 与 nv 不受长度与大小写的限制；no visual 是两个词。
    @Test func intelWords() {
        #expect(kinds("clr") == [.intelWord(.clear)])
        #expect(kinds("nv") == [.intelWord(.noVisual)])
        #expect(kinds("no visual") == [.intelWord(.noVisual)])
        #expect(kinds("安全") == [.intelWord(.clear)])
        #expect(found("CLEAR").first?.1 == .intelWord(.clear))
    }

    /// 连在一起、没有空格的中文名称；匹配互不重叠且按位置排序。
    @Test func adjacentChineseNames() {
        typealias F = StaticDataFixtures
        #expect(kinds("吉他剑齿虎级黑鸦级") == [.system(id: F.jita), .ship(typeID: F.sabre), .ship(typeID: F.crow)])
        let matches = data.matcher.matches(in: "Jita 吉他 Hek")
        #expect(zip(matches, matches.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound })
    }

    /// 两个词之间隔两个空格时不算连续：`New  Caldari` 不是星系。
    @Test func doubleSpaceBreaksNames() {
        #expect(kinds("New  Caldari").isEmpty)
        #expect(kinds("Vexor Navy  Issue").isEmpty)
    }

    /// 没有任何名称时返回空数组。
    @Test func emptyInput() {
        #expect(data.matcher.matches(in: "").isEmpty)
        let empty = TermMatcher(systems: [], regions: [], ships: [])
        #expect(empty.matches(in: "clr").map(\.kind) == [.intelWord(.clear)])
    }
}
