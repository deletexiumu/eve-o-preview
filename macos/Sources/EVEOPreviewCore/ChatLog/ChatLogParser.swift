// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的文件头与消息行的解析（docs/macos/design-intel-translate.md 5.2 节）。
// - 文件是带 BOM 的 UTF-16 小端（C2），由调用方用 LogLineFramer 切成行后交给这里。
// - 文件头固定 12 行：两条全是 `-` 的分隔线之间是 Channel ID、Channel Name、Listener、Session started 4 个字段。
//   标签在 8 种语言的客户端里都是英文（C4）；标签不认识而正好 4 行时按位置取。
// - 消息行是 U+FEFF 加「[ yyyy.MM.dd HH:mm:ss ] 说话人 > 正文」（C6），时间是 UTC。
// - 正文里本机没见过标记与实体（C6），plainText 只作防御。连续的空格保留：它是条目之间的分隔（C14）。
// 解析不用正则表达式，只做前缀与子串比较。

import Foundation

/// 聊天日志的解析器。
public enum ChatLogParser {
    /// 至多看文件开头的这么多行。读满仍没有第二条分隔线时，视为字段都没有的完整文件头。
    public static let maxHeaderLines = 16

    /// EVE 系统消息的说话人（5.2 节的表）：英文客户端与中文客户端各一个，其余语言待补（V32）。
    public static let systemSpeakers: [String] = ["EVE System", "EVE系统"]

    /// 时间部分的字符数：`yyyy.MM.dd HH:mm:ss`。
    static let timestampLength = 19

    // MARK: - 文件头

    /// 解析文件开头的各行（不含换行符）。规则：
    /// 1. 每行先去掉 U+FEFF 与首尾空白。至多看 `maxHeaderLines` 行。
    /// 2. 第一条全是 `-` 的行是文件头的开始，第二条是结束；读到第二条时 `isComplete` 为真。
    /// 3. 两条分隔线之间的非空行按第一个半角或全角冒号分成标签与值，标签不区分大小写：
    ///    `Channel ID`、`Channel Name`、`Listener` 分别填进 3 个字段。值为空时字段为 nil。
    /// 4. 标签一个都不认识、而非空行正好 4 行时，按顺序取第 1、2、3 行的值（应对标签被翻译的客户端）。
    /// 5. 读满 `maxHeaderLines` 行还没有第二条分隔线时，`isComplete` 为真，各字段为 nil；行数不够时为假。
    public static func parseHeader(_ lines: [String]) -> ChatLogHeader {
        var inside: [String]?
        for raw in lines.prefix(maxHeaderLines) {
            let line = raw.trimmingCharacters(in: CombatLogHeaderParser.whitespace)
            if CombatLogHeaderParser.isSeparator(line) {
                if let between = inside {
                    return header(from: between)
                }
                inside = []
                continue
            }
            if !line.isEmpty { inside?.append(line) }
        }
        // 没读到第二条分隔线：行数已满说明文件头不是预期的形式，否则是文件还没写完。
        return ChatLogHeader(channelID: nil, channelName: nil, listener: nil,
                             isComplete: lines.count >= maxHeaderLines)
    }

    /// 从两条分隔线之间的非空行取 3 个字段。
    private static func header(from lines: [String]) -> ChatLogHeader {
        var id: String?
        var name: String?
        var listener: String?
        var recognized = false
        for line in lines {
            guard let (label, value) = splitField(line) else { continue }
            switch label.lowercased() {
            case "channel id": id = value; recognized = true
            case "channel name": name = value; recognized = true
            case "listener": listener = value; recognized = true
            default: break
            }
        }
        if !recognized, lines.count == 4 {
            // 标签被翻译的客户端：按位置取第 1、2、3 行的值。
            id = splitField(lines[0])?.value
            name = splitField(lines[1])?.value
            listener = splitField(lines[2])?.value
        }
        return ChatLogHeader(channelID: id, channelName: name, listener: listener, isComplete: true)
    }

