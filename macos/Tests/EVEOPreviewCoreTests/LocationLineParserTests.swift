// SPDX-License-Identifier: GPL-3.0-or-later
//
// LocationLineParser 的用例（docs/macos/design-intel-translate.md 5.6 节、14.1 节）：Local 的切换消息、
// 游戏日志的 4 种句式与 (None) 行。星系与空间站名是游戏的公开数据。

import Testing
import EVEOPreviewCore

/// 位置线索的句式。
struct LocationLineParserTests {
    /// Local 的英文与中文切换消息，带 `*` 与句号；没有冒号时返回 nil。
    @Test func localSystemLines() {
        #expect(LocationLineParser.systemName(fromLocalSystemLine: "Channel changed to Local : Jita") == "Jita")
        #expect(LocationLineParser.systemName(fromLocalSystemLine: "频道更换为本地：吉他*") == "吉他")
        #expect(LocationLineParser.systemName(fromLocalSystemLine: "Channel changed to Local : New Caldari.")
                == "New Caldari")
        #expect(LocationLineParser.systemName(fromLocalSystemLine: "Local: HED-GP* 。") == "HED-GP")
        #expect(LocationLineParser.systemName(fromLocalSystemLine: "Channel changed to Local") == nil)
        #expect(LocationLineParser.systemName(fromLocalSystemLine: "Channel changed to Local : ") == nil)
    }

    /// 5.6 节表里的 4 种句式。
    @Test func gameNotePatterns() {
        #expect(LocationLineParser.systemName(fromGameNote: "从吉他*跳到皮尔米特*") == "皮尔米特")
        #expect(LocationLineParser.systemName(fromGameNote: "从1DQ1-A跳到T5ZI-S") == "T5ZI-S")
        #expect(LocationLineParser.systemName(
            fromGameNote: "正在从 吉他 IV - 卫星 4 - 加达里海军组装工厂* 离站进入 吉他* 恒星系。") == "吉他")
        #expect(LocationLineParser.systemName(fromGameNote: "Jumping from Jita to Perimeter") == "Perimeter")
        #expect(LocationLineParser.systemName(fromGameNote: "jumping from New Caldari to Urlen.") == "Urlen")
        #expect(LocationLineParser.systemName(
            fromGameNote: "Undocking from Jita IV - Moon 4 - Caldari Navy Assembly Plant to Jita solar system.")
                == "Jita")
    }

    /// 不认识的句式返回 nil（交给 LocationTracker 兜底）。
    @Test(arguments: ["Вы прыгнули из Jita в Perimeter", "Jita", "", "Undocking from somewhere"])
    func unknownPatterns(text: String) {
        #expect(LocationLineParser.systemName(fromGameNote: text) == nil)
    }

    /// gameNote 只认 None 类别（不区分大小写），正文去掉标记；时间按 UTC 换算。
    @Test func gameNotes() throws {
        let note = try #require(LocationLineParser.gameNote(
            "[ 2026.11.20 11:33:46 ] (None) 从<b>吉他*</b>跳到<color=0xffffffff>皮尔米特*"))
        #expect(note.time == ChatLogFixtures.sampleTime)
        #expect(note.text == "从吉他*跳到皮尔米特*")
        #expect(LocationLineParser.gameNote("[ 2026.11.20 11:33:46 ] (NONE) Jumping from Jita to Perimeter")?.text
                == "Jumping from Jita to Perimeter")
        #expect(LocationLineParser.gameNote("[ 2026.11.20 11:33:46 ] (combat) 100 from Sabre") == nil)
        #expect(LocationLineParser.gameNote("[ 2026.11.20 11:33:46 ] (notify) 从吉他跳到皮尔米特") == nil)
        #expect(LocationLineParser.gameNote("not a log line") == nil)
        #expect(LocationLineParser.gameNote("\u{FEFF}[ 2026.11.20 11:33:46 ] (None) x")?.text == "x")
    }
}
