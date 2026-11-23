// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的测试样例（docs/macos/design-intel-translate.md 14.1 节）：按 C3 的格式拼出的文件头（玩家频道、Local、
// 军团频道各一份）与各种消息行，以及把文本编码成带 BOM 的 UTF-16 小端字节的辅助函数。
// 说话人、收听者与频道名都是虚构的；星系名是游戏的公开数据。三个并行的工作包只读不改。
//
// 文件头 12 行（C3）：第 1 行只有 U+FEFF（BOM 之后的第一个字符），第 2～4 行为空，第 5 行与第 11 行是分隔线，
// 第 6 行为空，第 7～10 行是 4 个字段，第 12 行为空。文件头的各行以 LF 结尾，消息行以 U+FEFF 开头、CRLF 结尾。

import Foundation

/// 聊天日志的样例。
enum ChatLogFixtures {
    /// 虚构的收听者。
    static let listener = "Kael Doran"
    /// 虚构的玩家频道。
    static let playerChannelName = "intel.Demo"
    static let playerChannelID = "player_0123456789abcdef0123456789abcdef"
    /// 虚构的说话人。
    static let speaker = "Mira Voss"
    /// 2026-11-20 11:33:46 UTC 的秒数，与样例消息行的时间相同。
    static let sampleTime = 1_795_174_426.0

    /// 分隔线（前面有缩进，与客户端写的一样）。
    static let separator = "        ---------------------------------------------------------------"

    /// 一份文件头的 12 行（不含换行符）。
    static func headerLines(channelID: String, channelName: String, listener: String = listener,
                            started: String = "2026.11.20 11:33:40") -> [String] {
        [
            "\u{FEFF}", "", "", "",
            separator,
            "",
            "          Channel ID:      \(channelID)",
            "          Channel Name:    \(channelName)",
            "          Listener:        \(listener)",
            "          Session started: \(started)",
            separator,
            "",
        ]
    }

    /// 玩家频道的文件头。
    static var playerHeader: [String] { headerLines(channelID: playerChannelID, channelName: playerChannelName) }
    /// Local 频道的文件头。
    static var localHeader: [String] { headerLines(channelID: "local", channelName: "Local") }
    /// 军团频道的文件头。
    static var corpHeader: [String] { headerLines(channelID: "corp", channelName: "Corp") }

    /// 一行消息（不含换行符），以 U+FEFF 开头。
    static func messageLine(_ time: String = "2026.11.20 11:33:46", speaker: String = speaker,
                            text: String) -> String {
        "\u{FEFF}[ \(time) ] \(speaker) > \(text)"
    }

    /// 英文客户端的 Local 切换消息。
    static let localChangeEnglish = messageLine(speaker: "EVE System", text: "Channel changed to Local : Jita")
    /// 中文客户端的 Local 切换消息（参考实现记录的形式，V39）。
    static let localChangeChinese = messageLine(speaker: "EVE系统", text: "频道更换为本地：吉他*")
    /// 一条预警消息，条目之间隔两个空格（C14）。
    static let intelMessage = messageLine(text: "1DQ1-A  Tarn Vex  Sabre nv")

    /// 一份完整文件的文本：文件头各行以 LF 结尾，消息行以 CRLF 结尾。
    static func fileText(header: [String], messages: [String]) -> String {
        header.map { $0 + "\n" }.joined() + messages.map { $0 + "\r\n" }.joined()
    }

    /// 编码成带 BOM（FF FE）的 UTF-16 小端字节。文本开头的 U+FEFF 已是 BOM 时不再加。
    static func utf16LEWithBOM(_ text: String) -> Data {
        var data = Data()
        if text.first != "\u{FEFF}" { data.append(contentsOf: [0xFF, 0xFE]) }
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }
}
