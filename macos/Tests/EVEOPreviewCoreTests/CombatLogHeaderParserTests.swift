// SPDX-License-Identifier: GPL-3.0-or-later
//
// CombatLogHeaderParser 的用例（反馈文档 7.5 节、10.1 节）。

import Testing
import EVEOPreviewCore

/// 文件头的解析：8 种语言的标签、全角冒号、没有收听者、3 行的兜底、不完整与超长。
struct CombatLogHeaderParserTests {
    /// 中文与英文的真实文件头。
    @Test func realHeaders() {
        #expect(CombatLogHeaderParser.parse(CombatLogFixtures.zhHeader)
                == CombatLogHeader(listener: "Aurora Vale", isComplete: true))
        #expect(CombatLogHeaderParser.parse(CombatLogFixtures.enHeader)
                == CombatLogHeader(listener: "Aurora Vale", isComplete: true))
    }

    /// 8 种语言的收听者标签都能识别；名字里的空格保留。
    @Test(arguments: CombatLogFixtures.headerLabels.map(\.label))
    func eightLanguageLabels(_ label: String) throws {
        let entry = try #require(CombatLogFixtures.headerLabels.first { $0.label == label })
        let lines = CombatLogFixtures.header(title: entry.title, label: entry.label, session: entry.session,
                                             listener: "Sample Observer")
        #expect(CombatLogHeaderParser.parse(lines) == CombatLogHeader(listener: "Sample Observer", isComplete: true))
    }

    /// 全角冒号，以及法文排版习惯的「冒号前有空格」。
    @Test func colonVariants() {
        let fullWidth = CombatLogFixtures.header(title: "游戏记录", label: "收听者", session: "进程开始",
                                                 listener: "Aurora Vale", colon: "：")
        #expect(CombatLogHeaderParser.parse(fullWidth).listener == "Aurora Vale")
        let french = CombatLogFixtures.header(title: "Journal", label: "Auditeur", session: "Session commencée",
                                              listener: "Aurora Vale", colon: " : ")
        #expect(CombatLogHeaderParser.parse(french).listener == "Aurora Vale")
    }

    /// 登录界面阶段的文件：文件头完整，没有收听者（L3）。分隔线之间只有 2 行，不触发兜底。
    @Test func headerWithoutListener() {
        #expect(CombatLogHeaderParser.parse(CombatLogFixtures.zhHeaderWithoutListener)
                == CombatLogHeader(listener: nil, isComplete: true))
    }

    /// 标签不认识、但分隔线之间正好 3 行时，取第 2 行冒号后的部分。
    @Test func unknownLabelFallback() {
        let lines = CombatLogFixtures.header(title: "Pelilokit", label: "Kuuntelija", session: "Aloitettu",
                                             listener: "Sample Observer")
        #expect(CombatLogHeaderParser.parse(lines) == CombatLogHeader(listener: "Sample Observer", isComplete: true))
        // 不认识的标签且不是 3 行：没有收听者。
        var four = lines
        four.insert("  extra", at: 2)
        #expect(CombatLogHeaderParser.parse(four) == CombatLogHeader(listener: nil, isComplete: true))
    }

    /// 还没读到第二条分隔线：不完整，没有收听者。
    @Test func incompleteHeader() {
        let partial = Array(CombatLogFixtures.zhHeader.prefix(3))
        #expect(CombatLogHeaderParser.parse(partial) == CombatLogHeader(listener: nil, isComplete: false))
        #expect(CombatLogHeaderParser.parse([]) == CombatLogHeader(listener: nil, isComplete: false))
    }

    /// 读满 maxHeaderLines 行仍没有第二条分隔线：视为完整、没有收听者。之后的行不看。
    @Test func tooManyLines() {
        var lines = ["------------------------------------------------------------"]
        lines += Array(repeating: "  noise", count: CombatLogHeaderParser.maxHeaderLines)
        lines.append("------------------------------------------------------------")
        #expect(CombatLogHeaderParser.parse(lines) == CombatLogHeader(listener: nil, isComplete: true))
    }

    /// 空的收听者按没有收听者处理。
    @Test func emptyListener() {
        let lines = CombatLogFixtures.header(title: "Game Log", label: "Listener", session: "Session Started",
                                             listener: "   ")
        #expect(CombatLogHeaderParser.parse(lines).listener == nil)
    }
}
