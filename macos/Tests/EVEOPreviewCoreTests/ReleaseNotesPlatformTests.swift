// SPDX-License-Identifier: GPL-3.0-or-later
//
// `ReleaseNotes.platformOnly` 的用例（docs/update-manifest.md 第 4 节第 6 条）。用例与 Windows 的
// eveo-core/src/update/notes_tests.rs 里 platform_only 的几条相同，两端的显示规则一致。

import Foundation
import Testing
import EVEOPreviewCore

/// 去掉别的平台的小节。
struct ReleaseNotesPlatformTests {
    /// 两端都改的小节（标题不正好是平台名）两边都留；本平台小节只去掉标题行，别的平台连内容一起去掉。
    @Test func keepsOwnSections() {
        let text = "Intro.\n\n## macOS and Windows\n\n- Both.\n\n## macOS\n\n- Mac item.\n\n### Detail\n\n- Mac detail.\n\n"
            + "## Windows\n\n- Win item."
        #expect(ReleaseNotes.platformOnly(text, own: "Windows") == "Intro.\n\n## macOS and Windows\n\n- Both.\n\n- Win item.")
        #expect(ReleaseNotes.platformOnly(text, own: "macOS")
            == "Intro.\n\n## macOS and Windows\n\n- Both.\n\n- Mac item.\n\n### Detail\n\n- Mac detail.")
    }

    /// 标题不分大小写；代码块里的 `#` 不算标题；没有平台小节时原样返回；只剩开头的段落时只留它。
    @Test func edgeCases() {
        #expect(ReleaseNotes.platformOnly("### WINDOWS\n- a\n### MacOS\n- b", own: "windows") == "- a")
        let code = "```\n## macOS\n```\n- a"
        #expect(ReleaseNotes.platformOnly(code, own: "Windows") == code)
        #expect(ReleaseNotes.platformOnly("- only", own: "Windows") == "- only")
        #expect(ReleaseNotes.platformOnly("Fixes Windows.\n\n## Windows\n\n- x", own: "macOS") == "Fixes Windows.")
    }

    /// 仓库里真实的 1.4.0 说明：Windows 的小节 macOS 看不到，两端共有的小节仍在。
    @Test func realNotes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/release-notes/v1.4.0.md")
        let body = try #require(try? String(contentsOf: url, encoding: .utf8))
        let zh = ReleaseNotes.section(for: .zh, in: body)
        #expect(ReleaseNotes.platformOnly(zh, own: "Windows").contains("Ctrl+Shift+J"))
        let mac = ReleaseNotes.platformOnly(zh, own: "macOS")
        #expect(!mac.contains("Ctrl+Shift+J"))
        #expect(mac.contains("macOS 与 Windows"))
    }
}
