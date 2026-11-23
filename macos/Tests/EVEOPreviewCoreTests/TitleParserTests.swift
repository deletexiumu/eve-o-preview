// SPDX-License-Identifier: GPL-3.0-or-later
//
// TitleParser 的用例（架构文档 5.3 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 标题解析：登录、角色、未知三种身份与显示标题。
struct TitleParserTests {
    /// `EVE` 与 `eve` 都是登录客户端（不区分大小写）。
    @Test(arguments: ["EVE", "eve", "Eve", "  EVE  "])
    func loginTitles(title: String) {
        #expect(TitleParser.identity(fromTitle: title) == .login)
    }

    /// `EVE - Name` 解析出角色名。
    @Test func characterTitle() {
        #expect(TitleParser.identity(fromTitle: "EVE - Pilot Alpha") == .character("Pilot Alpha"))
    }

    /// 首尾空白被去掉，角色名里的空格保留。
    @Test func characterWithSurroundingWhitespace() {
        #expect(TitleParser.identity(fromTitle: "  EVE - bravo pilot \n") == .character("bravo pilot"))
    }

    /// `EVE - ` 后面为空时是未知客户端。
    @Test(arguments: ["EVE - ", "EVE -", "EVE -   "])
    func emptyCharacterName(title: String) {
        #expect(TitleParser.identity(fromTitle: title) == .unknown)
    }

    /// 角色名本身含 ` - ` 时只去掉第一个前缀。
    @Test func characterNameContainingSeparator() {
        #expect(TitleParser.identity(fromTitle: "EVE - Foo - Bar") == .character("Foo - Bar"))
    }

    /// nil 与空串是未知客户端。
    @Test func nilAndEmpty() {
        #expect(TitleParser.identity(fromTitle: nil) == .unknown)
        #expect(TitleParser.identity(fromTitle: "") == .unknown)
    }

    /// 其他标题（包括大小写不同的前缀与启动器）是未知客户端。
    @Test(arguments: ["EVE Launcher", "Settings", "eve - Pilot Alpha", "EVE-Pilot Alpha", "EVEs"])
    func otherTitles(title: String) {
        #expect(TitleParser.identity(fromTitle: title) == .unknown)
    }

    /// 显示标题：角色名、`EVE`、`EVE (<pid>)`。
    @Test func displayTitles() {
        #expect(TitleParser.title(for: .character("Pilot Alpha"), pid: 1) == "Pilot Alpha")
        #expect(TitleParser.title(for: .login, pid: 1) == "EVE")
        #expect(TitleParser.title(for: .unknown, pid: 4101) == "EVE (4101)")
    }

    /// 切换目标的标题：角色与登录用真实标题，未知客户端不按标题匹配。
    @Test func clientTargetTitles() {
        #expect(Fixtures.character("Pilot Alpha", id: 1, pid: 2).target.title == "EVE - Pilot Alpha")
        #expect(Fixtures.client(1, pid: 2, .login).target.title == "EVE")
        #expect(Fixtures.client(1, pid: 2, .unknown).target.title == nil)
    }
}
