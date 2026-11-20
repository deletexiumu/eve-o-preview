// SPDX-License-Identifier: GPL-3.0-or-later
//
// CombatLogParser 的用例（反馈文档 7.6 节、10.1 节）。样例见 CombatLogFixtures.swift。

import Testing
import EVEOPreviewCore

/// 单行的解析与归类。
struct CombatLogParserTests {
    /// 解析一行并取归类结果；不是日志行时返回 nil。
    private func kind(_ line: String) -> CombatLineKind? {
        CombatLogParser.parse(line)?.kind
    }

    // MARK: - 中文（本机真实格式）

    /// 中文的各类行：受到伤害、造成伤害、数字为 0、两种对方未命中、己方未命中、跃迁扰断、hint。
    @Test func chineseLines() {
        #expect(kind(CombatLogFixtures.zhIncoming) == .incomingDamage(amount: 19))
        #expect(kind(CombatLogFixtures.zhOutgoing) == .outgoingDamage(amount: 117))
        #expect(kind(CombatLogFixtures.zhIncomingZero) == .incomingDamage(amount: 0))
        #expect(kind(CombatLogFixtures.zhIncomingMiss) == .incomingMiss)
        #expect(kind(CombatLogFixtures.zhIncomingMissWeapon) == .incomingMiss)
        #expect(kind(CombatLogFixtures.zhOutgoingMiss) == .outgoingMiss)
        #expect(kind(CombatLogFixtures.zhWarpScramble) == .otherCombat)
        #expect(CombatLogParser.parse(CombatLogFixtures.zhHint) == CombatLogLine(category: "hint", kind: .other))
    }

    /// 类别转成小写，非 combat 类别一律是 other。
    @Test func nonCombatCategories() {
        #expect(CombatLogParser.parse(CombatLogFixtures.ruNoneCategory) == CombatLogLine(category: "none", kind: .other))
        let upper = "[ 2026.11.20 11:33:51 ] (COMBAT) 灾难皮希伊 粉碎者*完全没有打中你"
        #expect(CombatLogParser.parse(upper) == CombatLogLine(category: "combat", kind: .incomingMiss))
    }

    // MARK: - 日文与俄文（上游录制样例）

    /// 日文两个方向的介词相同，只靠颜色区分；去掉颜色后归为 otherCombat，不猜方向。
    @Test func japaneseUsesColorOnly() {
        #expect(kind(CombatLogFixtures.jaIncoming) == .incomingDamage(amount: 40))
        #expect(kind(CombatLogFixtures.jaOutgoing) == .outgoingDamage(amount: 492))
        #expect(kind(CombatLogFixtures.jaNoColor) == .otherCombat)
        #expect(kind(CombatLogFixtures.jaIncomingMiss) == .incomingMiss)
        #expect(kind(CombatLogFixtures.jaOutgoingMiss) == .outgoingMiss)
    }

    /// 俄文的伤害行与未命中。
    @Test func russianLines() {
        #expect(kind(CombatLogFixtures.ruIncoming) == .incomingDamage(amount: 130))
        #expect(kind(CombatLogFixtures.ruOutgoing) == .outgoingDamage(amount: 983))
        #expect(kind(CombatLogFixtures.ruIncomingMiss) == .incomingMiss)
        #expect(kind(CombatLogFixtures.ruOutgoingMiss) == .outgoingMiss)
    }

    // MARK: - 英文与只有模板的语言

    /// 英文的伤害行与两种对方未命中、一种己方未命中。
    @Test func englishLines() {
        #expect(kind(CombatLogFixtures.enIncoming) == .incomingDamage(amount: 214))
        #expect(kind(CombatLogFixtures.enOutgoing) == .outgoingDamage(amount: 214))
        #expect(kind(CombatLogFixtures.enIncomingMiss) == .incomingMiss)
        #expect(kind(CombatLogFixtures.enIncomingMissWeapon) == .incomingMiss)
        #expect(kind(CombatLogFixtures.enOutgoingMiss) == .outgoingMiss)
    }

    /// 德、法、西、韩：带颜色与不带颜色的两个方向，以及两种未命中。
    @Test(arguments: CombatLogFixtures.templateLanguages.map(\.name))
    func templateLanguages(_ name: String) throws {
        let lang = try #require(CombatLogFixtures.templateLanguages.first { $0.name == name })
        let combat = CombatLogFixtures.combat
        #expect(kind(combat("<color=0xffcc0000><b>214</b> " + lang.incomingMiddle)) == .incomingDamage(amount: 214))
        #expect(kind(combat("<color=0xff00ffff><b>214</b> " + lang.outgoingMiddle)) == .outgoingDamage(amount: 214))
        // 没有颜色标记时改用方向词或韩文的句尾。
        #expect(kind(combat("<b>214</b> " + lang.incomingMiddle)) == .incomingDamage(amount: 214))
        #expect(kind(combat("<b>214</b> " + lang.outgoingMiddle)) == .outgoingDamage(amount: 214))
        #expect(kind(combat(lang.incomingMiss)) == .incomingMiss)
        #expect(kind(combat(lang.outgoingMiss)) == .outgoingMiss)
    }

    /// 没有颜色时方向词不区分大小写；没有任何方向词时是 otherCombat。
    @Test func directionWordsWithoutColor() {
        let combat = CombatLogFixtures.combat
        #expect(kind(combat("<b>50</b> <font size=10>FROM <b>Sample Pilot</b>")) == .incomingDamage(amount: 50))
        #expect(kind(combat("<b>50</b> <font size=10>来自</font> <b>Sample Pilot</b>")) == .incomingDamage(amount: 50))
        #expect(kind(combat("<b>50</b> <font size=10>对</font> <b>Sample Pilot</b>")) == .outgoingDamage(amount: 50))
        #expect(kind(combat("<b>50</b> <b>Sample Pilot</b>")) == .otherCombat)
    }

