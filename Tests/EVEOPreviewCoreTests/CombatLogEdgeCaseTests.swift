// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志一侧的边界用例（反馈文档 7.4～7.7 节、10.1 节），由测试方在集成后补充。
// 已有的 CombatLogParserTests、CombatLogHeaderParserTests、LogLineFramerTests、CombatAlertRulesTests
// 覆盖了 10.1 节的表，这里只补表里没有写到、但规则推得出的情况：
// - 分行器的结果与字节被切成几段无关（逐个切点、逐字节追加）。
// - 远程维修、能量中和一类「有数字但不是伤害」的行不提醒。
// - 文件头的冒号前有不换行空格、首行带 BOM、第二条分隔线恰在第 12 行。
// 测试方当初登记为已知问题的几项已在实现里修复，对应用例改成普通用例，注释里保留问题的来历。

import Foundation
import Testing
import EVEOPreviewCore

// MARK: - 分行器：切分方式不影响结果

/// 分行器的结果只取决于字节流本身，与字节分几次到达无关。
struct LogLineFramerChunkingTests {
    /// 一次追加全部字节得到的行。
    private func whole(_ data: Data, encoding: LogTextEncoding? = nil, maxLineBytes: Int = 65_536) -> [String] {
        var framer = LogLineFramer(encoding: encoding, maxLineBytes: maxLineBytes)
        return framer.append(data)
    }

    /// 在 cut 处切成两段先后追加得到的行。
    private func split(_ data: Data, at cut: Int, encoding: LogTextEncoding? = nil,
                       maxLineBytes: Int = 65_536) -> [String] {
        var framer = LogLineFramer(encoding: encoding, maxLineBytes: maxLineBytes)
        return framer.append(data.prefix(cut)) + framer.append(data.dropFirst(cut))
    }

    /// 逐字节追加得到的行。
    private func byteByByte(_ data: Data, encoding: LogTextEncoding? = nil) -> [String] {
        var framer = LogLineFramer(encoding: encoding)
        return data.reduce(into: [String]()) { lines, byte in lines += framer.append(Data([byte])) }
    }

    /// 把文本编码成带或不带 BOM 的字节。
    private static func encode(_ text: String, as encoding: LogTextEncoding, bom: Bool) -> Data {
        switch encoding {
        case .utf8:
            return Data(bom ? [0xEF, 0xBB, 0xBF] : []) + Data(text.utf8)
        case .utf16LittleEndian, .utf16BigEndian:
            let big = encoding == .utf16BigEndian
            var data = Data(bom ? (big ? [0xFE, 0xFF] : [0xFF, 0xFE]) : [])
            for unit in text.utf16 {
                data.append(contentsOf: big ? [UInt8(unit >> 8), UInt8(unit & 0xFF)]
                                            : [UInt8(unit & 0xFF), UInt8(unit >> 8)])
            }
            return data
        }
    }

    /// 样例文本：中文、日文、代理对（emoji）、CRLF、空行，以及 UTF-16 码元里含 0A 字节的字符
    /// （U+0A0A 的两个字节都是 0A，U+010A 的低字节是 0A），用来核对 UTF-16 按码元对齐找换行。
    static let sample = "  游戏记录\r\n  收听者: Aurora Vale\n\n[ 2026.01.01 00:00:00 ] (combat) 🛰️ ਊ Ċ 外した\r\ntail\n"

    /// 期望的行：与切分无关。
    static let expected = ["  游戏记录", "  收听者: Aurora Vale", "", "[ 2026.01.01 00:00:00 ] (combat) 🛰️ ਊ Ċ 外した",
                           "tail"]

    /// 3 种编码、带与不带 BOM：任一切点切成两段、逐字节追加，结果都与一次追加相同。
    @Test(arguments: [LogTextEncoding.utf8, .utf16LittleEndian, .utf16BigEndian], [true, false])
    func everyCutPointGivesSameLines(encoding: LogTextEncoding, bom: Bool) {
        let data = Self.encode(Self.sample, as: encoding, bom: bom)
        // 不带 BOM 的 UTF-16 无法自动判断，由调用方指定编码（7.4 节「从文件中间开始读」的做法）。
        let given: LogTextEncoding? = (encoding != .utf8 && !bom) ? encoding : nil
        #expect(whole(data, encoding: given) == Self.expected)
        for cut in 0...data.count {
            #expect(split(data, at: cut, encoding: given) == Self.expected, "切点 \(cut)")
        }
        #expect(byteByByte(data, encoding: given) == Self.expected)
    }

