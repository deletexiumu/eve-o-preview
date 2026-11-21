// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的判断与分批规则（docs/design-intel-translate.md 7.6 节、7.8 节，14.1 节 TranslationRulesTests）：
// alreadyIn 对 8 种目标语言的正例与反例（含中日混排、没有字母的消息）；skipReason 的 4 种原因与 nil；
// cacheKey 对空白、`*`、换行的处理；nextBatch 的条数、字数上限、相同原文只取一条、第一条超长时仍被取出；
// renderTerms 只换写法不同的术语。术语匹配与情报分段都手工构造，不依赖 WP-B 的实现。
// 本文件另有翻译各测试共用的构造函数（前缀 tr，避免与其他工作包的测试重名）。人名与频道名都是虚构的。

import Testing
import Foundation
import EVEOPreviewCore

// MARK: - 共用的构造函数

/// 建一条消息。收听者、频道与说话人都是虚构的。
func trMessage(_ text: String, listener: String = "Pilot Alpha", time: Double = 1_000_000,
               speaker: String = "Vex Oran", channel: String = "chat.Demo", backfill: Bool = false) -> ChatMessage {
    ChatMessage(listener: listener, channelID: "player_" + channel, channelName: channel, time: time,
                speaker: speaker, text: text, isBackfill: backfill)
}

/// 在 text 里找 word 第一次出现的范围，建一处术语匹配。
func trMatch(_ word: String, in text: String, kind: TermKind = .ship(typeID: 1), english: String,
             localized: [String: String] = [:]) -> TermMatch {
    let range = text.range(of: word)!
    return TermMatch(range: range, kind: kind, english: english, localized: localized)
}

/// 建一条条目。
func trItem(_ id: UInt64, _ text: String, phase: TranslationPhase = .pending) -> TranslationItem {
    TranslationItem(id: id, message: trMessage(text), phase: phase)
}

/// 翻译规则。
struct TranslationRulesTests {
    // MARK: alreadyIn

    /// 中文：汉字过半为真；含假名的是日文；英文为假。
    @Test func alreadyInChinese() {
        #expect(TranslationRules.alreadyIn("吉他有红名在门口", target: .zh))
        #expect(TranslationRules.alreadyIn("吉他 gate 有红", target: .zh))
        #expect(!TranslationRules.alreadyIn("ゲートにいる敵", target: .zh))
        #expect(!TranslationRules.alreadyIn("hostile on gate", target: .zh))
    }

    /// 日文：要有假名，且假名加汉字过半；只有汉字的中文为假。
    @Test func alreadyInJapanese() {
        #expect(TranslationRules.alreadyIn("ゲートに敵がいる", target: .ja))
        #expect(!TranslationRules.alreadyIn("门口有敌人", target: .ja))
        #expect(!TranslationRules.alreadyIn("enemy at gate です", target: .ja))
    }

    /// 韩文与俄文按各自文字的占比。
    @Test func alreadyInKoreanAndRussian() {
        #expect(TranslationRules.alreadyIn("게이트에 적이 있다", target: .ko))
        #expect(!TranslationRules.alreadyIn("enemy at gate", target: .ko))
        #expect(TranslationRules.alreadyIn("враг на гейте", target: .ru))
        #expect(!TranslationRules.alreadyIn("enemy на gate now", target: .ru))
    }

    /// 拉丁字母的 4 种语言总是交给模型；没有字母的消息对任何目标都为真。
    @Test func alreadyInLatinAndNoLetters() {
        for target in [AppLanguage.en, .fr, .de, .es] {
            #expect(!TranslationRules.alreadyIn("hostile on gate", target: target))
            #expect(!TranslationRules.alreadyIn("门口有敌人", target: target))
        }
        for target in AppLanguage.allCases {
            #expect(TranslationRules.alreadyIn("7 123 :) ++ 18", target: target))
            #expect(TranslationRules.alreadyIn("", target: target))
        }
    }

    // MARK: skipReason

    /// 4 种原因与 nil。
    @Test func skipReasons() {
        let plain = IntelReport.plain("x")
        func line(_ text: String, system: Bool = false) -> ChatLine {
            ChatLine(time: 0, speaker: system ? "EVE System" : "Vex Oran", text: text, isSystem: system)
        }
        #expect(TranslationRules.skipReason(for: line("hello", system: true), report: plain, target: .zh) == .systemSpeaker)
        #expect(TranslationRules.skipReason(for: line("   "), report: plain, target: .zh) == .empty)
        #expect(TranslationRules.skipReason(for: line("门口有人"), report: plain, target: .zh) == .sameLanguage)
        #expect(TranslationRules.skipReason(for: line("hello there"), report: .plain("hello there"), target: .zh) == nil)

        // 只有星系、舰船与数量：剩下的文字为空，是 termsOnly。
        let intel = IntelReport(segments: [
            IntelSegment(text: "Jita", kind: .system(id: 30_000_142)), IntelSegment(text: " ", kind: .plain),
            IntelSegment(text: "Sabre", kind: .ship(typeID: 22456)), IntelSegment(text: " ", kind: .plain),
            IntelSegment(text: "2", kind: .count(2)),
        ], systemIDs: [30_000_142], ships: [IntelShipMention(kind: .ship(typeID: 22456), count: 2)])
        #expect(TranslationRules.skipReason(for: line("Jita Sabre 2"), report: intel, target: .zh) == .termsOnly)

        // 情报样的消息里还有一句英文：交给模型。
        let mixed = IntelReport(segments: [
            IntelSegment(text: "Jita", kind: .system(id: 30_000_142)),
            IntelSegment(text: " camp on the gate", kind: .plain),
        ], systemIDs: [30_000_142])
        #expect(TranslationRules.skipReason(for: line("Jita camp on the gate"), report: mixed, target: .zh) == nil)
    }

