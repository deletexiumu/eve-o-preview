// SPDX-License-Identifier: GPL-3.0-or-later
//
// ChatLogParser 的用例（docs/design-intel-translate.md 5.2 节、14.1 节）。说话人、收听者与频道名都是虚构的。
// 最后一组用例走一遍真实的读取路径：带 BOM 的 UTF-16 小端字节 → LogLineFramer → parseHeader 与 parseLine。

import Foundation
import Testing
import EVEOPreviewCore

/// 文件头、消息行、频道种类与正文清理。
struct ChatLogParserTests {
    // MARK: 文件头

    /// 3 份文件头：玩家频道、Local、军团。
    @Test func headers() {
        let player = ChatLogParser.parseHeader(ChatLogFixtures.playerHeader)
        #expect(player == ChatLogHeader(channelID: ChatLogFixtures.playerChannelID,
                                        channelName: ChatLogFixtures.playerChannelName,
                                        listener: ChatLogFixtures.listener, isComplete: true))
        #expect(player.kind == .player)
        let local = ChatLogParser.parseHeader(ChatLogFixtures.localHeader)
        #expect(local.channelID == "local" && local.channelName == "Local" && local.kind == .local)
        let corp = ChatLogParser.parseHeader(ChatLogFixtures.corpHeader)
        #expect(corp.channelID == "corp" && corp.kind == .corp && corp.listener == ChatLogFixtures.listener)
    }

    /// 标签被翻译、一个都不认识，而字段正好 4 行时，按位置取第 1、2、3 行。
    @Test func unknownLabelsFallBackToPosition() {
        let lines = ["\u{FEFF}", "", ChatLogFixtures.separator,
                     "  频道 ID：player_abc", "  频道名称： intel.Demo", "  收听者：Kael Doran", "  开始：2026.11.20 11:33:40",
                     ChatLogFixtures.separator]
        let header = ChatLogParser.parseHeader(lines)
        #expect(header == ChatLogHeader(channelID: "player_abc", channelName: "intel.Demo", listener: "Kael Doran",
                                        isComplete: true))
    }

    /// 标签不认识但不是 4 行时不猜，字段都为 nil。
    @Test func unknownLabelsWithWrongCount() {
        let lines = [ChatLogFixtures.separator, "A: 1", "B: 2", "C: 3", ChatLogFixtures.separator]
        let header = ChatLogParser.parseHeader(lines)
        #expect(header.isComplete && header.channelID == nil && header.listener == nil)
    }

    /// 标签不区分大小写；值为空时字段为 nil；值里的冒号保留。
    @Test func labelsAndValues() {
        let lines = [ChatLogFixtures.separator, "channel id: corp", "CHANNEL NAME:", "Listener: Kael: Doran",
                     ChatLogFixtures.separator]
        let header = ChatLogParser.parseHeader(lines)
        #expect(header.channelID == "corp" && header.channelName == nil && header.listener == "Kael: Doran")
    }

    /// 文件刚建出来、还没有第二条分隔线：不完整。
    @Test func incompleteHeader() {
        let header = ChatLogParser.parseHeader(Array(ChatLogFixtures.playerHeader.prefix(8)))
        #expect(!header.isComplete && header.channelID == nil)
    }

    /// 读满 maxHeaderLines 行仍没有第二条分隔线：视为完整，字段为 nil。
    @Test func fullWithoutSecondSeparator() {
        let lines = [ChatLogFixtures.separator] + Array(repeating: "Channel ID: corp", count: 20)
        let header = ChatLogParser.parseHeader(lines)
        #expect(header == ChatLogHeader(channelID: nil, channelName: nil, listener: nil, isComplete: true))
    }

    // MARK: 消息行

    /// 带 U+FEFF 与回车的消息行；时间按 UTC 换算。
    @Test func messageLine() throws {
        let line = try #require(ChatLogParser.parseLine(ChatLogFixtures.intelMessage + "\r"))
        #expect(line.time == ChatLogFixtures.sampleTime)
        #expect(line.speaker == ChatLogFixtures.speaker)
        #expect(line.text == "1DQ1-A  Tarn Vex  Sabre nv")
        #expect(!line.isSystem)
    }

    /// 正文里的 ` > ` 保留在正文里；说话人里没有空格包围的 `>` 不影响拆分。
    @Test func arrowInsideText() throws {
        let line = try #require(ChatLogParser.parseLine(
            ChatLogFixtures.messageLine(speaker: "Ilya>Morrow", text: "Jita > Perimeter > Urlen")))
        #expect(line.speaker == "Ilya>Morrow")
        #expect(line.text == "Jita > Perimeter > Urlen")
    }

    /// 不合法的行返回 nil：时间不合法、没有 ` > `、空行、说话人为空、括号不对。
    @Test(arguments: [
        "\u{FEFF}[ 2026.13.20 11:33:46 ] Mira Voss > hi",
        "\u{FEFF}[ 2026.11.20 25:33:46 ] Mira Voss > hi",
        "\u{FEFF}[ 2026.11.20 11:33 ] Mira Voss > hi",
        "\u{FEFF}[ 2026.11.20 11:33:46 ] Mira Voss: hi",
        "\u{FEFF}[ 2026.11.20 11:33:46 ]  > hi",
        "\u{FEFF}2026.11.20 11:33:46 ] Mira Voss > hi",
        "",
        "\u{FEFF}",
    ])
    func invalidLines(line: String) {
        #expect(ChatLogParser.parseLine(line) == nil)
    }

    /// EVE System 与 EVE系统 是系统消息。
    @Test func systemSpeakers() throws {
        #expect(try #require(ChatLogParser.parseLine(ChatLogFixtures.localChangeEnglish)).isSystem)
        let chinese = try #require(ChatLogParser.parseLine(ChatLogFixtures.localChangeChinese))
        #expect(chinese.isSystem && chinese.text == "频道更换为本地：吉他*")
        #expect(ChatLogParser.systemSpeakers == ["EVE System", "EVE系统"])
    }

    // MARK: 正文清理

    /// 保留连续空格，去掉标记，<br> 换成换行，解码 5 种实体，去首尾空白。
    @Test func plainText() {
        #expect(ChatLogParser.plainText("  HED-GP*  Tarn Vex  ") == "HED-GP*  Tarn Vex")
        #expect(ChatLogParser.plainText("<b>Jita</b>\tclr") == "Jita\tclr")
        #expect(ChatLogParser.plainText("a<br>b<BR/>c<br />d") == "a\nb\nc\nd")
        #expect(ChatLogParser.plainText("&lt;3 &amp;&amp; &quot;x&quot; it&#39;s &gt;") == "<3 && \"x\" it's >")
        #expect(ChatLogParser.plainText("&amp;lt;") == "&lt;")
        #expect(ChatLogParser.plainText("1 < 2 and 3") == "1 < 2 and 3")
        #expect(ChatLogParser.plainText("&nbsp;x") == "&nbsp;x")
    }

    /// channelKind 的 7 种结果，比较不区分大小写。
    @Test func channelKinds() {
        #expect(ChatLogParser.channelKind(id: "local") == .local)
        #expect(ChatLogParser.channelKind(id: "Corp") == .corp)
        #expect(ChatLogParser.channelKind(id: "alliance") == .alliance)
        #expect(ChatLogParser.channelKind(id: "fleet_123") == .fleet)
        #expect(ChatLogParser.channelKind(id: "player_abc") == .player)
        #expect(ChatLogParser.channelKind(id: "PRIVATE_1") == .privateChat)
        #expect(ChatLogParser.channelKind(id: "something") == .other)
        #expect(ChatLogParser.channelKind(id: nil) == .other)
    }

    // MARK: 真实的读取路径

    /// UTF-16 小端字节（文件头 LF、消息行 CRLF 且以 U+FEFF 开头）经 LogLineFramer 切行后解析；
    /// 字节分成奇数大小的两段追加，切点落在码元中间也不错位。
    @Test func endToEndThroughFramer() throws {
        let text = ChatLogFixtures.fileText(header: ChatLogFixtures.playerHeader,
                                            messages: [ChatLogFixtures.intelMessage, ChatLogFixtures.localChangeEnglish])
        let bytes = ChatLogFixtures.utf16LEWithBOM(text)
        #expect(bytes.prefix(2) == Data([0xFF, 0xFE]) && bytes.count % 2 == 0)
        var framer = LogLineFramer()
        let cut = 301
        var lines = framer.append(bytes.prefix(cut))
        lines += framer.append(bytes.dropFirst(cut))
        #expect(framer.encoding == .utf16LittleEndian)
        let header = ChatLogParser.parseHeader(Array(lines.prefix(ChatLogParser.maxHeaderLines)))
        #expect(header.channelID == ChatLogFixtures.playerChannelID && header.listener == ChatLogFixtures.listener)
        let parsed = lines.compactMap(ChatLogParser.parseLine)
        #expect(parsed.count == 2)
        #expect(parsed.first?.text == "1DQ1-A  Tarn Vex  Sabre nv")
        #expect(parsed.last?.isSystem == true)
    }
}