    /// 回车与换行被切在两次追加之间：回车照样去掉。
    @Test func carriageReturnSplitFromLineFeed() {
        var framer = LogLineFramer()
        #expect(framer.append(Data("abc\r".utf8)).isEmpty)
        #expect(framer.append(Data("\ndef\r\n".utf8)) == ["abc", "def"])
    }

    /// 长度正好等于上限、以 CRLF 结尾的行：一次追加时保留（回车不计入行长）。
    @Test func lineAtLimitWithCRLFKeptInOneAppend() {
        let data = Data("12345678\r\nnext\n".utf8)
        #expect(whole(data, maxLineBytes: 8) == ["12345678", "next"])
    }

    /// 同一字节流在回车与换行之间被切开时，结果应与一次追加相同。
    ///
    /// 问题的来历：keepTail 曾用「含回车的尾部字节数」与上限比较，尾部是「8 字节内容 + 回车」时超过上限 8，
    /// 进入丢弃状态，这一行被丢掉；一次追加时同一行被保留。现在比较时不计尾部的回车。
    @Test func lineAtLimitWithCRLFSplitBeforeLineFeed() {
        let data = Data("12345678\r\nnext\n".utf8)
        // 切点 9：第一段是「12345678\r」，第二段从「\n」开始。
        #expect(split(data, at: 9, maxLineBytes: 8) == ["12345678", "next"])
    }

    /// 内容等于上限、以 CRLF 结尾的行，以及超长的 CRLF 行：任一切点、逐字节追加的结果都与一次追加相同。
    @Test func limitAndOverlongCRLFLinesIndependentOfCuts() {
        let data = Data("ok\r\n12345678\r\n0123456789abcdef\r\n123456789\r\nlast\r\n".utf8)
        let expected = ["ok", "12345678", "last"]
        #expect(whole(data, maxLineBytes: 8) == expected)
        for cut in 0...data.count {
            #expect(split(data, at: cut, maxLineBytes: 8) == expected, "切点 \(cut)")
        }
        var framer = LogLineFramer(maxLineBytes: 8)
        let bytewise = data.reduce(into: [String]()) { lines, byte in lines += framer.append(Data([byte])) }
        #expect(bytewise == expected)
    }

    /// UTF-16 的 CRLF 同样不把回车计入行长（含切在回车码元中间的切点）。
    @Test(arguments: [LogTextEncoding.utf16LittleEndian, .utf16BigEndian])
    func limitCRLFLinesIndependentOfCutsUTF16(encoding: LogTextEncoding) {
        let text = "ab\r\n1234\r\n0123456789\r\nend\r\n"
        var data = Data()
        for unit in text.utf16 {
            data.append(contentsOf: encoding == .utf16BigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)]
                                                                 : [UInt8(unit & 0xFF), UInt8(unit >> 8)])
        }
        // 上限 8 字节即 4 个字符：「1234」正好等于上限，「0123456789」超长。
        let expected = ["ab", "1234", "end"]
        #expect(whole(data, encoding: encoding, maxLineBytes: 8) == expected)
        for cut in 0...data.count {
            #expect(split(data, at: cut, encoding: encoding, maxLineBytes: 8) == expected, "切点 \(cut)")
        }
    }

    /// 超长行之后的行不受切分方式影响（切点不落在回车与换行之间时）。
    @Test func overlongLineIndependentOfCuts() {
        let data = Data("ok\n0123456789abcdef\nfine\r\nlast\n".utf8)
        let expected = ["ok", "fine", "last"]
        #expect(whole(data, maxLineBytes: 8) == expected)
        for cut in 0...data.count where data[safe: cut - 1] != 0x0D {
            #expect(split(data, at: cut, maxLineBytes: 8) == expected, "切点 \(cut)")
        }
    }
}

extension Data {
    /// 越界时返回 nil 的下标，便于在用例里判断切点前一个字节。
    fileprivate subscript(safe index: Int) -> UInt8? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 单行归类：有数字但不是受到伤害的行

/// 「宁可漏报，不误报」：有开头数字、但不是两种伤害色的行不应提醒。
struct CombatLogParserNonDamageTests {
    /// 解析一行 combat 日志，取归类结果。
    private func kind(_ body: String) -> CombatLineKind? {
        CombatLogParser.parse(CombatLogFixtures.combat(body))?.kind
    }

