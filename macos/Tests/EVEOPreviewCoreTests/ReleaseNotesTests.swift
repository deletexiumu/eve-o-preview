// SPDX-License-Identifier: GPL-3.0-or-later
//
// ReleaseNotes 的用例（v1.1 设计 8.2、8.7 节、14.1 节）：按界面语言取段落、去掉折叠标签、回退到英文与全文、
// CRLF、标记的写法，以及 `blocks` 表的每种行。另用仓库里真实的 docs/release-notes/macos/v1.0.0.md 核对一遍。

import Foundation
import Testing
import EVEOPreviewCore

/// 发布说明的选取与切块。
struct ReleaseNotesTests {
    /// 8.2 节格式的完整样例：英文在前，zh、ja、ko、ru、fr、de、es 各一个可折叠的块。
    static let sample = """
    <!-- lang:en -->
    ## What's new

    - English item.
    <!-- /lang:en -->

    <!-- lang:zh -->
    <details><summary>简体中文</summary>

    ## 新内容

    - 中文条目。

    </details>
    <!-- /lang:zh -->

    <!-- lang:ja -->
    <details><summary>日本語</summary>

    ## 新機能

    - 日本語の項目。

    </details>
    <!-- /lang:ja -->

    <!-- lang:ko -->
    <details><summary>한국어</summary>

    ## 새로운 기능

    - 한국어 항목.

    </details>
    <!-- /lang:ko -->

    <!-- lang:ru -->
    <details><summary>Русский</summary>

    ## Что нового

    - Русский пункт.

    </details>
    <!-- /lang:ru -->

    <!-- lang:fr -->
    <details><summary>Français</summary>

    ## Nouveautés

    - Élément en français.

    </details>
    <!-- /lang:fr -->

    <!-- lang:de -->
    <details><summary>Deutsch</summary>

    ## Neu

    - Deutscher Eintrag.

    </details>
    <!-- /lang:de -->

    <!-- lang:es -->
    <details><summary>Español</summary>

    ## Novedades

    - Elemento en español.

    </details>
    <!-- /lang:es -->
    """

    /// 各语言应取到的正文。
    static let expected: [AppLanguage: String] = [
        .en: "## What's new\n\n- English item.",
        .zh: "## 新内容\n\n- 中文条目。",
        .ja: "## 新機能\n\n- 日本語の項目。",
        .ko: "## 새로운 기능\n\n- 한국어 항목.",
        .ru: "## Что нового\n\n- Русский пункт.",
        .fr: "## Nouveautés\n\n- Élément en français.",
        .de: "## Neu\n\n- Deutscher Eintrag.",
        .es: "## Novedades\n\n- Elemento en español.",
    ]

    // MARK: - section(for:in:)

    /// 完整样例按每种界面语言取到各自的块。
    @Test(arguments: AppLanguage.allCases)
    func picksEachLanguage(language: AppLanguage) {
        #expect(ReleaseNotes.section(for: language, in: Self.sample) == Self.expected[language])
    }

    /// 非英文块去掉 `<details>`、`<summary>…</summary>` 与 `</details>`，标记本身也不留下。
    @Test(arguments: AppLanguage.allCases)
    func stripsFoldingTags(language: AppLanguage) {
        let text = ReleaseNotes.section(for: language, in: Self.sample)
        for leftover in ["<details", "</details>", "<summary", "</summary>", "lang:", "<!--"] {
            #expect(!text.contains(leftover))
        }
    }

    /// 缺界面语言的块时取英文的块。
    @Test func missingLanguageFallsBackToEnglish() {
        let body = Self.sample.replacingOccurrences(of: "<!-- lang:ko -->", with: "")
            .replacingOccurrences(of: "<!-- /lang:ko -->", with: "")
        #expect(ReleaseNotes.section(for: .ko, in: body) == Self.expected[.en])
        #expect(ReleaseNotes.section(for: .zh, in: body) == Self.expected[.zh])
    }

    /// 没有任何标记时（U13 所说的 1.0.0 的写法）返回全文，只去掉首尾空白行。
    @Test(arguments: AppLanguage.allCases)
    func noMarkersReturnsWholeBody(language: AppLanguage) {
        let body = "\n\nFirst release.\n\n## Install\n\n1. Download.\n\n"
        #expect(ReleaseNotes.section(for: language, in: body) == "First release.\n\n## Install\n\n1. Download.")
    }

    /// 只有非英文的块、界面语言又不是它时，两块都没有，返回全文。
    @Test func neitherLanguageNorEnglishReturnsWholeBody() {
        let body = "<!-- lang:zh -->\n中文\n<!-- /lang:zh -->"
        #expect(ReleaseNotes.section(for: .ja, in: body) == body)
        #expect(ReleaseNotes.section(for: .zh, in: body) == "中文")
    }

