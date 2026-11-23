// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预填的 GitHub Issue 地址（v1.1 设计 7.5 节）。
//
// - 形式：`https://github.com/deletexiumu/eve-o-preview-macos/issues/new?title=<标题>&body=<正文>`，
//   不带 `template` 与 `labels` 参数（V19）。
// - 标题与正文一律用英文。标题超过 120 个字符时截短。正文由小节拼成，每节是 `### <标题>`、空行、内容、空行。
// - 编码用 `URLComponents.queryItems`，再把查询串里的 `+` 换成 `%2B`（GitHub 把 `+` 当空格）。
// - 预算：`absoluteString.utf8.count` 不超过 6,000。超出时按以下顺序缩短，每一步之后重新计算：
//   1. 从后往前丢掉 `isRequired` 为假的小节。
//   2. 从 `Environment` 的末尾逐行删。
//   3. 把最后一个小节的内容按字符从末尾截短，补上 `…`。
//   设计只写了这 3 步；上限很小时（测试里）3 步之后仍可能超出，这时再从后往前截短更前面的小节、截短标题，
//   最后只留不带参数的地址。上限不小于不带参数的地址（62 字节）时，返回的地址总是不超过上限。
// - 标题与正文在交给本类型之前已由 App 用 `Redactor` 处理过。

import Foundation

/// Issue 正文的一个小节。
public struct IssueSection: Sendable, Equatable {
    /// 小节标题。
    public var heading: String
    /// 内容。
    public var body: String
    /// 必留的小节只会被截短，不会被丢掉。
    public var isRequired: Bool

    /// 用各字段建小节。
    public init(heading: String, body: String, isRequired: Bool) {
        self.heading = heading
        self.body = body
        self.isRequired = isRequired
    }
}

/// 一份 Issue 草稿：标题与小节。
public struct IssueDraft: Sendable, Equatable {
    /// 标题。
    public var title: String
    /// 小节，按顺序。
    public var sections: [IssueSection]

    /// 用标题与小节建草稿。
    public init(title: String, sections: [IssueSection]) {
        self.title = title
        self.sections = sections
    }
}

/// 生成预填的 Issue 地址。
public enum IssueURLBuilder {
    /// 仓库。
    public static let repository = "deletexiumu/eve-o-preview-macos"
    /// 地址的字节上限（百分号编码后）。
    public static let maxURLBytes = 6000
    /// 标题的字符上限。
    public static let maxTitleCharacters = 120
    /// 截短时补在末尾的记号。
    public static let ellipsis = "…"
    /// 缩短时逐行删的小节的标题。
    public static let environmentHeading = "Environment"

    /// 不带参数的新建 Issue 地址。
    static var baseURLString: String { "https://github.com/\(repository)/issues/new" }

    /// 正文：每节是 `### <标题>`、空行、内容、空行。
    public static func body(for draft: IssueDraft) -> String {
        draft.sections.map { "### \($0.heading)\n\n\($0.body)\n\n" }.joined()
    }

    /// 返回的 URL 百分号编码后不超过 limit 字节。
    public static func url(for draft: IssueDraft, limit: Int = maxURLBytes) -> URL {
        var current = draft
        current.title = truncatedTitle(draft.title)
        if fits(current, limit: limit) { return encodedURL(current) }

        // 第 1 步：从后往前丢掉可选的小节。
        while let index = current.sections.lastIndex(where: { !$0.isRequired }) {
            current.sections.remove(at: index)
            if fits(current, limit: limit) { return encodedURL(current) }
        }

        // 第 2 步：从 Environment 的末尾逐行删。
        if let index = current.sections.firstIndex(where: { $0.heading == environmentHeading }) {
            var lines = current.sections[index].body.components(separatedBy: "\n")
            while !lines.isEmpty {
                lines.removeLast()
                current.sections[index].body = lines.joined(separator: "\n")
                if fits(current, limit: limit) { return encodedURL(current) }
            }
        }

        // 第 3 步：从最后一个小节起，按字符从末尾截短内容；截空了仍超出时再截前一个小节。
        for index in current.sections.indices.reversed() {
            let original = current.sections[index].body
            if let kept = longestFittingPrefix(of: original, limit: limit, apply: { text in
                var trial = current
                trial.sections[index].body = text
                return trial
            }) {
                current.sections[index].body = kept
                return encodedURL(current)
            }
            current.sections[index].body = original.isEmpty ? "" : ellipsis
        }

        // 兜底：丢掉全部小节，再截短标题；都不行时只留不带参数的地址。
        current.sections = []
        if let kept = longestFittingPrefix(of: current.title, limit: limit, apply: { text in
            IssueDraft(title: text, sections: [])
        }) {
            return encodedURL(IssueDraft(title: kept, sections: []))
        }
        return URL(string: baseURLString) ?? URL(fileURLWithPath: "/")
    }