    // MARK: cacheKey

    /// 连续空白并成一个，去掉首尾空白与名称后面的 `*`，保留换行，去掉空行。
    @Test func cacheKeyNormalizes() {
        #expect(TranslationRules.cacheKey("  Jita*   Sabre  x2 ") == "Jita Sabre x2")
        #expect(TranslationRules.cacheKey("a*b c*") == "a*b c")
        #expect(TranslationRules.cacheKey("a**") == "a*")
        #expect(TranslationRules.cacheKey("line one\n\n  line\ttwo  \n") == "line one\nline two")
        #expect(TranslationRules.cacheKey("first\r\nsecond") == "first\nsecond")
        #expect(TranslationRules.cacheKey("  \n ") == "")
    }

    // MARK: nextBatch

    /// 一批至多 20 条。
    @Test func nextBatchCountLimit() {
        let items = (1...25).map { trItem(UInt64($0), "message \($0)") }
        #expect(TranslationRules.nextBatch(pending: items).count == 20)
    }

    /// 一批合计至多 6,000 个字符（每条按截断到 500 个字符计）；超过时停在前一条。
    @Test func nextBatchCharacterLimit() {
        let long = String(repeating: "a", count: 498)
        let items = (10...24).map { trItem(UInt64($0), long + String($0)) }
        // 每条 500 个字符，12 条正好 6,000。
        #expect(TranslationRules.nextBatch(pending: items).count == 12)
        let huge = (1...3).map { trItem(UInt64($0), String(repeating: "b", count: 3_000) + String($0)) }
        // 超长的消息按 500 计，3 条共 1,500，都能取。
        #expect(TranslationRules.nextBatch(pending: huge).count == 3)
    }

    /// 缓存键相同的只取第一条；不是 pending 的不取。
    @Test func nextBatchDeduplicates() {
        let items = [trItem(1, "hello  there"), trItem(2, "hello there*"), trItem(3, "other"),
                     trItem(4, "done one", phase: .done(text: "x", sourceLanguage: nil))]
        #expect(TranslationRules.nextBatch(pending: items).map(\.id) == [1, 3])
    }

    /// 第一条超长时仍被取出（按截断后的 500 计）。
    @Test func nextBatchFirstAlwaysTaken() {
        let items = [trItem(1, String(repeating: "z", count: 9_000))]
        #expect(TranslationRules.nextBatch(pending: items).map(\.id) == [1])
        #expect(TranslationRules.sentLength(items[0].message.text) == 500)
        #expect(TranslationRules.nextBatch(pending: []).isEmpty)
    }

    // MARK: renderTerms

    /// 只换写法不同的术语；`*` 随替换去掉；写法相同（不区分大小写）的不动。
    @Test func renderTermsReplacesOnlyDifferentSpellings() {
        let text = "Jita* sabre x2 HED-GP"
        let matches = [
            trMatch("Jita*", in: text, kind: .system(id: 1), english: "Jita", localized: ["zh": "吉他"]),
            trMatch("sabre", in: text, kind: .ship(typeID: 2), english: "Sabre", localized: ["zh": "剑齿虎级"]),
            trMatch("HED-GP", in: text, kind: .system(id: 3), english: "HED-GP"),
        ]
        #expect(TranslationRules.renderTerms(text, matches: matches, target: .zh) == "吉他 剑齿虎级 x2 HED-GP")
        // 目标是英文：Jita 与 sabre 只差 `*` 或大小写，原样不动。
        #expect(TranslationRules.renderTerms(text, matches: matches, target: .en) == text)
    }

    /// 情报用语只在有目标语言的译名时才换；重叠的匹配忽略。
    @Test func renderTermsIntelWordsAndOverlaps() {
        let text = "Naga clr"
        let clr = trMatch("clr", in: text, kind: .intelWord(.clear), english: "clear")
        #expect(TranslationRules.renderTerms(text, matches: [clr], target: .en) == "Naga clr")
        let localizedClr = trMatch("clr", in: text, kind: .intelWord(.clear), english: "clear", localized: ["zh": "安全"])
        #expect(TranslationRules.renderTerms(text, matches: [localizedClr], target: .zh) == "Naga 安全")

        let overlapText = "Naga Navy Issue"
        let full = trMatch("Naga Navy Issue", in: overlapText, english: "Naga Navy Issue", localized: ["zh": "娜迦级海军型"])
        let short = trMatch("Naga", in: overlapText, english: "Naga", localized: ["zh": "娜迦级"])
        #expect(TranslationRules.renderTerms(overlapText, matches: [full, short], target: .zh) == "娜迦级海军型")
    }
}
