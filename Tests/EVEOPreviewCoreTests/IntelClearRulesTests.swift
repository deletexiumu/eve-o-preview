// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「安全」用语的测试（docs/design-intel-translate.md 6.3 节字符键的边界、6.4 节 isClear 与敌对数量）。
// 前 6 条是审查时复现的误判：否定、疑问、「无人机」「安全等级」这类词里的字不算「安全」，写了人数时敌对数量不是 0。
// 其余是对照：真正报「安全」的写法仍认得出。星系取自 StaticDataFixtures；消息是编的。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct IntelClearRulesTests {
    typealias F = StaticDataFixtures
    /// 夹具的星图数据。
    private let data: EVEStaticData
    init() throws { data = try StaticDataFixtures.data() }

    /// 解析一条消息，并核对各段拼起来等于原文。
    private func parse(_ text: String) -> IntelReport {
        let report = IntelParser.parse(text, data: data)
        #expect(report.segments.map(\.text).joined() == text, "各段拼起来应与原文相同：\(text)")
        return report
    }

    // MARK: - 审查复现的误判

    /// 「无人机」里的「无人」不是用语；3 是独立人数。
    @Test func droneIsNotClear() {
        let report = parse("Jita 3 无人机")
        #expect(!report.isClear)
        #expect(report.hostileCount == 3)
        #expect(report.countIsExplicit)
    }

    /// 「不安全」被否定；+5 是人数。
    @Test func negatedChineseClear() {
        let report = parse("HED-GP 不安全 +5")
        #expect(!report.isClear)
        #expect(report.hostileCount == 5)
    }

    /// 英文的否定：前一个词是 not、no 或以 n't 结尾。
    @Test(arguments: ["Jita not clear", "Jita no clr", "Jita isn't clear", "Jita isn’t clr", "Jita NOT, clear"])
    func negatedEnglishClear(_ text: String) {
        #expect(!parse(text).isClear, "\(text)")
    }

    /// 往回看 3 个普通词（复审 N1）：not yet、no longer、never，以及隔着一两个词的 not。
    @Test(arguments: ["Jita not yet clr", "Jita no longer clear", "Jita never clr", "Jita is not really clear",
                      "Jita gate isn't fully clr"])
    func negationLookBack(_ text: String) {
        #expect(!parse(text).isClear, "\(text)")
    }

    /// 往回看的边界：上一句（以句号等结尾）里的否定、用语前面隔着别的段（星系、人数、用语）时不算否定。
    @Test(arguments: ["no camp anymore. Jita clr", "not sure. clr", "no Jita clr", "Jita nv clr"])
    func lookBackStops(_ text: String) {
        #expect(parse(text).isClear, "\(text)")
    }

    /// 致意与道别（o7、gg、ty）不当人名（复审 N2）：`X clr o7` 仍是安全，敌对数量 0。
    @Test(arguments: ["HED-GP clr o7", "Jita clr GG", "Jita clr ty", "Jita clr o/", "Jita clr THX"])
    func signOffsKeepClear(_ text: String) {
        let report = parse(text)
        #expect(report.isClear, "\(text)")
        #expect(report.pilots.isEmpty, "\(text)")
        #expect(report.hostileCount == 0, "\(text)")
    }

    /// 否定后面带人数：不是安全，数量是写明的 10。
    @Test func negatedClearWithCount() {
        let report = parse("spike +10 not clr")
        #expect(!report.isClear)
        #expect(report.hostileCount == 10)
    }

    /// 疑问：用语后紧跟问号，或整条消息以问号结尾。
    @Test(arguments: ["Amarr clear?", "Amarr clr ?", "Amarr clr？", "Amarr clr gate?", "吉他 安全？"])
    func questionIsNotClear(_ text: String) {
        #expect(!parse(text).isClear, "\(text)")
    }

    /// 「安全等级」里的「安全」后面紧跟汉字，不是用语。
    @Test func securityStatusIsNotClear() {
        let report = parse("Jita 安全等级")
        #expect(!report.isClear)
        #expect(!report.segments.contains { $0.kind == .word(.clear) })
    }

    // MARK: - 对照

    /// 真正的「安全」：英文缩写、中文用语前后是空白、`*` 或行尾时都认得出，敌对数量是 0。
    @Test(arguments: ["HED-GP* clr", "吉他 安全", "吉他*安全", "吉他安全", "吉他 无人", "Jita clear.", "CLEAR Jita"])
    func realClear(_ text: String) {
        let report = parse(text)
        #expect(report.isClear, "\(text)")
        #expect(report.hostileCount == 0, "\(text)")
    }

    /// 有「安全」又写了人数：isClear 仍为真，但敌对数量取写明的数，不强制为 0。
    @Test func clearWithCountKeepsCount() {
        let report = parse("Jita clr 3")
        #expect(report.isClear)
        #expect(report.hostileCount == 3)
        let withShip = parse("Jita clr Rifter")
        #expect(withShip.isClear)
        #expect(withShip.hostileCount == 1)
    }

    /// 字符键层面：否定字与后面的汉字都挡住匹配，前面是普通汉字时不挡。
    @Test func characterBoundary() {
        let kinds = { (text: String) in data.matcher.matches(in: text).map(\.kind) }
        #expect(kinds("非安全").isEmpty)
        #expect(kinds("未无人").isEmpty)
        #expect(kinds("安全区").isEmpty)
        #expect(kinds("很安全") == [.intelWord(.clear)])
        #expect(kinds("吉他安全") == [.system(id: F.jita), .intelWord(.clear)])
    }
}
