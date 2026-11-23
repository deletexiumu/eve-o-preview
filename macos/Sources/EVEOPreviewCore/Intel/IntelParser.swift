// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的分段、人数与人名（docs/macos/design-intel-translate.md 6.4 节）。
// - parse 的规则归 WP-B（本文件 parse 与 IntelParser+Counting.swift）。
// - remainder(of:) 由 WP-0 写完整，WP-B 不改它：翻译用它判断「只有术语」的消息（7.6 节）。
//
// parse 的步骤（6.4 节）：
// 1. 每个术语匹配成为一段；匹配之间的文字是「空隙」。
// 2. 空隙按空白切成词，记下每个词前面的空白。
// 3. 人数：去掉末尾的 , ， . ; : 后是 +3、x3、3、3x、3+、3人 等 13 种形式之一，数字 1～3 位、数值 1～500。
// 4. 紧跟在舰船或舰船分组之后、以 1～3 位数字开头且数字后直接是汉字的词：数字是人数，其余是普通文字。
// 5. 人名：消息里至少认出一个星系、舰船或舰船分组时，去掉两端标点后不含汉字假名谚文、不在 nonPilotWords 里、
//    至少含一个字母、含大写字母或数字的词是候选（`15:30` 这类没有字母的词不是）。
// 6. 相邻候选之间正好隔一个空格时并成一个人名，从左起每 3 个词一个人名，人名之间的一个空格单独成一段 plain。
// 7. 其余是 plain，相邻的 plain 并成一段。各段拼起来与原文逐字符相同。
// 数量的归属与敌对数量见 IntelParser+Counting.swift。

import Foundation

/// 预警消息的解析器。
public enum IntelParser {
    /// 一个人名至多几个词；人名的总词数超过它时，remainder 把人名也算进剩下的文字。
    public static let maxPilotWords = 3

    /// 用算好的术语匹配解析一条消息。matches 应按位置排序、互不重叠，范围是 text 的下标。
    public static func parse(_ text: String, matches: [TermMatch]) -> IntelReport {
        var pieces: [Piece] = []
        var cursor = text.startIndex
        for match in matches where match.range.lowerBound >= cursor && match.range.upperBound <= text.endIndex {
            appendGap(text[cursor..<match.range.lowerBound], to: &pieces)
            pieces.append(Piece(text: String(text[match.range]), role: .term(segmentKind(match.kind))))
            cursor = match.range.upperBound
        }
        appendGap(text[cursor...], to: &pieces)
        attachLeadingDigits(&pieces)
        let hasTerms = pieces.contains { piece in
            if case .term(let kind) = piece.role { return kind.isSystemOrShip }
            return false
        }
        let segments = buildSegments(pieces, infersPilots: hasTerms)
        return summarize(segments, countForms: pieces.compactMap(\.countForm))
    }

    /// 用星图数据的匹配器解析一条消息。
    public static func parse(_ text: String, data: EVEStaticData) -> IntelReport {
        parse(text, matches: data.matcher.matches(in: text))
    }

