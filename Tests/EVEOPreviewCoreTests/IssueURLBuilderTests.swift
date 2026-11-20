// SPDX-License-Identifier: GPL-3.0-or-later
//
// Issue 地址的用例（v1.1 设计 7.5 节、14.1 节）：主机与路径；标题与正文能从查询串还原；特殊字符的编码；
// 120 个字符的标题上限；超长时先丢可选小节、再删环境行、最后截断；不超过 6,000 字节；刚好等于上限；非 ASCII。

import Foundation
import Testing
import EVEOPreviewCore

/// Issue 地址。
struct IssueURLBuilderTests {
    /// 从地址里取出查询参数（已解码）。
    static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// 地址的字节数。
    static func bytes(_ url: URL) -> Int { url.absoluteString.utf8.count }

    /// 一份 4 个小节的草稿。环境一节有 envLines 行。
    static func draft(title: String = "Problem report: EVE-O Preview 1.1.0 on macOS 27.0", envLines: Int = 8,
                      optionalBody: String = "- Version: 1.0.0\n- Crash reports: 2",
                      lastBody: String = "Attach `EVE-O-Preview-diagnostics-20261121-040506.zip` (Finder shows it).")
        -> IssueDraft {
        IssueDraft(title: title, sections: [
            IssueSection(heading: "What happened", body: "<!-- describe -->", isRequired: true),
            IssueSection(heading: "Environment",
                         body: (1...max(1, envLines)).map { "- Line \($0): value" }.joined(separator: "\n"),
                         isRequired: true),
            IssueSection(heading: "Previous run", body: optionalBody, isRequired: false),
            IssueSection(heading: "Diagnostics", body: lastBody, isRequired: true),
        ])
    }

