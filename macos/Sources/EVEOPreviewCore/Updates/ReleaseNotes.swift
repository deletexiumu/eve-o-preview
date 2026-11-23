// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布说明的选取与切块（v1.1 设计 8.2、8.7 节；格式见架构文档 9.7 节）。
//
// Release 正文是 `docs/release-notes/macos/<tag>.md` 的原文：英文在最前，包在 `<!-- lang:en -->` 与 `<!-- /lang:en -->`
// 之间；之后 zh、ja、ko、ru、fr、de、es 各一个可折叠的块，块里是 `<details><summary>…</summary>`、Markdown 正文与 `</details>`。
// `section(for:in:)` 按界面语言取出一段，`blocks(from:)` 把它切成标题、列表、段落与代码块，由界面逐块显示
// （SwiftUI 的 `Text` 只渲染行内 Markdown，不渲染标题与列表）。
//
// 设计没有写明、这里定下的做法（各有用例）：
// - 有开始标记、没有对应的结束标记时，这一块按不存在处理。
// - 块存在但去掉 `<details>` 与空白行后什么都不剩时，也按不存在处理，改取英文或全文。
// - 编号行与列表行一样允许前面有空格；标题行要从行首开始，`#` 后面要有空格，7 个 `#` 不算标题。
// - 没有结束的代码块一直延续到正文末尾。

import Foundation

/// 发布说明里的一块，由 `ReleaseNotes.blocks(from:)` 切出。
public enum ReleaseNotesBlock: Sendable, Equatable {
    /// 标题，level 是 `#` 的个数（1～6）。
    case heading(level: Int, text: String)
    /// 段落；原文里相邻的几行用一个空格连起来。
    case paragraph(String)
    /// 无序列表的一项；depth 是缩进的级数，每 2 个空格算一级，从 0 起。
    case bullet(depth: Int, text: String)
    /// 有序列表的一项；number 是原文写的序号。
    case numbered(number: Int, text: String)
    /// 三个反引号围起来的代码，各行原样保留，用换行连接。
    case code(String)
}

/// 发布说明的选取与切块。
public enum ReleaseNotes {
    /// 按 8.2 节的约定取出一种语言的正文。
    ///
    /// 1. CRLF 换成 LF。
    /// 2. 找 `<!-- lang:<代码> -->` 与它之后第一个 `<!-- /lang:<代码> -->` 之间的文字；标记里的空白可有可无，
    ///    代码不区分大小写。
    /// 3. 界面语言的块存在时取它，否则取 `en` 的块；两块都没有时取整个正文（1.0.0 的说明属于这种情况）。
    /// 4. 取出的文字以 `<details>` 开头时，去掉从 `<details>` 到第一个 `</summary>` 的部分，以及最后一个 `</details>`。
    /// 5. 去掉首尾的空白行。
    public static func section(for language: AppLanguage, in body: String) -> String {
        let text = normalizedNewlines(body)
        let markers = ReleaseNotesMarker.scan(text)
        // 界面语言在前；界面语言就是英文时只试一次。
        var candidates = [language.rawValue]
        if language != .en { candidates.append(AppLanguage.en.rawValue) }
        for code in candidates {
            guard let raw = block(code: code, markers: markers, in: text) else { continue }
            let cleaned = trimBlankLines(stripDetails(raw))
            if !cleaned.isEmpty { return cleaned }
        }
        return trimBlankLines(stripDetails(text))
    }

    /// 把取出的那段文字按行切成块（8.7 节的表）。
    ///
    /// | 行的形式 | 块 |
    /// | --- | --- |
    /// | 以 1～6 个 `#` 加空格开头 | `heading` |
    /// | 以 `-`、`*` 或 `+` 加空格开头，前面有 0 个或多个空格 | `bullet`，每 2 个空格算一级 |
    /// | 以数字加 `.` 加空格开头（前面可以有空格） | `numbered` |
    /// | 三个反引号围起来的各行 | `code` |
    /// | 空行 | 结束当前段落 |
    /// | 其他 | 并入当前 `paragraph`，行与行之间加一个空格 |
    public static func blocks(from markdown: String) -> [ReleaseNotesBlock] {
        var builder = ReleaseNotesBlockBuilder()
        // 按 LF 切行；先把 CRLF 换掉，否则 "\r\n" 是一个字符，切不开。
        for line in normalizedNewlines(markdown).split(separator: "\n", omittingEmptySubsequences: false) {
            builder.consume(String(line))
        }
        return builder.finish()
    }

