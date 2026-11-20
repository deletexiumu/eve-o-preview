// SPDX-License-Identifier: GPL-3.0-or-later
//
// Redactor 与 CharacterNameCollector 的用例（v1.1 设计 7.3 节、14.1 节）。

import Foundation
import Testing
import EVEOPreviewCore

/// 脱敏。
struct RedactorTests {
    /// 测试用的本机名字：短用户名 cookie、全名、主机名两种写法、两个角色名。
    static let terms = RedactionTerms(userNames: ["cookie", "Cookie Monster"],
                                      hostNames: ["cookies-mbp.local", "cookies-mbp", "Cookie's MacBook Pro"],
                                      characterNames: ["Bob", "Bob Jr", "Alice Zed"],
                                      homeDirectory: "/Users/cookie")

    // MARK: 主目录路径

    /// 主目录路径原样出现时整个换成 `/Users/[user]`。
    @Test func homeDirectoryPlain() {
        let result = Redactor(terms: Self.terms).redact("config: /Users/cookie/Library/x.json")
        #expect(result.text == "config: /Users/[user]/Library/x.json")
        #expect(result.counts.user == 1)
    }

    /// 主目录路径的 JSON 转义写法（`\/`）换成转义的占位路径。
    @Test func homeDirectoryEscaped() {
        let result = Redactor(terms: Self.terms).redact(#"{"path":"\/Users\/cookie\/Library\/x"}"#)
        #expect(result.text == #"{"path":"\/Users\/[user]\/Library\/x"}"#)
        #expect(result.counts.user == 1)
    }

    /// 不是 `/Users/<用户名>` 的主目录也能认出来。
    @Test func nonStandardHomeDirectory() {
        let redactor = Redactor(terms: RedactionTerms(userNames: ["cookie"], homeDirectory: "/Volumes/Data/home/ck"))
        #expect(redactor.redact("at /Volumes/Data/home/ck/logs").text == "at /Users/[user]/logs")
    }

    // MARK: 用户名

    /// 用户名作为独立的词被替换；作为别的词的一部分时不被替换。
    @Test func userNameBoundaries() {
        let redactor = Redactor(terms: Self.terms)
        #expect(redactor.redact("owner cookie logged in").text == "owner [user] logged in")
        #expect(redactor.redact("HTTPCookieStorage").text == "HTTPCookieStorage")
        #expect(redactor.redact("cookies and cookie2").text == "cookies and cookie2")
        #expect(redactor.redact("user=cookie;").text == "user=[user];")
    }

    /// 全名也被替换，含空格。
    @Test func fullUserName() {
        #expect(Redactor(terms: Self.terms).redact("by Cookie Monster.").text == "by [user].")
    }

    /// 不足 3 个字符的用户名只在紧跟 `/Users/` 或 `\/Users\/` 时替换。
    @Test func shortUserNameOnlyInPaths() {
        let redactor = Redactor(terms: RedactionTerms(userNames: ["ab"]))
        #expect(redactor.redact("ab is here").text == "ab is here")
        #expect(redactor.redact("/Users/ab/Library").text == "/Users/[user]/Library")
        #expect(redactor.redact(#"\/Users\/ab\/x"#).text == #"\/Users\/[user]\/x"#)
        #expect(redactor.redact("/Users/abc/x").text == "/Users/abc/x")
    }

    /// 单个字符的用户名（只有一个标量的词）同样只在路径里替换。
    @Test func singleCharacterUserName() {
        let redactor = Redactor(terms: RedactionTerms(userNames: ["q"]))
        #expect(redactor.redact("quick q /Users/q/x").text == "quick q /Users/[user]/x")
        #expect(redactor.redact(#"\/Users\/Q\/x"#).text == #"\/Users\/[user]\/x"#)
        #expect(redactor.redact("/Users/qq/x").text == "/Users/qq/x")
    }

    // MARK: 主机名

    /// 主机名的各种写法都换成 `[host]`，长的写法先匹配。
    @Test func hostNames() {
        let result = Redactor(terms: Self.terms).redact("host cookies-mbp.local, short cookies-mbp, Cookie's MacBook Pro")
        #expect(result.text == "host [host], short [host], [host]")
        #expect(result.counts.host == 3)
    }

    // MARK: 角色名

    /// 角色名不区分大小写。
    @Test func characterNamesCaseInsensitive() {
        let redactor = Redactor(terms: Self.terms)
        #expect(redactor.redact("ALICE ZED and alice zed").text == "[character-1] and [character-1]")
    }

    /// 最长优先：`Bob Jr` 先于 `Bob` 匹配。
    @Test func longestMatchWins() {
        let redactor = Redactor(terms: Self.terms)
        let jr = redactor.placeholder(forCharacter: "Bob Jr") ?? "?"
        let bob = redactor.placeholder(forCharacter: "Bob") ?? "?"
        #expect(redactor.redact("Bob Jr met Bob").text == "\(jr) met \(bob)")
    }

    /// 中文角色名不要求边界；单个非 ASCII 字符的名字不替换。
    @Test func nonASCIINamesNeedNoBoundary() {
        let redactor = Redactor(terms: RedactionTerms(characterNames: ["星辰大海", "龙"]))
        let result = redactor.redact("角色星辰大海上线，龙")
        #expect(result.text == "角色[character-1]上线，龙")
        #expect(redactor.placeholder(forCharacter: "龙") == nil)
        #expect(result.counts.character == 1)
    }

    /// 名叫 `user` 的角色不破坏已输出的占位符。
    @Test func characterNamedUserKeepsPlaceholders() {
        let redactor = Redactor(terms: RedactionTerms(userNames: ["cookie"], characterNames: ["user"],
                                                      homeDirectory: "/Users/cookie"))
        let result = redactor.redact("/Users/cookie/x cookie user")
        #expect(result.text == "/Users/[user]/x [user] [character-1]")
        #expect(result.counts.user == 2)
        #expect(result.counts.character == 1)
    }

    /// 序号按名字排序（不区分大小写）后从 1 起编，与传入顺序无关。
    @Test func characterNumberingIsSortedAndStable() {
        let a = Redactor(terms: RedactionTerms(characterNames: ["zeta", "Alpha", "mike"]))
        let b = Redactor(terms: RedactionTerms(characterNames: ["mike", "zeta", "Alpha", "ALPHA"]))
        for redactor in [a, b] {
            #expect(redactor.placeholder(forCharacter: "Alpha") == "[character-1]")
            #expect(redactor.placeholder(forCharacter: "alpha") == "[character-1]")
            #expect(redactor.placeholder(forCharacter: "mike") == "[character-2]")
            #expect(redactor.placeholder(forCharacter: "zeta") == "[character-3]")
        }
        #expect(a.placeholder(forCharacter: "nobody") == nil)
    }

    // MARK: Unicode 规范化

    /// 「José García」的 NFC（预组合）与 NFD（分解）两种写法。用转义写出，免得源文件保存时被规范化。
    static let nfcName = "Jos\u{E9} Garc\u{ED}a"
    static let nfdName = "Jose\u{301} Garci\u{301}a"

    /// 两种写法在标量层面确实不同，字符层面相同（否则下面的用例测不到东西）。
    @Test func normalizationFixturesDiffer() {
        #expect(Self.nfcName.unicodeScalars.count == 11)
        #expect(Self.nfdName.unicodeScalars.count == 13)
        #expect(Self.nfcName == Self.nfdName)
        #expect(Array(Self.nfcName.unicodeScalars) != Array(Self.nfdName.unicodeScalars))
    }

    /// 词是 NFC、正文是 NFD，或反过来，都能替换；同一个名字的两种写法得到同一个占位符。
    @Test(arguments: [(RedactorTests.nfcName, RedactorTests.nfdName), (RedactorTests.nfdName, RedactorTests.nfcName),
                      (RedactorTests.nfcName, RedactorTests.nfcName), (RedactorTests.nfdName, RedactorTests.nfdName)])
    func characterNameInBothForms(term: String, text: String) {
        let redactor = Redactor(terms: RedactionTerms(characterNames: [term]))
        let result = redactor.redact("pilot \(text) undocked")
        #expect(result.text == "pilot [character-1] undocked")
        #expect(result.counts.character == 1)
        #expect(redactor.placeholder(forCharacter: Self.nfcName) == "[character-1]")
        #expect(redactor.placeholder(forCharacter: Self.nfdName) == "[character-1]")
    }

    /// 全名与主目录路径也按两种写法匹配（文件系统给出的路径常是 NFD）；一段文字里两种写法都换掉。
    @Test func userNameAndHomeInBothForms() {
        let redactor = Redactor(terms: RedactionTerms(userNames: [Self.nfcName],
                                                      homeDirectory: "/Users/" + Self.nfcName))
        let text = "\(Self.nfdName) at /Users/\(Self.nfdName)/x and \(Self.nfcName)"
        let result = redactor.redact(text)
        #expect(result.text == "[user] at /Users/[user]/x and [user]")
        #expect(result.counts.user == 3)
    }

    /// 同一个名字的两种写法同时出现在角色名里时只占一个序号。
    @Test func bothFormsShareOneNumber() {
        let redactor = Redactor(terms: RedactionTerms(characterNames: [Self.nfdName, "Alpha", Self.nfcName]))
        #expect(redactor.placeholder(forCharacter: "Alpha") == "[character-1]")
        #expect(redactor.placeholder(forCharacter: Self.nfcName) == "[character-2]")
        #expect(redactor.redact("\(Self.nfcName)/\(Self.nfdName)").text == "[character-2]/[character-2]")
    }

    // MARK: 设备标识

    /// `crashReporterKey` 与 `deviceIdentifierForVendor` 的值被替换，键保留；冒号两侧的空白可有可无。
    @Test func deviceIdentifiers() {
        let text = #"{"crashReporterKey" : "ABCD-1234","deviceIdentifierForVendor":"F00D","other":"keep"}"#
        let result = Redactor(terms: RedactionTerms()).redact(text)
        #expect(result.text == #"{"crashReporterKey" : "[redacted]","deviceIdentifierForVendor":"[redacted]","other":"keep"}"#)
        #expect(result.counts.identifier == 2)
    }

    /// 替换后的 JSON 仍能解析，内容是预期的占位符。
    @Test func redactedJSONStillParses() throws {
        let json = #"""
        {"app_name":"EVEOPreview","crashReporterKey":"5E3B","path":"\/Users\/cookie\/Applications\/EVE-O Preview.app","host":"cookies-mbp","note":"Bob Jr"}
        """#
        let result = Redactor(terms: Self.terms).redact(json)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: String])
        #expect(object["crashReporterKey"] == "[redacted]")
        #expect(object["path"] == "/Users/[user]/Applications/EVE-O Preview.app")
        #expect(object["host"] == "[host]")
        #expect(object["note"]?.hasPrefix("[character-") == true)
        #expect(object["app_name"] == "EVEOPreview")
    }

    // MARK: 计数与空词表

    /// 计数按类别累计，`+` 按类别相加。
    @Test func countsAccumulate() {
        let result = Redactor(terms: Self.terms).redact(
            "/Users/cookie cookie cookies-mbp Bob \"crashReporterKey\":\"x\"")
        #expect(result.counts == RedactionCounts(user: 2, host: 1, character: 1, identifier: 1))
        #expect(result.counts.total == 5)
        let sum = result.counts + RedactionCounts(user: 1, host: 1, character: 1, identifier: 1)
        #expect(sum == RedactionCounts(user: 3, host: 2, character: 2, identifier: 2))
    }

    /// 空的词表原样返回；空白的词被忽略，不会匹配到每个位置。
    @Test func emptyTermsReturnInput() {
        let text = "nothing to hide at /Users/someone"
        #expect(Redactor(terms: RedactionTerms()).redact(text).text == text)
        let blanks = Redactor(terms: RedactionTerms(userNames: ["", "  "], hostNames: [""], characterNames: [" "],
                                                    homeDirectory: ""))
        let result = blanks.redact(text)
        #expect(result.text == text)
        #expect(result.counts.total == 0)
    }
}

/// 角色名的收集。
struct CharacterNameCollectorTests {
    /// 全部配置方案的各处角色名加上在线角色，去重并排序。
    @Test func collectsFromAllProfiles() {
        let first = Profile(name: "Main", layouts: ["Alpha": ThumbnailLayout(x: 0, y: 0)], hiddenCharacters: ["Bravo"],
                            highlightColors: ["Charlie": "#FF0000"],
                            cycleGroups: [CycleGroup(name: "G", members: ["Delta", "Alpha"])],
                            characterHotkeys: ["Echo": ["F1"]])
        let second = Profile(name: "Other", hiddenCharacters: ["Foxtrot", " "])
        let config = AppConfig(activeProfileID: first.id, profiles: [first, second])
        let names = CharacterNameCollector.names(config: config, online: ["Golf", "Alpha"])
        #expect(names == ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf"])
    }
}
