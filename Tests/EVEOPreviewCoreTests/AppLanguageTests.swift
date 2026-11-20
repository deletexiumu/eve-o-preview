// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面语言的解析用例（反馈文档 3.2 节、10.1 节）。

import Testing
import EVEOPreviewCore

/// LanguagePreference.resolved：6 种选项、跟随系统、调试覆盖。
struct AppLanguageTests {
    /// 5 种具体语言的选项返回同名语言，不看系统语言。
    @Test(arguments: [
        (LanguagePreference.en, AppLanguage.en), (.zh, .zh), (.ru, .ru), (.ja, .ja), (.ko, .ko),
    ])
    func explicitPreference(preference: LanguagePreference, expected: AppLanguage) {
        #expect(preference.resolved(preferredLanguages: ["zh-Hans-CN"], override: nil) == expected)
        #expect(preference.resolved(preferredLanguages: [], override: nil) == expected)
    }

    /// 跟随系统：每种受支持语言的系统代码各对应一种语言。
    @Test(arguments: [
        ("zh-Hans-CN", AppLanguage.zh), ("ru-RU", .ru), ("ja-JP", .ja), ("ko-KR", .ko), ("en-US", .en),
        ("ZH-Hant-TW", .zh),
    ])
    func systemMapsLanguageCodes(code: String, expected: AppLanguage) {
        #expect(LanguagePreference.system.resolved(preferredLanguages: [code], override: nil) == expected)
    }

    /// 跟随系统：不受支持的语言与空列表都得到英文。
    @Test func systemFallsBackToEnglish() {
        #expect(LanguagePreference.system.resolved(preferredLanguages: ["de-DE"], override: nil) == .en)
        #expect(LanguagePreference.system.resolved(preferredLanguages: [], override: nil) == .en)
    }

    /// 跟随系统：首选语言不受支持时，取后面第一个受支持的。
    @Test func systemSkipsUnsupportedLanguages() {
        let languages = ["de-DE", "fr-FR", "ja-JP", "zh-Hans-CN"]
        #expect(LanguagePreference.system.resolved(preferredLanguages: languages, override: nil) == .ja)
    }

    /// 调试覆盖：合法的 override 优先于选项，去掉首尾空白且不区分大小写。
    @Test func overrideWins() {
        #expect(LanguagePreference.en.resolved(preferredLanguages: [], override: "ru") == .ru)
        #expect(LanguagePreference.system.resolved(preferredLanguages: ["ja-JP"], override: " KO ") == .ko)
        #expect(LanguagePreference.ja.resolved(preferredLanguages: [], override: "zh-Hans") == .zh)
    }

    /// 调试覆盖：不认识的 override 与空串被忽略，按选项解析。
    @Test func invalidOverrideIgnored() {
        #expect(LanguagePreference.zh.resolved(preferredLanguages: [], override: "de") == .zh)
        #expect(LanguagePreference.system.resolved(preferredLanguages: ["ko-KR"], override: "") == .ko)
        #expect(LanguagePreference.system.resolved(preferredLanguages: ["ru"], override: "   ") == .ru)
    }

    /// 自称不随界面语言变化。
    @Test func autonyms() {
        #expect(AppLanguage.allCases.map(\.autonym) == ["English", "中文", "Русский", "日本語", "한국어"])
    }
}