    /// 远程维修（上游模板 519186～519190 的颜色 0xff7fffff）：各种颜色写法、中英文都归为 otherCombat。
    @Test func remoteRepairVariants() {
        // 英文：句中有 from，按方向词会误判成受到伤害。
        #expect(kind("<color=0xff7fffff><b>350</b><color=0x77ffffff><font size=10> remote armor repaired from </font><b><color=0xffffffff>Sample Pilot</b>") == .otherCombat)
        #expect(kind("<color=#FF7FFFFF><b>350</b> from Sample Pilot") == .otherCombat)
        #expect(kind("<color=\"0xff7fffff\"><b>1,200</b> 来自 Sample Pilot") == .otherCombat)
        // 远程维修与能量中和的行合并后没有事件，不提醒。
        let kinds = ["<color=0xff7fffff><b>350</b> from X", "<color=0xffccff66><b>-43 GJ</b> energy neutralized X"]
            .compactMap { kind($0) }
        #expect(CombatAlertRules.events(for: "X", kinds: kinds).isEmpty)
    }

    /// 颜色值带引号时照常识别为伤害色。
    @Test func quotedDamageColor() {
        #expect(kind("<color=\"0xffcc0000\"><b>42</b> 来自 X") == .incomingDamage(amount: 42))
        #expect(kind("<color='#ff00ffff'><b>42</b> to X") == .outgoingDamage(amount: 42))
    }

    /// 能量中和、能量传输的数字以 `-`、`+` 开头，不是开头的数字：不会被当成伤害。
    @Test func energyLinesNotDamage() {
        #expect(kind("<color=0xffe57f7f><b>-43 GJ</b><color=0x77ffffff><font size=10> energy neutralized </font><b>Sample Pilot</b>") == .otherCombat)
        #expect(kind("<color=0xff7fffff><b>+43 GJ</b><color=0x77ffffff><font size=10> energy drained from </font><b>Sample Pilot</b>") == .otherCombat)
    }

    /// 颜色只取数字前面的标记：数字后面的标记（如名字的白色）不改变方向。
    @Test func colorAfterNumberIgnored() {
        #expect(kind("<color=0xffcc0000><b>5</b> <color=0xff00ffff>from X") == .incomingDamage(amount: 5))
        #expect(kind("<b>5</b> <color=0xffcc0000>to X") == .outgoingDamage(amount: 5))
    }

    /// 行首有多个 BOM、行尾是 LF 或 CRLF：照常解析。
    @Test func multipleBOMsAndLineEndings() {
        let line = CombatLogFixtures.combat("<color=0xffcc0000><b>7</b> 来自 X")
        #expect(CombatLogParser.parse("\u{FEFF}\u{FEFF}" + line)?.kind == .incomingDamage(amount: 7))
        #expect(CombatLogParser.parse(line + "\n")?.kind == .incomingDamage(amount: 7))
        #expect(CombatLogParser.parse(line + "\r\n")?.kind == .incomingDamage(amount: 7))
    }

    /// 未命中的句尾：尾部空白、全角句号、大写都不影响。
    @Test func incomingMissEndingVariants() {
        #expect(kind("Sample Pilot misses you completely.  ") == .incomingMiss)
        #expect(kind("Sample Pilot MISSES YOU COMPLETELY") == .incomingMiss)
        #expect(kind("灾难皮希伊 粉碎者*完全没有打中你。") == .incomingMiss)
        // 句尾后面还有别的文字时不是对方未命中；含通用短语，归为己方未命中，不提醒。
        #expect(kind("Sample Pilot misses you completely - Sample Module") == .outgoingMiss)
    }

    /// 对方武器未命中、而武器名以数字开头（英文模板「武器 belonging to 驾驶员 misses you completely」）。
    ///
    /// 问题的来历：可见文字以数字开头的行曾一律当作「有开头的数字」，未命中判断只在没有开头数字时进行，
    /// `125mm`、`425mm` 一类炮塔的未命中因此归为 otherCombat。现在没有颜色、方向词也不匹配时，转按未命中判断。
    @Test func digitLeadingWeaponMiss() {
        #expect(kind("125mm Gatling AutoCannon II belonging to Sample Pilot misses you completely") == .incomingMiss)
        #expect(kind("425mm Railgun II von Sample Pilot hat Sie völlig verfehlt") == .incomingMiss)
        #expect(kind("1400mm Howitzer Artillery II, de Sample Pilot, falla por mucho.") == .incomingMiss)
        // 己方的数字开头武器未命中：句尾不是对方未命中，归为己方未命中。
        #expect(kind("125mm Gatling AutoCannon II misses Sample Pilot completely") == .outgoingMiss)
    }