    /// CRLF 换成 LF 后再取，结果里没有回车。
    @Test(arguments: AppLanguage.allCases)
    func crlfBody(language: AppLanguage) {
        let crlf = Self.sample.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(crlf.contains("\r\n"))
        let text = ReleaseNotes.section(for: language, in: crlf)
        #expect(text == Self.expected[language])
        #expect(!text.contains("\r"))
    }

    /// 标记里多空格、少空格、大写都能认出；代码不区分大小写。
    @Test func lenientMarkers() {
        let body = """
        <!--LANG:EN-->
        English.
        <!--   /Lang:En   -->
        <!--  lang : ZH  -->
        <DETAILS><Summary>简体中文</SUMMARY>

        中文。

        </Details>
        <!--/lang:zh-->
        """
        #expect(ReleaseNotes.section(for: .en, in: body) == "English.")
        #expect(ReleaseNotes.section(for: .zh, in: body) == "中文。")
        #expect(ReleaseNotes.section(for: .ru, in: body) == "English.")
    }

    /// 只取开始标记之后的第一个结束标记；别的 HTML 注释不算标记。
    @Test func firstClosingMarkerAndOtherComments() {
        let body = "<!-- note -->\n<!-- lang:en -->\nA <!-- inline --> B\n<!-- /lang:en -->\nC\n<!-- /lang:en -->"
        #expect(ReleaseNotes.section(for: .en, in: body) == "A <!-- inline --> B")
    }

    /// 有开始标记、没有结束标记时这一块按不存在处理（设计未写明，本实现的做法）。
    @Test func unclosedBlockIsIgnored() {
        let body = "<!-- lang:en -->\nEnglish.\n<!-- /lang:en -->\n<!-- lang:ja -->\n日本語"
        #expect(ReleaseNotes.section(for: .ja, in: body) == "English.")
    }

    /// 块存在但内容为空时按不存在处理，改取英文（设计未写明，本实现的做法）。
    @Test func emptyBlockFallsBackToEnglish() {
        let body = "<!-- lang:en -->\nEnglish.\n<!-- /lang:en -->\n<!-- lang:ru -->\n<details><summary>Русский</summary>\n\n</details>\n<!-- /lang:ru -->"
        #expect(ReleaseNotes.section(for: .ru, in: body) == "English.")
    }

    /// 只有以 `<details>` 开头时才去掉折叠标签；正文中间的 `<details>` 原样保留。
    @Test func detailsOnlyStrippedAtStart() {
        let body = "<!-- lang:en -->\nSee <details> below.\n</details>\n<!-- /lang:en -->"
        #expect(ReleaseNotes.section(for: .en, in: body) == "See <details> below.\n</details>")
    }

    /// 去掉最后一个 `</details>`，前面嵌套的保留；没有 `</summary>` 时只去掉开头的标签。
    @Test func detailsEdgeCases() {
        let nested = "<!-- lang:zh -->\n<details open><summary>中文</summary>\n\n<details>x</details>\n\n</details>\n<!-- /lang:zh -->"
        #expect(ReleaseNotes.section(for: .zh, in: nested) == "<details>x</details>")
        let noSummary = "<!-- lang:zh -->\n<details>\n中文\n</details>\n<!-- /lang:zh -->"
        #expect(ReleaseNotes.section(for: .zh, in: noSummary) == "中文")
    }

    // MARK: - 仓库里的 v1.0.0 说明

    /// 读仓库里的 docs/release-notes/macos/v1.0.0.md。文件不在时用例失败，不跳过。
    static func repositoryNotes() throws -> String {
        // 本文件在 macos/Tests/EVEOPreviewCoreTests/ 下，往上 4 级是仓库根目录。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/release-notes/macos/v1.0.0.md")
        return try #require(try? String(contentsOf: url, encoding: .utf8), "找不到 \(url.path)")
    }

    /// 真实的 v1.0.0 说明（现在带标记）：每种语言取到自己的块，不留标签与标记，开头是该语言的正文。
    @Test(arguments: AppLanguage.allCases)
    func repositoryNotesPerLanguage(language: AppLanguage) throws {
        let notes = try Self.repositoryNotes()
        let text = ReleaseNotes.section(for: language, in: notes)
        for leftover in ["<details", "</details>", "<summary", "</summary>", "lang:", "<!--"] {
            #expect(!text.contains(leftover))
        }
        let openings: [AppLanguage: String] = [
            .en: "First release of EVE-O Preview for macOS", .zh: "EVE-O Preview for macOS 的首个正式版",
            .ja: "EVE-O Preview for macOS の最初のリリース", .ko: "EVE-O Preview for macOS의 첫 정식 릴리스",
            .ru: "Первый выпуск EVE-O Preview for macOS",
            // 1.0.0 的说明没有法、德、西文的块，这三种语言退回英文的块。
            .fr: "First release of EVE-O Preview for macOS", .de: "First release of EVE-O Preview for macOS",
            .es: "First release of EVE-O Preview for macOS",
        ]
        #expect(text.hasPrefix(try #require(openings[language])))
        #expect(!ReleaseNotes.blocks(from: text).isEmpty)
    }