    // MARK: - 选取的步骤

    /// CRLF 与单独的 CR 都换成 LF。
    static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// 取 code 的第一个开始标记与它之后第一个同代码的结束标记之间的文字；任何一个找不到时返回 nil。
    private static func block(code: String, markers: [ReleaseNotesMarker], in text: String) -> String? {
        guard let open = markers.first(where: { !$0.isClosing && $0.code == code }),
              let close = markers.first(where: {
                  $0.isClosing && $0.code == code && $0.range.lowerBound >= open.range.upperBound
              }) else { return nil }
        return String(text[open.range.upperBound..<close.range.lowerBound])
    }

    /// 文字以 `<details>` 开头（前面允许有空白）时，去掉从它到第一个 `</summary>` 的部分，以及最后一个 `</details>`。
    /// 没有 `</summary>` 时只去掉 `<details>` 这个标签本身。标签不区分大小写，`<details open>` 也算。
    static func stripDetails(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }),
              let openTag = text.range(of: "<details", options: [.caseInsensitive, .anchored], range: start..<text.endIndex),
              openTag.upperBound < text.endIndex,
              text[openTag.upperBound] == ">" || text[openTag.upperBound].isWhitespace,
              let openEnd = text.range(of: ">", range: openTag.upperBound..<text.endIndex) else { return text }
        let summaryEnd = text.range(of: "</summary>", options: .caseInsensitive, range: openEnd.upperBound..<text.endIndex)
        var result = String(text[(summaryEnd?.upperBound ?? openEnd.upperBound)...])
        if let close = result.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
            result.removeSubrange(close)
        }
        return result
    }

    /// 去掉开头和末尾只含空白的行；中间的行原样保留。
    static func trimBlankLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let isBlank: (Substring) -> Bool = { $0.allSatisfy(\.isWhitespace) }
        guard let first = lines.firstIndex(where: { !isBlank($0) }),
              let last = lines.lastIndex(where: { !isBlank($0) }) else { return "" }
        return lines[first...last].joined(separator: "\n")
    }
}

// MARK: - 语言标记

/// 正文里的一个语言标记：`<!-- lang:xx -->` 或 `<!-- /lang:xx -->`。
struct ReleaseNotesMarker {
    /// 标记在正文里的范围，从 `<!--` 到 `-->`。
    let range: Range<String.Index>
    /// 语言代码，已转成小写。
    let code: String
    /// 是否是结束标记（`/lang:`）。
    let isClosing: Bool

    /// 按出现的先后列出正文里全部的语言标记。
    ///
    /// 宽松的写法：`<!--` 之后、`-->` 之前，以及 `/`、`lang`、`:` 两侧的空白都可有可无；`lang` 与代码不区分大小写。
    /// 别的 HTML 注释不算标记。在原文上逐字比较，不在转成小写的副本上找，下标才对得上原文。
    static func scan(_ text: String) -> [ReleaseNotesMarker] {
        var result: [ReleaseNotesMarker] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "<!--", range: searchStart..<text.endIndex) {
            if let marker = parse(text, from: open) {
                result.append(marker)
                searchStart = marker.range.upperBound
            } else {
                searchStart = open.upperBound
            }
        }
        return result
    }

    /// 从一个 `<!--` 起解析标记；不是语言标记时返回 nil。
    private static func parse(_ text: String, from open: Range<String.Index>) -> ReleaseNotesMarker? {
        var index = skipWhitespace(text, from: open.upperBound)
        let isClosing = index < text.endIndex && text[index] == "/"
        if isClosing { index = skipWhitespace(text, from: text.index(after: index)) }
        guard let keyword = text.range(of: "lang", options: [.caseInsensitive, .anchored], range: index..<text.endIndex)
        else { return nil }
        index = skipWhitespace(text, from: keyword.upperBound)
        guard index < text.endIndex, text[index] == ":" else { return nil }
        index = skipWhitespace(text, from: text.index(after: index))
        // 代码由 ASCII 字母与数字组成，中间可以有 `-`（如 `zh-hans`）。`-` 后面不是字母或数字时停下，
        // 否则 `<!--lang:en-->` 里的 `-->` 会被当成代码的一部分。
        let isCodeCharacter: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let codeStart = index
        while index < text.endIndex {
            let next = text.index(after: index)
            if isCodeCharacter(text[index]) || (text[index] == "-" && next < text.endIndex && isCodeCharacter(text[next])) {
                index = next
            } else {
                break
            }
        }
        guard index > codeStart else { return nil }
        let code = text[codeStart..<index].lowercased()
        index = skipWhitespace(text, from: index)
        guard let close = text.range(of: "-->", options: .anchored, range: index..<text.endIndex) else { return nil }
        return ReleaseNotesMarker(range: open.lowerBound..<close.upperBound, code: code, isClosing: isClosing)
    }

    /// 跳过空白（含换行），返回第一个非空白字符的位置。
    private static func skipWhitespace(_ text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        return index
    }
}