    /// 数字开头的真实伤害行不受影响：有颜色按颜色，没有颜色按方向词，方向词与未命中短语同时出现时以方向词为准。
    @Test func damageLinesUnaffectedByMissFallThrough() {
        #expect(kind("<color=0xffcc0000><b>12</b> from Sample Pilot - 125mm Gatling misses") == .incomingDamage(amount: 12))
        #expect(kind("12 from Sample Pilot - Gatling - Hits") == .incomingDamage(amount: 12))
        #expect(kind("12 to Sample Pilot - Gatling - Hits") == .outgoingDamage(amount: 12))
        #expect(kind("12 来自 Sample Pilot - 轨道炮 - 击中") == .incomingDamage(amount: 12))
        // 无颜色、无方向词、也不是未命中：仍是 otherCombat。
        #expect(kind("12 mm unknown module activated") == .otherCombat)
    }

    /// 韩文己方未命中：上游模板写的是「을(를)」，客户端若按名字的收音把它换成「을」或「를」，
    /// 句尾与对方未命中相同，曾被当成对方未命中（误报）。现在三种写法都列入排除短语。
    ///
    /// 只有模板，没有韩文客户端的真实样例（V15）。
    @Test func koreanResolvedParticle() {
        // 模板原样（含「을(를)」）时判断正确。
        #expect(kind("Sample Module이(가) Sample Pilot을(를) 완전히 빗나감") == .outgoingMiss)
        #expect(kind("Sample Module이 Sample Pilot을 완전히 빗나감") == .outgoingMiss)
        // 名字以元音结尾时助词是「를」，故意写成 Pilo。
        #expect(kind("Sample Module이 Sample Pilo를 완전히 빗나감") == .outgoingMiss)
        // 对方未命中：助词是「이(가)」或实际的「이」「가」，仍是 incomingMiss。
        #expect(kind("Sample Pilot의 Sample Module이(가) 완전히 빗나감") == .incomingMiss)
        #expect(kind("Sample Pilot의 Sample Module이 완전히 빗나감") == .incomingMiss)
        #expect(kind("Sample Pilot의 Sample Modul가 완전히 빗나감") == .incomingMiss)
    }
}

// MARK: - 文件头

/// 文件头的边界：冒号前的不换行空格、首行 BOM、第二条分隔线的位置。
struct CombatLogHeaderEdgeCaseTests {
    /// 用指定的冒号写法拼一个法文文件头。
    private func french(colon: String, extraLines: Int = 0) -> [String] {
        var lines = CombatLogFixtures.header(title: "Journal de jeu", label: "Auditeur", session: "Session commencée",
                                             listener: "Aurora Vale", colon: colon)
        lines.insert(contentsOf: Array(repeating: "  extra", count: extraLines), at: 1)
        return lines
    }

    /// 法文排版在冒号前用不换行空格（U+00A0）：按标签识别。
    @Test func frenchNoBreakSpaceBeforeColon() {
        #expect(CombatLogHeaderParser.parse(french(colon: "\u{00A0}: ")).listener == "Aurora Vale")
        // 标签识别不依赖兜底：分隔线之间多一行（不是 3 行）也能取到。
        #expect(CombatLogHeaderParser.parse(french(colon: "\u{00A0}: ", extraLines: 1)).listener == "Aurora Vale")
    }

    /// 窄不换行空格（U+202F）不在标签后允许的空白里：3 行的文件头靠兜底取到收听者。
    @Test func frenchNarrowNoBreakSpaceFallsBackToThreeLineRule() {
        #expect(CombatLogHeaderParser.parse(french(colon: "\u{202F}: ")).listener == "Aurora Vale")
    }

    /// 第一条分隔线前有 BOM、各行带回车：照常识别。
    @Test func bomAndCarriageReturns() {
        var lines = CombatLogFixtures.zhHeader.map { $0 + "\r" }
        lines[0] = "\u{FEFF}" + lines[0]
        #expect(CombatLogHeaderParser.parse(lines) == CombatLogHeader(listener: "Aurora Vale", isComplete: true))
    }