    // MARK: - 内部

    /// 标题超过 120 个字符时截到 119 个字符加 `…`。
    static func truncatedTitle(_ title: String) -> String {
        guard title.count > maxTitleCharacters else { return title }
        return String(title.prefix(maxTitleCharacters - 1)) + ellipsis
    }

    /// 草稿编码后是否不超过 limit 字节。
    static func fits(_ draft: IssueDraft, limit: Int) -> Bool {
        encodedURL(draft).absoluteString.utf8.count <= limit
    }

    /// 编码成地址：`URLComponents.queryItems` 编码，再把 `+` 换成 `%2B`。
    static func encodedURL(_ draft: IssueDraft) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/issues/new"
        components.queryItems = [URLQueryItem(name: "title", value: draft.title),
                                 URLQueryItem(name: "body", value: body(for: draft))]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: baseURLString) ?? URL(fileURLWithPath: "/")
    }

    /// 二分查找 text 能保留的最长前缀（按字符），截短时补 `…`。连空串都放不下时返回 nil。
    ///
    /// - Parameter apply: 把候选文字放回草稿。
    private static func longestFittingPrefix(of text: String, limit: Int,
                                             apply: (String) -> IssueDraft) -> String? {
        let characters = Array(text)
        func candidate(_ count: Int) -> String {
            count >= characters.count ? text : String(characters[0..<count]) + ellipsis
        }
        guard fits(apply(candidate(0)), limit: limit) else { return nil }
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(apply(candidate(middle)), limit: limit) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return candidate(low)
    }
}

extension IssueURLBuilder {
    /// 演示模式下 Issue 标题的前缀。
    public static let demoTitlePrefix = "[demo] "

    /// 问题报告的草稿（7.5 节的 4 个小节）。
    ///
    /// - Parameters:
    ///   - isCrash: 是否为崩溃情境；标题开头与是否有「Previous run」一节随之变化。
    ///   - environment: 环境报告，取版本、系统版本与 `issueLines()`；`runtime.isFakeMode` 为真时标题加 `[demo] `。
    ///   - previousVersion: 崩溃情境下上一次运行的版本。
    ///   - crashReportCount: 崩溃情境下报告里的崩溃报告个数。
    ///   - archiveFileName: zip 的文件名。
    public static func problemReportDraft(isCrash: Bool, environment: EnvironmentReport, previousVersion: String?,
                                          crashReportCount: Int, archiveFileName: String) -> IssueDraft {
        let prefix = isCrash ? "Crash report" : "Problem report"
        // 演示模式生成的报告在标题前加 `[demo] `，维护者一眼能认出不是真实的问题。
        let demo = environment.runtime.isFakeMode ? demoTitlePrefix : ""
        let title = "\(demo)\(prefix): EVE-O Preview \(environment.app.version) on macOS \(environment.system.osVersion)"
        var sections = [
            IssueSection(heading: "What happened",
                         body: "<!-- Describe what you did and what went wrong. Then drag the zip file "
                             + "that Finder is showing into this box. -->",
                         isRequired: true),
            IssueSection(heading: environmentHeading, body: environment.issueLines().joined(separator: "\n"),
                         isRequired: true),
        ]
        if isCrash {
            sections.append(IssueSection(heading: "Previous run",
                                         body: "- Version: \(previousVersion ?? "unknown")\n"
                                             + "- Crash reports: \(crashReportCount)",
                                         isRequired: false))
        }
        sections.append(IssueSection(heading: "Diagnostics",
                                     body: "Attach `\(archiveFileName)` (Finder shows it).", isRequired: true))
        return IssueDraft(title: title, sections: sections)
    }
}