    /// 主机、路径与参数名；不带 template 与 labels。
    @Test func hostAndPath() throws {
        let url = IssueURLBuilder.url(for: Self.draft())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path == "/deletexiumu/eve-o-preview-macos/issues/new")
        #expect(Set(components.queryItems?.map(\.name) ?? []) == ["title", "body"])
    }

    /// 标题与正文能从查询串原样还原；正文的格式是 `### 标题`、空行、内容、空行。
    @Test func roundTrip() {
        let draft = Self.draft()
        let query = Self.query(IssueURLBuilder.url(for: draft))
        #expect(query["title"] == draft.title)
        #expect(query["body"] == IssueURLBuilder.body(for: draft))
        #expect(IssueURLBuilder.body(for: draft).hasPrefix("### What happened\n\n<!-- describe -->\n\n### Environment\n\n"))
    }

    /// `+`、`&`、`#`、换行被编码，还原后不变；查询串里没有裸的 `+`。
    @Test func specialCharacters() throws {
        let draft = IssueDraft(title: "a+b & c#d", sections: [
            IssueSection(heading: "What happened", body: "x+y=z & w#1\nnext line", isRequired: true),
        ])
        let url = IssueURLBuilder.url(for: draft)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(!query.contains("+"))
        #expect(query.contains("%2B"))
        #expect(query.contains("%26"))
        #expect(query.contains("%23"))
        #expect(query.contains("%0A"))
        #expect(!url.absoluteString.contains("#"))
        let decoded = Self.query(url)
        #expect(decoded["title"] == "a+b & c#d")
        #expect(decoded["body"]?.contains("x+y=z & w#1\nnext line") == true)
    }

    /// 标题超过 120 个字符时截短到 120 个字符，末尾是 `…`；不超过时不变。
    @Test func titleLimit() {
        let long = String(repeating: "t", count: 200)
        let title = Self.query(IssueURLBuilder.url(for: Self.draft(title: long)))["title"] ?? ""
        #expect(title.count == IssueURLBuilder.maxTitleCharacters)
        #expect(title.hasSuffix("…"))
        let exact = String(repeating: "e", count: 120)
        #expect(Self.query(IssueURLBuilder.url(for: Self.draft(title: exact)))["title"] == exact)
    }

    /// 超长时第 1 步：先丢可选小节，必留的都在。
    @Test func dropsOptionalSectionFirst() {
        let draft = Self.draft(optionalBody: String(repeating: "o", count: 3000))
        let full = Self.bytes(IssueURLBuilder.url(for: draft, limit: 100_000))
        let withoutOptional = IssueDraft(title: draft.title, sections: draft.sections.filter(\.isRequired))
        let limit = Self.bytes(IssueURLBuilder.url(for: withoutOptional, limit: 100_000))
        #expect(full > limit)
        let body = Self.query(IssueURLBuilder.url(for: draft, limit: limit))["body"] ?? ""
        #expect(!body.contains("### Previous run"))
        #expect(body == IssueURLBuilder.body(for: withoutOptional))
    }

    /// 第 2 步：丢完可选小节仍超出时，从 Environment 的末尾逐行删，其余小节不动。
    @Test func trimsEnvironmentLines() {
        let draft = Self.draft(envLines: 10)
        let required = IssueDraft(title: draft.title, sections: draft.sections.filter(\.isRequired))
        var sevenLines = required
        sevenLines.sections[1].body = (1...7).map { "- Line \($0): value" }.joined(separator: "\n")
        let limit = Self.bytes(IssueURLBuilder.url(for: sevenLines, limit: 100_000))
        let body = Self.query(IssueURLBuilder.url(for: draft, limit: limit))["body"] ?? ""
        #expect(body == IssueURLBuilder.body(for: sevenLines))
        #expect(body.contains("- Line 7: value"))
        #expect(!body.contains("- Line 8: value"))
        #expect(body.contains("### Diagnostics"))
    }

    /// 第 3 步：环境行删完仍超出时，把最后一个小节按字符截短并补 `…`。
    @Test func truncatesLastSection() {
        let draft = Self.draft(envLines: 1, lastBody: String(repeating: "d", count: 4000))
        let url = IssueURLBuilder.url(for: draft, limit: 2000)
        #expect(Self.bytes(url) <= 2000)
        let body = Self.query(url)["body"] ?? ""
        #expect(body.contains("### Diagnostics\n\nddd"))
        #expect(body.hasSuffix("…\n\n"))
        #expect(!body.contains("- Line 1"))
        #expect(body.contains("### What happened"))
    }

    /// 默认上限下，再长的正文也不超过 6,000 字节，且尽量用满。
    @Test func defaultBudget() {
        let draft = Self.draft(envLines: 400, lastBody: String(repeating: "x", count: 20_000))
        let url = IssueURLBuilder.url(for: draft)
        #expect(Self.bytes(url) <= IssueURLBuilder.maxURLBytes)
        #expect(Self.bytes(url) > IssueURLBuilder.maxURLBytes - 100)
    }

    /// 刚好等于上限时原样返回；比上限少 1 字节时被缩短且不超限。
    @Test func exactlyAtLimit() {
        let draft = Self.draft()
        let full = IssueURLBuilder.url(for: draft, limit: 100_000)
        let size = Self.bytes(full)
        #expect(IssueURLBuilder.url(for: draft, limit: size) == full)
        let shorter = IssueURLBuilder.url(for: draft, limit: size - 1)
        #expect(Self.bytes(shorter) <= size - 1)
        #expect(shorter != full)
    }

    /// 含非 ASCII 字符（一个汉字编码后占 9 字节）时仍不超限。
    @Test func nonASCIIStaysWithinLimit() {
        let draft = Self.draft(title: String(repeating: "崩", count: 150), envLines: 50,
                               optionalBody: String(repeating: "旧", count: 500),
                               lastBody: String(repeating: "包", count: 2000))
        let url = IssueURLBuilder.url(for: draft)
        #expect(Self.bytes(url) <= IssueURLBuilder.maxURLBytes)
        #expect(Self.query(url)["title"]?.count == IssueURLBuilder.maxTitleCharacters)
    }

    /// 上限小到连必留小节的标题都放不下时，仍返回不超限的地址。
    @Test func tinyLimitStillBounded() {
        for limit in [80, 120, 300] {
            let url = IssueURLBuilder.url(for: Self.draft(), limit: limit)
            #expect(Self.bytes(url) <= limit)
        }
    }

    /// 问题报告的草稿：标题的两种开头；崩溃情境才有 Previous run 一节，它是可选的。
    @Test func problemReportDraft() {
        let report = DiagnosticsSummaryTests.sampleReport()
        let manual = IssueURLBuilder.problemReportDraft(isCrash: false, environment: report, previousVersion: nil,
                                                        crashReportCount: 0, archiveFileName: "x.zip")
        #expect(manual.title == "Problem report: EVE-O Preview 1.1.0 on macOS 27.0")
        #expect(manual.sections.map(\.heading) == ["What happened", "Environment", "Diagnostics"])
        let crash = IssueURLBuilder.problemReportDraft(isCrash: true, environment: report, previousVersion: "1.0.9",
                                                       crashReportCount: 2, archiveFileName: "x.zip")
        #expect(crash.title.hasPrefix("Crash report: "))
        #expect(crash.sections.map(\.heading) == ["What happened", "Environment", "Previous run", "Diagnostics"])
        #expect(crash.sections.filter { !$0.isRequired }.map(\.heading) == ["Previous run"])
        #expect(crash.sections[2].body.contains("1.0.9"))
        #expect(crash.sections[3].body.contains("x.zip"))
    }
}