    /// 第二条分隔线恰在第 12 行：仍在读取范围内，取到收听者；在第 13 行时超出范围，没有收听者。
    @Test func secondSeparatorAtLineLimit() {
        let separator = "------------------------------------------------------------"
        func lines(paddingCount: Int) -> [String] {
            [separator, "  Game Log", "  Listener: Aurora Vale"]
                + Array(repeating: "  padding", count: paddingCount) + [separator]
        }
        // 1 + 2 + 8 + 1 = 12 行。
        let atLimit = lines(paddingCount: CombatLogHeaderParser.maxHeaderLines - 4)
        #expect(atLimit.count == CombatLogHeaderParser.maxHeaderLines)
        #expect(CombatLogHeaderParser.parse(atLimit) == CombatLogHeader(listener: "Aurora Vale", isComplete: true))
        let beyond = lines(paddingCount: CombatLogHeaderParser.maxHeaderLines - 3)
        #expect(CombatLogHeaderParser.parse(beyond) == CombatLogHeader(listener: nil, isComplete: true))
    }

    /// 分行器与文件头解析串起来：UTF-16 小端带 BOM 的文件头也能取到收听者。
    @Test func utf16HeaderThroughFramer() {
        let text = CombatLogFixtures.enHeader.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 { data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        var framer = LogLineFramer()
        let lines = framer.append(data)
        #expect(CombatLogHeaderParser.parse(lines) == CombatLogHeader(listener: "Aurora Vale", isComplete: true))
    }
}

// MARK: - 事件合并与触发

/// 事件合并与触发规则串起来的结果。
struct CombatAlertCoalescingEdgeCaseTests {
    /// 合并一批行后，是否至少有一条事件会提醒。
    private func alerts(_ kinds: [CombatLineKind], _ settings: CombatAlertSettings) -> Bool {
        CombatAlertRules.events(for: "X", kinds: kinds).contains { CombatAlertRules.triggers($0.kind, settings: settings) }
    }

    /// 小于阈值的伤害加一次未命中：按未命中提醒（7.7 节写明的场景）。
    @Test func smallHitPlusMissAlerts() {
        let settings = CombatAlertSettings(minimumDamage: 100)
        #expect(alerts([.incomingDamage(amount: 5), .incomingMiss], settings))
        #expect(!alerts([.incomingDamage(amount: 5)], settings))
    }

    /// 伤害数字的上限：Int.max 不溢出，最小伤害取上界 100,000 时照常比较。
    @Test func extremeAmounts() {
        let settings = CombatAlertSettings(minimumDamage: 100_000)
        #expect(alerts([.incomingDamage(amount: Int.max)], settings))
        #expect(alerts([.incomingDamage(amount: 100_000)], settings))
        #expect(!alerts([.incomingDamage(amount: 99_999)], settings))
    }

    /// 数字为 0 的命中按未命中对待（7.7 节触发表）。同一次读取里还有一次小于阈值的伤害时，0 不会被它盖住。
    ///
    /// 问题的来历：events 曾只按数字取最大值，0 被较大的数字盖住，整批不提醒。现在同批里有正数伤害时，
    /// 数字为 0 的命中另报一条 `incomingMiss`，是否提醒由 includeMisses 决定。
    @Test func zeroHitMaskedBySmallHit() {
        let settings = CombatAlertSettings(minimumDamage: 100)
        #expect(alerts([.incomingDamage(amount: 0)], settings))
        #expect(alerts([.incomingDamage(amount: 0), .incomingDamage(amount: 5)], settings))
        #expect(alerts([.incomingDamage(amount: 5), .incomingDamage(amount: 0)], settings))
        // 关掉未命中后：0 加小伤害不提醒，0 加不小于阈值的伤害提醒。
        var noMisses = settings
        noMisses.includeMisses = false
        #expect(!alerts([.incomingDamage(amount: 0), .incomingDamage(amount: 5)], noMisses))
        #expect(!alerts([.incomingDamage(amount: 0)], noMisses))
        #expect(alerts([.incomingDamage(amount: 0), .incomingDamage(amount: 150)], noMisses))
    }

    /// 事件形态：0 加正数伤害得到「最大伤害 + 未命中」两条，仍不超过两条；只有 0 时只有一条伤害事件。
    @Test func zeroHitEventShape() {
        #expect(CombatAlertRules.events(for: "X", kinds: [.incomingDamage(amount: 0), .incomingDamage(amount: 5)]) == [
            CombatLogEvent(character: "X", kind: .incomingDamage(amount: 5)),
            CombatLogEvent(character: "X", kind: .incomingMiss),
        ])
        #expect(CombatAlertRules.events(for: "X", kinds: [.incomingDamage(amount: 0), .incomingDamage(amount: 0)])
                == [CombatLogEvent(character: "X", kind: .incomingDamage(amount: 0))])
        #expect(CombatAlertRules.events(for: "X", kinds: [.incomingDamage(amount: 0), .incomingMiss, .incomingDamage(amount: 5)])
                .count == 2)
    }
}
