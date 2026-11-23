// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布说明的显示（v1.1 设计 8.7 节）。SwiftUI 的 `Text` 只渲染行内 Markdown，不渲染标题与列表，
// 所以先用 Core 的 `ReleaseNotes.blocks(from:)` 切成块，再逐块显示：
// - 块里的文字用 `AttributedString(markdown:options:)`（`inlineOnlyPreservingWhitespace`）渲染粗体、行内代码和链接；
//   解析失败时按纯文本显示。
// - 链接只在协议是 `https` 时可点：别的协议的链接在建文字时就去掉链接属性，点击时再查一次，用默认浏览器打开。
// - 剩下的 HTML 标签按纯文本显示，不解释；不用 WebView，不加载图片与任何远程资源（10.3 节）。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 一段发布说明（已按界面语言取出）的显示。外层负责滚动。
struct ReleaseNotesView: View {
    /// 已由 `ReleaseNotes.section(for:in:)` 取出的 Markdown 文字。
    let markdown: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        // 点击链接时再核对一次协议，只把 https 交给默认浏览器。
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "https" else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    /// 一块的显示。文字都允许换行，不截断。
    @ViewBuilder
    private func blockView(_ block: ReleaseNotesBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(Self.headingFont(level: level))
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth, let text):
            listRow(marker: depth == 0 ? "•" : "◦", text: text, indent: depth)
        case .numbered(let number, let text):
            listRow(marker: "\(number).", text: text, indent: 0)
        case .code(let text):
            Text(verbatim: text).font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 列表的一行：记号与文字按首行基线对齐，每级缩进 16 点。
    private func listRow(marker: String, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: marker).monospacedDigit().foregroundStyle(.secondary)
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// 标题的字体：1 级最大，3 级及以下同正文加粗。
    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    /// 渲染行内 Markdown。解析失败时按纯文本；协议不是 https 的链接与图片地址去掉，只留文字。
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        // 先收集再修改：边遍历 runs 边改属性会让下标失效。
        let unsafeLinks = attributed.runs[\.link].compactMap { link, range in
            link.map { $0.scheme?.lowercased() == "https" } == false ? range : nil
        }
        for range in unsafeLinks { attributed[range].link = nil }
        let images = attributed.runs[\.imageURL].compactMap { url, range in url == nil ? nil : range }
        for range in images { attributed[range].imageURL = nil }
        return attributed
    }
}
