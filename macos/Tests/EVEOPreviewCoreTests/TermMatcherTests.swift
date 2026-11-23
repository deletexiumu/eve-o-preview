// SPDX-License-Identifier: GPL-3.0-or-later
//
// 术语匹配的测试（docs/macos/design-intel-translate.md 6.3 节、14.1 节）。星图数据用 StaticDataFixtures，
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

    /// 中文情报用语看边界（6.3 节字符键的边界）：「无人机」「安全等级」后面紧跟汉字，「不安全」前面是否定字，都不算；
    /// 前后是空白、`*` 或行尾时算。
    @Test func chineseClearWordsNeedBoundary() {
        #expect(kinds("无人机").isEmpty)
        #expect(kinds("不安全").isEmpty)
        #expect(kinds("没无人").isEmpty)
        #expect(kinds("安全等级").isEmpty)
        // 往回看 2 个字符（复审 N1）；「非常」不算否定。
        #expect(kinds("不太安全").isEmpty)
        #expect(kinds("没有安全").isEmpty)
        #expect(kinds("不 安全").isEmpty)
        #expect(kinds("非常安全") == [.intelWord(.clear)])
        #expect(kinds("安全") == [.intelWord(.clear)])
        #expect(kinds("吉他* 无人") == [.system(id: StaticDataFixtures.jita), .intelWord(.clear)])
    }

    /// commonWordLocalizedNames 里的译名（日常中文词，如 Exit 的「出口」、Cache 的「地窖」、Central Point 的「中心点」）：
    /// 后面紧跟 `*`，或前后都不紧挨汉字时才算（复审 R1）。不在表里的译名照常不看边界，英文名是普通词的
    /// Perimeter 的音译「皮尔米特」也一样。
    @Test func commonWordLocalizedNames() {
        let systems = [SolarSystem(id: 1, name: "Exit", localized: ["zh": "出口"], kind: .known),
                       SolarSystem(id: 2, name: "Jita", localized: ["zh": "吉他"], kind: .known),
                       SolarSystem(id: 3, name: "Central Point", localized: ["zh": "中心点"], kind: .known),
                       SolarSystem(id: 4, name: "Perimeter", localized: ["zh": "皮尔米特"], kind: .known)]
        let regions = [StaticDataFile.Named(i: 10, n: "Cache", l: ["zh": "地窖"])]
        let matcher = TermMatcher(systems: systems, regions: regions, ships: [])
        let kinds = { (text: String) in matcher.matches(in: text).map(\.kind) }
        #expect(kinds("出口") == [.system(id: 1)])
        #expect(kinds("出口*") == [.system(id: 1)])
        #expect(kinds("Jita 出口 gate") == [.system(id: 2), .system(id: 1)])
        #expect(kinds("门口出口处").isEmpty)
        #expect(kinds("出口有泡泡").isEmpty)
        #expect(kinds("吉他出口*") == [.system(id: 2), .system(id: 1)])
        #expect(kinds("吉他出口") == [.system(id: 2)])
        #expect(kinds("地窖 3") == [.region(id: 10)])
        #expect(kinds("酒地窖里").isEmpty)
        #expect(kinds("中心点") == [.system(id: 3)])
        #expect(kinds("地图中心点附近").isEmpty)
        // 音译名不在表里：紧挨汉字也算。
        #expect(kinds("门口皮尔米特有人") == [.system(id: 4)])
        #expect(kinds("吉他皮尔米特") == [.system(id: 2), .system(id: 4)])
        #expect(IntelLexicon.commonWordLocalizedNames.contains("出口"))
        #expect(!IntelLexicon.commonWordLocalizedNames.contains("皮尔米特"))
    }

    /// 夹具里的皮尔米特（Perimeter 在 ambiguousShortNames 里）不带 `*`、紧挨汉字也认得出。
    @Test func transliteratedAmbiguousNameMatchesFreely() {
        #expect(kinds("从吉他跳到皮尔米特了") == [.system(id: StaticDataFixtures.jita),
                                                 .system(id: StaticDataFixtures.perimeter)])
    }

    /// 舰船与舰船分组小写也算（不受第 5 条限制）；caseSensitiveShipNames 与 ambiguousShortNames 里的键仍要大写或 `*`，
    /// 复数回退得到的键也按这条判断。
    @Test func lowercaseShipNames() {
        let ships = [ShipName(id: 1, groupID: 25, name: "Moa"), ShipName(id: 2, groupID: 25, name: "Nyx"),
                     ShipName(id: 3, groupID: 25, name: "Sin"), ShipName(id: 4, groupID: 25, name: "Imp"),
                     ShipName(id: 5, groupID: 25, name: "Ark"), ShipName(id: 6, groupID: 25, name: "Curse"),
                     ShipName(id: 7, groupID: 25, name: "Hel")]
        let matcher = TermMatcher(systems: [SolarSystem(id: 9, name: "Hek", kind: .known)], regions: [], ships: ships)
        let kinds = { (text: String) in matcher.matches(in: text).map(\.kind) }
        #expect(kinds("moa") == [.ship(typeID: 1)])
        #expect(kinds("2 moas") == [.ship(typeID: 1)])
        #expect(kinds("nyx") == [.ship(typeID: 2)])
        #expect(kinds("sin").isEmpty)
        #expect(kinds("sins").isEmpty)
        #expect(kinds("Sin") == [.ship(typeID: 3)])
        #expect(kinds("imp ark").isEmpty)
        #expect(kinds("Imp Ark*") == [.ship(typeID: 4), .ship(typeID: 5)])
        #expect(kinds("curse").isEmpty)
        #expect(kinds("hel").isEmpty)
        #expect(kinds("Curse") == [.ship(typeID: 6)])
        // 星系仍受第 5 条限制。
        #expect(kinds("hek").isEmpty)
        #expect(kinds("Hel") == [.ship(typeID: 7)])
        #expect(IntelLexicon.caseSensitiveShipNames == ["sin", "imp", "ark", "hel"])
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