    /// 去掉认出的术语、人数与推断的人名后，剩下的文字（给「不用模型」的判断用）。
    ///
    /// 做法：按顺序取全部 plain 段，各段去掉首尾空白，空段丢掉，其余用一个空格连起来。
    /// 人名的总词数（各 pilot 段按空白切词后相加）超过 `maxPilotWords` 时，pilot 段也按原来的位置算进去：
    /// 这时消息多半是一句话，应交给模型翻译。只看 segments，不看 `pilots` 数组，手工构造的结果不会两处不一致。
    public static func remainder(of report: IntelReport) -> String {
        let pilotWords = report.segments.reduce(0) { total, segment in
            guard segment.kind == .pilot else { return total }
            return total + segment.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        let includesPilots = pilotWords > maxPilotWords
        var parts: [String] = []
        for segment in report.segments {
            switch segment.kind {
            case .plain:
                break
            case .pilot where includesPilots:
                break
            default:
                continue
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - 分段

    /// 解析过程中的一小段。
    struct Piece {
        /// 原文。
        var text: String
        /// 用途。
        var role: Role
        /// 人数的写法（只对 count 有值）：能否把数量归给后面的舰船（6.4 节数量第 2 条）。
        var countForm: CountForm? {
            if case .count(_, let form) = role { return form }
            return nil
        }
    }

    /// 一小段的用途。
    enum Role {
        /// 术语。
        case term(IntelSegmentKind)
        /// 空白。
        case space
        /// 人数与它的写法。
        case count(Int, CountForm)
        /// 人名的候选词（已去掉两端标点）。
        case candidate
        /// 普通文字。
        case plain
    }

    /// 人数的写法。
    enum CountForm {
        /// `3`、`3x`、`3×`：可以归给后面的舰船。
        case leading
        /// 其他写法：只能归给前面的舰船，或作独立人数。
        case other
    }

    /// 术语种类到段种类的对应。
    static func segmentKind(_ kind: TermKind) -> IntelSegmentKind {
        switch kind {
        case .system(let id): .system(id: id)
        case .region(let id): .region(id: id)
        case .ship(let typeID): .ship(typeID: typeID)
        case .shipGroup(let groupID): .shipGroup(groupID: groupID)
        case .intelWord(let word): .word(word)
        }
    }

    /// 把一段空隙按空白切成词，每个词再分出人数、人名候选与两端的标点。
    private static func appendGap(_ gap: Substring, to pieces: inout [Piece]) {
        var index = gap.startIndex
        while index < gap.endIndex {
            let isSpace = gap[index].isWhitespace
            var end = gap.index(after: index)
            while end < gap.endIndex, gap[end].isWhitespace == isSpace { end = gap.index(after: end) }
            let chunk = String(gap[index..<end])
            if isSpace {
                pieces.append(Piece(text: chunk, role: .space))
            } else {
                appendToken(chunk, to: &pieces)
            }
            index = end
        }
    }

    /// 一个不含空白的词：先认人数，再认人名候选（两端的标点单独成为普通文字），其余是普通文字。
    private static func appendToken(_ token: String, to pieces: inout [Piece]) {
        var core = token
        var trailing = ""
        while let last = core.last, ",，.;:".contains(last) {
            trailing.insert(last, at: trailing.startIndex)
            core.removeLast()
        }
        if let (value, form) = countValue(core) {
            pieces.append(Piece(text: core, role: .count(value, form)))
            if !trailing.isEmpty { pieces.append(Piece(text: trailing, role: .plain)) }
            return
        }
        // 人名候选：去掉两端不是字母或数字的字符。候选的条件在 buildSegments 里判断（要看整条消息有没有术语）。
        let characters = Array(token)
        guard let first = characters.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = characters.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
            pieces.append(Piece(text: token, role: .plain))
            return
        }
        let name = String(characters[first...last])
        guard isPilotCandidate(name) else {
            pieces.append(Piece(text: token, role: .plain))
            return
        }
        if first > 0 { pieces.append(Piece(text: String(characters[..<first]), role: .plain)) }
        pieces.append(Piece(text: name, role: .candidate))
        if last + 1 < characters.count {
            pieces.append(Piece(text: String(characters[(last + 1)...]), role: .plain))
        }
    }

    /// 人数的 13 种写法：`+3`、`＋3`、`x3`、`×3`、`3`、`3x`、`3×`、`3+`、`3人`、`3个`、`3只`、`3艘`、`3名`。
    /// 数字 1～3 位，数值 1～500；不符合时返回 nil。`x` 不区分大小写。
    static func countValue(_ core: String) -> (Int, CountForm)? {
        var body = Substring(core)
        var form = CountForm.other
        if let first = body.first, "+＋xX×".contains(first) {
            body = body.dropFirst()
        } else if let last = body.last, "xX×".contains(last) {
            body = body.dropLast()
            form = .leading
        } else if let last = body.last, "+人个只艘名".contains(last) {
            body = body.dropLast()
        } else {
            form = .leading
        }
        guard (1...3).contains(body.count), body.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(body), (1...500).contains(value) else { return nil }
        return (value, form)
    }

    /// 6.4 节第 5 条：不为空；不含汉字、假名、谚文；小写不在 nonPilotWords 里；至少含一个字母；含大写字母或数字。
    /// 「至少含一个字母」也排除了全是数字的词。
    static func isPilotCandidate(_ word: String) -> Bool {
        guard !word.isEmpty, !word.contains(where: IntelLexicon.isCJK),
              !IntelLexicon.nonPilotWords.contains(word.lowercased()),
              word.contains(where: { $0.isLetter }) else { return false }
        return word.contains { $0.isUppercase || $0.isNumber }
    }

    /// 6.4 节第 4 条：紧跟在舰船或舰船分组之后（中间只有空白）的普通词，以 1～3 位数字开头、数字后直接是汉字时，
    /// 数字成为人数，其余是普通文字。例：`剑齿虎级 1门口有泡泡` 里的 `1`。
    private static func attachLeadingDigits(_ pieces: inout [Piece]) {
        var index = 0
        var afterShip = false
        while index < pieces.count {
            let piece = pieces[index]
            switch piece.role {
            case .term(let kind):
                afterShip = kind.isShip
            case .space:
                break
            case .plain where afterShip:
                afterShip = false
                let digits = piece.text.prefix(while: { $0.isASCII && $0.isNumber })
                let rest = piece.text.dropFirst(digits.count)
                if (1...3).contains(digits.count), let next = rest.first, IntelLexicon.isCJK(next),
                   let value = Int(digits), (1...500).contains(value) {
                    pieces[index] = Piece(text: String(digits), role: .count(value, .other))
                    pieces.insert(Piece(text: String(rest), role: .plain), at: index + 1)
                    index += 1
                }
            default:
                afterShip = false
            }
            index += 1
        }
    }

    /// 按第 5～7 条组段：没有术语时候选词都是普通文字；相邻候选只隔一个空格时并成一串，每 3 个词一个人名；
    /// 其余并成 plain。
    private static func buildSegments(_ pieces: [Piece], infersPilots: Bool) -> [IntelSegment] {
        var segments: [IntelSegment] = []
        func appendPlain(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.kind == .plain {
                segments[segments.count - 1].text += text
            } else {
                segments.append(IntelSegment(text: text, kind: .plain))
            }
        }
        var index = 0
        while index < pieces.count {
            let piece = pieces[index]
            switch piece.role {
            case .term(let kind):
                segments.append(IntelSegment(text: piece.text, kind: kind))
            case .count(let value, _):
                segments.append(IntelSegment(text: piece.text, kind: .count(value)))
            case .space, .plain:
                appendPlain(piece.text)
            case .candidate where !infersPilots:
                appendPlain(piece.text)
            case .candidate:
                // 收一串：候选、正好一个空格、候选……
                var words = [piece.text]
                var next = index + 1
                while next + 1 < pieces.count, pieces[next].text == " ", case .space = pieces[next].role,
                      case .candidate = pieces[next + 1].role {
                    words.append(pieces[next + 1].text)
                    next += 2
                }
                for (chunkIndex, start) in stride(from: 0, to: words.count, by: maxPilotWords).enumerated() {
                    if chunkIndex > 0 { appendPlain(" ") }
                    let chunk = words[start..<min(start + maxPilotWords, words.count)]
                    segments.append(IntelSegment(text: chunk.joined(separator: " "), kind: .pilot))
                }
                index = next
                continue
            }
            index += 1
        }
        return segments
    }
}

extension IntelSegmentKind {
    /// 是舰船或舰船分组。
    var isShip: Bool {
        switch self {
        case .ship, .shipGroup: true
        default: false
        }
    }

    /// 是星系、舰船或舰船分组（推断人名的前提）。
    var isSystemOrShip: Bool {
        if case .system = self { return true }
        return isShip
    }
}