// MARK: - 切块

/// `ReleaseNotes.blocks(from:)` 的逐行状态：当前段落的行、是否在代码块里。
struct ReleaseNotesBlockBuilder {
    /// 已切出的块。
    private var blocks: [ReleaseNotesBlock] = []
    /// 当前段落已收的行（已去掉首尾空白）。
    private var paragraph: [String] = []
    /// 在代码块里时是已收的行；不在代码块里时是 nil。
    private var code: [String]?

    /// 处理一行（不含换行符）。
    mutating func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if code != nil {
            // 代码块里的行原样保留，`#` 与 `-` 都不解释；遇到下一个三个反引号时结束。
            if trimmed.hasPrefix("```") {
                blocks.append(.code(code!.joined(separator: "\n")))
                code = nil
            } else {
                code!.append(line)
            }
            return
        }
        if trimmed.hasPrefix("```") {
            flushParagraph()
            code = []
        } else if trimmed.isEmpty {
            flushParagraph()
        } else if let block = Self.listOrHeading(line) {
            flushParagraph()
            blocks.append(block)
        } else {
            paragraph.append(trimmed)
        }
    }

    /// 收尾：结束当前段落；没有结束的代码块延续到正文末尾。
    mutating func finish() -> [ReleaseNotesBlock] {
        flushParagraph()
        if let lines = code {
            blocks.append(.code(lines.joined(separator: "\n")))
            code = nil
        }
        return blocks
    }

    /// 把当前段落的行用一个空格连起来，作为一个段落块。
    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: " ")))
        paragraph.removeAll()
    }

    /// 标题、无序列表或有序列表的一行；都不是时返回 nil。
    static func listOrHeading(_ line: String) -> ReleaseNotesBlock? {
        let chars = Array(line)
        // 标题：从行首起 1～6 个 `#`，后面紧跟空格。
        let hashes = chars.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), hashes < chars.count, chars[hashes] == " " {
            return .heading(level: hashes, text: String(chars[(hashes + 1)...]).trimmingCharacters(in: .whitespaces))
        }
        let indent = chars.prefix(while: { $0 == " " }).count
        // 无序列表：缩进之后是 `-`、`*` 或 `+`，后面紧跟空格。`**粗体**` 开头的行不算。
        if indent + 1 < chars.count, "-*+".contains(chars[indent]), chars[indent + 1] == " " {
            return .bullet(depth: indent / 2, text: String(chars[(indent + 2)...]).trimmingCharacters(in: .whitespaces))
        }
        // 有序列表：缩进之后是数字、`.` 与空格。数字超出 Int 时按普通段落处理。
        let digits = chars[indent...].prefix(while: { $0.isASCII && $0.isNumber }).count
        let dot = indent + digits
        if digits > 0, dot + 1 < chars.count, chars[dot] == ".", chars[dot + 1] == " ",
           let number = Int(String(chars[indent..<dot])) {
            return .numbered(number: number, text: String(chars[(dot + 2)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