    /// 有颜色但不是两种伤害色（远程维修一类，上游模板 519190 用 0xff7fffff 且句中有「来自」）：不猜方向。
    @Test func unknownColorIsOtherCombat() {
        let repair = CombatLogFixtures.combat(
            "<color=0xff7fffff><b>120</b><color=0x77ffffff><font size=10>来自</font><b><color=0xffffffff>Sample Pilot</b>远程装甲维修")
        #expect(kind(repair) == .otherCombat)
    }

    // MARK: - 数字与颜色的写法

    /// 数字之间的千分位逗号、不换行空格与窄不换行空格被跳过。
    @Test func groupedNumbers() {
        let combat = CombatLogFixtures.combat
        #expect(kind(combat("<color=0xffcc0000><b>1,265</b> 来自 X")) == .incomingDamage(amount: 1_265))
        #expect(kind(combat("<color=0xffcc0000><b>12\u{00A0}345</b> 来自 X")) == .incomingDamage(amount: 12_345))
        #expect(kind(combat("<color=0xffcc0000><b>1\u{202F}000\u{202F}000</b> 来自 X")) == .incomingDamage(amount: 1_000_000))
        // 分隔符后不是数字时，数字到此结束。
        #expect(kind(combat("<color=0xffcc0000><b>12,</b> 来自 X")) == .incomingDamage(amount: 12))
    }

    /// 颜色值大写、`#` 前缀都能识别；取跳过的标记里最后一个颜色。
    @Test func colorVariants() {
        let combat = CombatLogFixtures.combat
        #expect(kind(combat("<color=0xFFCC0000><b>7</b> X")) == .incomingDamage(amount: 7))
        #expect(kind(combat("<color=#FF00FFFF><b>8</b> X")) == .outgoingDamage(amount: 8))
        #expect(kind(combat("<color=0xff00ffff><font size=10><color=0xffcc0000><b>9</b> X")) == .incomingDamage(amount: 9))
    }

    /// 超出 Int 范围的数字取 Int.max，不崩溃。
    @Test func hugeNumberSaturates() {
        let line = CombatLogFixtures.combat("<color=0xffcc0000><b>99999999999999999999999</b> 来自 X")
        #expect(kind(line) == .incomingDamage(amount: Int.max))
    }

    // MARK: - 行的形式

    /// 不是日志行的输入返回 nil：多行条目的后续行、空行、时间不完整、括号缺失。
    @Test func malformedLinesReturnNil() {
        #expect(CombatLogParser.parse("") == nil)
        #expect(CombatLogParser.parse("  续行文字，不以方括号开头") == nil)
        #expect(CombatLogParser.parse("[ 2026.10.22 10:30 ] (combat) x") == nil)
        #expect(CombatLogParser.parse("[ 2026.10.22 10:30:1x ] (combat) x") == nil)
        #expect(CombatLogParser.parse("[2026.10.22 10:30:13] (combat) x") == nil)
        #expect(CombatLogParser.parse("[ 2026.10.22 10:30:13 ] combat x") == nil)
        #expect(CombatLogParser.parse("[ 2026.10.22 10:30:13 ] (combat x") == nil)
        // 从文件中间读起时，第一段是半行。
        #expect(CombatLogParser.parse("ffffff>古斯塔斯塔台岗哨 II*</b> - 穿透") == nil)
    }

    /// 行首的 U+FEFF 与行尾的回车被去掉；正文为空的行也能解析。
    @Test func bomAndCarriageReturn() {
        #expect(kind("\u{FEFF}" + CombatLogFixtures.zhIncomingMiss + "\r") == .incomingMiss)
        #expect(kind(CombatLogFixtures.zhIncoming + "\r") == .incomingDamage(amount: 19))
        #expect(CombatLogParser.parse("[ 2026.10.22 10:30:13 ] (notify)") == CombatLogLine(category: "notify", kind: .other))
    }

    // MARK: - plainText 与 logTime

    /// 标记被删掉，连续空白合成一个空格；找不到 `>` 的 `<` 保留为普通字符。
    @Test func plainTextStripsMarkup() {
        #expect(CombatLogParser.plainText("<b>19</b> <color=0x77ffffff><font size=10>来自</font>  <b>X</b>") == "19 来自 X")
        #expect(CombatLogParser.plainText("  a\u{00A0}\u{00A0}b  ") == "a b")
        // `<` 与其后第一个 `>` 之间的内容一律删掉；最后一个找不到 `>` 的 `<` 保留。
        #expect(CombatLogParser.plainText("a <b>x</b> < tail") == "a x < tail")
        #expect(CombatLogParser.plainText("x <unclosed") == "x <unclosed")
        #expect(CombatLogParser.plainText("A &amp; B") == "A &amp; B")
    }

    /// 日志时间按 UTC 换算成 1970 年以来的秒数；不合法的日期返回 nil。
    @Test func logTimeIsUTC() {
        // 2026-11-20 09:51:46 UTC = 1,795,168,306 秒（由 days_from_civil 推算，与 date -u 核对一致）。
        #expect(CombatLogParser.logTime("[ 2026.11.20 09:51:46 ] (hint) x") == 1_795_168_306)
        #expect(CombatLogParser.logTime("[ 1970.01.01 00:00:00 ] (hint) x") == 0)
        #expect(CombatLogParser.logTime("[ 2026.13.01 00:00:00 ] (hint) x") == nil)
        #expect(CombatLogParser.logTime("not a log line") == nil)
    }
}