    /// 去掉全部标记的 v1.0.0 说明（U13 所说的 1.0.0 正文的形式）：任何语言都返回全文。
    @Test(arguments: AppLanguage.allCases)
    func repositoryNotesWithoutMarkers(language: AppLanguage) throws {
        let notes = try Self.repositoryNotes()
        let stripped = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("<!-- lang:") && !$0.hasPrefix("<!-- /lang:") }
            .joined(separator: "\n")
        #expect(!stripped.contains("lang:"))
        let text = ReleaseNotes.section(for: language, in: stripped)
        #expect(text == stripped.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 英文块的切块结果：标题、无序列表与有序列表都认得出。
    @Test func repositoryNotesBlocks() throws {
        let blocks = ReleaseNotes.blocks(from: ReleaseNotes.section(for: .en, in: try Self.repositoryNotes()))
        #expect(blocks.contains(.heading(level: 2, text: "Highlights")))
        #expect(blocks.contains(.heading(level: 2, text: "Install")))
        #expect(blocks.contains { if case .bullet(depth: 0, _) = $0 { true } else { false } })
        #expect(blocks.contains { if case .numbered(number: 3, _) = $0 { true } else { false } })
    }

    // MARK: - blocks(from:)

    /// 表里的每种行。
    @Test func eachLineKind() {
        let markdown = """
        # Title
        ###### Six
        - dash
        * star
        + plus
          - nested
            - deeper
        1. one
        12. twelve
        ```
        let x = 1
        ```
        Plain line.
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .heading(level: 1, text: "Title"), .heading(level: 6, text: "Six"),
            .bullet(depth: 0, text: "dash"), .bullet(depth: 0, text: "star"), .bullet(depth: 0, text: "plus"),
            .bullet(depth: 1, text: "nested"), .bullet(depth: 2, text: "deeper"),
            .numbered(number: 1, text: "one"), .numbered(number: 12, text: "twelve"),
            .code("let x = 1"), .paragraph("Plain line."),
        ])
    }

    /// 相邻的行并入同一段落，用一个空格连接；空行结束段落；列表行也结束段落。
    @Test func paragraphMerging() {
        let markdown = "First line\n   second line  \n\nNew paragraph\n- item\nafter item"
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .paragraph("First line second line"), .paragraph("New paragraph"),
            .bullet(depth: 0, text: "item"), .paragraph("after item"),
        ])
    }

    /// 代码块里的 `#`、`-` 与空行都原样保留，不算标题、列表或段落的分隔。
    @Test func codeBlockKeepsContent() {
        let markdown = "```swift\n# not a heading\n- not a bullet\n\n  indented\n```\n# Real"
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .code("# not a heading\n- not a bullet\n\n  indented"), .heading(level: 1, text: "Real"),
        ])
    }

    /// 没有结束的代码块延续到末尾（设计未写明，本实现的做法）。
    @Test func unterminatedCodeBlock() {
        #expect(ReleaseNotes.blocks(from: "Intro\n```\na\nb") == [.paragraph("Intro"), .code("a\nb")])
    }

    /// 不算标题或列表的写法：`#` 后没有空格、7 个 `#`、`**粗体**` 开头、`-` 后没有空格、数字后没有 `.`。
    @Test func lookalikesArePlainParagraphs() {
        for line in ["#tag", "####### seven", "**bold** start", "-dash", "--- rule", "1) paren", "2024.", "v1.1.0 notes"] {
            #expect(ReleaseNotes.blocks(from: line) == [.paragraph(line)], "\(line)")
        }
    }

    /// CRLF 的正文切块结果与 LF 相同。
    @Test func blocksWithCRLF() {
        let lf = "## Head\n\n- a\n- b\n\ntext\nmore"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(ReleaseNotes.blocks(from: crlf) == ReleaseNotes.blocks(from: lf))
        #expect(ReleaseNotes.blocks(from: lf) == [
            .heading(level: 2, text: "Head"), .bullet(depth: 0, text: "a"), .bullet(depth: 0, text: "b"),
            .paragraph("text more"),
        ])
    }

    /// 空正文与只有空白的正文没有块。
    @Test func emptyInput() {
        #expect(ReleaseNotes.blocks(from: "").isEmpty)
        #expect(ReleaseNotes.blocks(from: "\n  \n\n").isEmpty)
        #expect(ReleaseNotes.section(for: .en, in: "") == "")
    }
}