    /// 按第一个半角或全角冒号把一行分成标签与值，两边去掉首尾空白；值为空时为 nil。没有冒号时返回 nil。
    private static func splitField(_ line: String) -> (label: String, value: String?)? {
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: CombatLogHeaderParser.whitespace)
        return (label, value.isEmpty ? nil : value)
    }

    // MARK: - 消息行

    /// 解析一行消息。不是「[ 时间 ] 说话人 > 正文」形式的行返回 nil。规则：
    /// 1. 去掉行首的 U+FEFF（可能有多个）与行尾的回车、换行。
    /// 2. 行以 `[ ` 开头，时间是 19 个字符的 `yyyy.MM.dd HH:mm:ss`，后面是 ` ] `。时间按 UTC 换算；换算不了时返回 nil。
    /// 3. 剩下的部分按第一个 ` > ` 分成说话人与正文；没有 ` > ` 时返回 nil。说话人去掉首尾空白，为空时返回 nil。
    /// 4. 正文经 `plainText` 清理；`isSystem` 是「说话人在 `systemSpeakers` 里」。
    public static func parseLine(_ line: String) -> ChatLine? {
        var text = Substring(line)
        while text.first == "\u{FEFF}" { text = text.dropFirst() }
        while let last = text.last, last == "\r" || last == "\n" || last == "\r\n" { text = text.dropLast() }
        let bytes = Array(text.utf8)
        let prefixLength = 2 + timestampLength + 3      // "[ " + 时间 + " ] "
        guard bytes.count >= prefixLength,
              bytes[0] == UInt8(ascii: "["), bytes[1] == UInt8(ascii: " "),
              bytes[(2 + timestampLength)..<prefixLength].elementsEqual(" ] ".utf8) else { return nil }
        guard let time = utcSeconds(Array(bytes[2..<(2 + timestampLength)])) else { return nil }
        let rest = String(decoding: bytes[prefixLength...], as: UTF8.self)
        guard let arrow = rest.range(of: " > ") else { return nil }
        let speaker = rest[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return nil }
        let body = plainText(String(rest[arrow.upperBound...]))
        return ChatLine(time: time, speaker: speaker, text: body, isSystem: systemSpeakers.contains(speaker))
    }

    /// 19 字节的 `yyyy.MM.dd HH:mm:ss` 换算成 UTC 秒数；形式或数值不合法时返回 nil。
    static func utcSeconds(_ t: [UInt8]) -> Double? {
        guard CombatLogParser.isTimestamp(t) else { return nil }
        // 各字段在时间串里的位置，形式已核对过，这里只取数值。
        func number(_ start: Int, _ length: Int) -> Int {
            t[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        let (year, month, day) = (number(0, 4), number(5, 2), number(8, 2))
        let (hour, minute, second) = (number(11, 2), number(14, 2), number(17, 2))
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        let days = CombatLogParser.daysFromCivil(year: year, month: month, day: day)
        return Double(days * 86_400 + hour * 3_600 + minute * 60 + second)
    }

    // MARK: - 频道种类

    /// 按 Channel ID 判断频道种类，比较不区分大小写：`local`、`corp`、`alliance` 各对应同名的种类；
    /// 以 `fleet_` 开头是 fleet；以 `player_` 开头是 player；以 `private_` 开头是 privateChat；其余与 nil 是 other。
    public static func channelKind(id: String?) -> ChatChannelKind {
        guard let id = id?.trimmingCharacters(in: .whitespaces).lowercased() else { return .other }
        switch id {
        case "local": return .local
        case "corp": return .corp
        case "alliance": return .alliance
        default:
            if id.hasPrefix("fleet_") { return .fleet }
            if id.hasPrefix("player_") { return .player }
            if id.hasPrefix("private_") { return .privateChat }
            return .other
        }
    }

    // MARK: - 正文清理

    /// 清理正文：把 `<br>`（含 `<br/>`、`<br />`，不区分大小写）换成换行；删掉其余每一对 `<` 与 `>` 之间的内容，
    /// 找不到 `>` 的 `<` 保留；解码 `&lt;`、`&gt;`、`&amp;`、`&quot;`、`&#39;`（一次扫描，不重复解码）；
    /// 行内连续的空格与制表符保留原样；最后去掉首尾空白。
    public static func plainText(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        // 一旦某个 `<` 之后再也没有 `>`，后面的 `<` 也不会有，记下来免得重复查找。
        var noMoreClose = false
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "<", !noMoreClose {
                if let close = scalars[(i + 1)...].firstIndex(of: ">") {
                    if isLineBreakTag(scalars[(i + 1)..<close]) { out.append("\n") }
                    i = close + 1
                    continue
                }
                noMoreClose = true
            }
            if c == "&", let (decoded, length) = entity(in: scalars, at: i) {
                out.append(decoded)
                i += length
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标记的内容（`<` 与 `>` 之间）是不是换行标记 `br`、`br/`、`br /`。
    private static func isLineBreakTag(_ content: ArraySlice<Unicode.Scalar>) -> Bool {
        var name = String(String.UnicodeScalarView(content)).trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix("/") { name.removeLast() }
        return name.trimmingCharacters(in: .whitespaces) == "br"
    }

    /// 支持的 5 种实体与解码后的字符。
    private static let entities: [(name: [Unicode.Scalar], value: Unicode.Scalar)] = [
        (Array("&lt;".unicodeScalars), "<"), (Array("&gt;".unicodeScalars), ">"),
        (Array("&amp;".unicodeScalars), "&"), (Array("&quot;".unicodeScalars), "\""),
        (Array("&#39;".unicodeScalars), "'"),
    ]

    /// 从 index 处的 `&` 起认一个实体，返回解码后的字符与实体的长度；不认识时返回 nil。
    private static func entity(in scalars: [Unicode.Scalar], at index: Int) -> (Unicode.Scalar, Int)? {
        for (name, value) in entities where index + name.count <= scalars.count {
            if scalars[index..<(index + name.count)].elementsEqual(name) { return (value, name.count) }
        }
        return nil
    }
}
