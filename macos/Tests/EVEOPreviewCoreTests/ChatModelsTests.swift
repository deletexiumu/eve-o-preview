// SPDX-License-Identifier: GPL-3.0-or-later
//
// WP-0 写完整的几处小规则的用例（docs/macos/design-intel-translate.md 6.4 节、7.2 节）：
// IntelParser.remainder(of:)（WP-B 不改它，测试用手工构造的 IntelReport）、IntelReport.isIntelLike、
// TranslationFailure 的致命与等待时长、TranslationTarget.resolved、CharacterNameMatch。
// IntelParserTests 归 WP-B，所以 remainder 的用例放在这个 WP-0 的文件里。人名都是虚构的。

import Testing
import EVEOPreviewCore

/// 预警与翻译的小规则。
struct ChatModelsTests {
    /// 只留 plain 段，各段去首尾空白后用一个空格连接；人名不超过 3 个词时不算进去。
    @Test func remainderSkipsTermsAndShortPilots() {
        let report = IntelReport(segments: [
            IntelSegment(text: "HED-GP*", kind: .system(id: 1)), IntelSegment(text: "  ", kind: .plain),
            IntelSegment(text: "Tarn Vex", kind: .pilot), IntelSegment(text: "  gate camp  ", kind: .plain),
            IntelSegment(text: "3", kind: .count(3)), IntelSegment(text: " ", kind: .plain),
            IntelSegment(text: "clr", kind: .word(.clear)),
        ], systemIDs: [1], pilots: ["Tarn Vex"])
        #expect(IntelParser.remainder(of: report) == "gate camp")
    }

    /// 人名的总词数超过 3 个时，人名按原位置算进剩下的文字。
    @Test func remainderIncludesLongPilots() {
        let report = IntelReport(segments: [
            IntelSegment(text: "Jita", kind: .system(id: 1)), IntelSegment(text: " ", kind: .plain),
            IntelSegment(text: "Kael Doran", kind: .pilot), IntelSegment(text: " is ", kind: .plain),
            IntelSegment(text: "Mira Voss", kind: .pilot), IntelSegment(text: " here", kind: .plain),
        ], systemIDs: [1], pilots: ["Kael Doran", "Mira Voss"])
        #expect(IntelParser.remainder(of: report) == "Kael Doran is Mira Voss here")
    }

    /// 词数只看 pilot 段，不看 pilots 数组：手工构造的报告只填了段、pilots 为空时结果不变。
    @Test func remainderCountsPilotSegmentsOnly() {
        let long = IntelReport(segments: [
            IntelSegment(text: "Kael Doran", kind: .pilot), IntelSegment(text: " and ", kind: .plain),
            IntelSegment(text: "Mira Voss", kind: .pilot),
        ], systemIDs: [], pilots: [])
        #expect(IntelParser.remainder(of: long) == "Kael Doran and Mira Voss")
        let short = IntelReport(segments: [
            IntelSegment(text: "Tarn Vex", kind: .pilot), IntelSegment(text: " gate ", kind: .plain),
        ], systemIDs: [], pilots: ["Kael Doran", "Mira Voss", "Tyra Kelloway"])
        #expect(IntelParser.remainder(of: short) == "gate")
    }

    /// 什么也没认出时，remainder 就是去掉首尾空白的全文；空报告是空串。
    @Test func remainderOfPlainReport() {
        #expect(IntelParser.remainder(of: IntelReport.plain("  hello there ")) == "hello there")
        #expect(IntelParser.remainder(of: .empty).isEmpty)
        #expect(IntelReport.plain("").segments.isEmpty)
    }

    /// WP-0 的空实现：parse 返回全文一段 plain，各段拼起来等于原文。
    @Test func skeletonParse() {
        let text = "1DQ1-A  Tarn Vex  nv"
        let report = IntelParser.parse(text, matches: [])
        #expect(report.segments.map(\.text).joined() == text)
        #expect(!report.isIntelLike)
    }

    /// 认出星系或舰船才算情报。
    @Test func intelLike() {
        #expect(IntelReport(segments: [], systemIDs: [1]).isIntelLike)
        #expect(IntelReport(segments: [], ships: [IntelShipMention(kind: .ship(typeID: 2), count: 1)]).isIntelLike)
        #expect(!IntelReport(segments: [], pilots: ["Tarn Vex"], isClear: true).isIntelLike)
    }

    /// 7.5 节表里的致命与等待时长。
    @Test func failureClassification() {
        let fatal: [TranslationFailure] = [.notConfigured(.missingModel), .missingKey, .keychainUnavailable,
                                           .unauthorized(status: 401), .notFound, .insufficientBalance,
                                           .rejected(status: 400, message: "bad")]
        #expect(fatal.allSatisfy { $0.isFatal })
        let transient: [TranslationFailure] = [.rateLimited(retryAfter: 42), .server(status: 503), .network("x"),
                                               .malformedAnswer, .refused, .truncated]
        #expect(!transient.contains { $0.isFatal })
        #expect(TranslationFailure.rateLimited(retryAfter: 42).retryDelay == 42)
        #expect(TranslationFailure.server(status: 500).retryDelay == 30)
        #expect(TranslationFailure.network("x").retryDelay == 30)
        #expect(TranslationFailure.malformedAnswer.retryDelay == 0)
    }

    /// ui 跟随界面语言，其余取同名的语言。
    @Test func translationTarget() {
        #expect(TranslationTarget.ui.resolved(ui: .ja) == .ja)
        #expect(TranslationTarget.ru.resolved(ui: .ja) == .ru)
        #expect(TranslationTarget.allCases.count == 9)
    }

    /// 角色名先原样比较，再不区分大小写比较。
    @Test func characterNameMatch() {
        #expect(CharacterNameMatch.match("Kael Doran", in: ["kael doran", "Kael Doran"]) == "Kael Doran")
        #expect(CharacterNameMatch.match("KAEL DORAN", in: ["Mira Voss", "kael doran"]) == "kael doran")
        #expect(CharacterNameMatch.match("Tarn Vex", in: ["Mira Voss"]) == nil)
        let table = ["Kael Doran": 1, "mira voss": 2]
        #expect(CharacterNameMatch.value(for: "Kael Doran", in: table) == 1)
        #expect(CharacterNameMatch.value(for: "Mira Voss", in: table) == 2)
        #expect(CharacterNameMatch.key(for: "MIRA VOSS", in: table) == "mira voss")
        #expect(CharacterNameMatch.value(for: "Tarn Vex", in: table) == nil)
    }
}

/// 跟踪请求变化时要不要重建跟踪服务（审查 m6）。频道名是虚构的。
struct ChatLogRequestRestartTests {
    /// 一个基准请求。
    let base = ChatLogRequest(logDirectory: nil, channels: [ChannelRef(name: "intel.Demo", id: "player_1")],
                              followsLocation: true, backfillSeconds: 600)

    /// 只改补读时长不重建；改目录、频道或位置跟踪要重建；开和关都要重建；两边都是 nil 不重建。
    @Test func onlyBackfillDoesNotRestart() {
        var longer = base
        longer.backfillSeconds = 3_600
        #expect(!ChatLogRequest.requiresRestart(from: base, to: longer))
        #expect(!ChatLogRequest.requiresRestart(from: base, to: base))
        var moved = base
        moved.logDirectory = "/tmp/logs"
        #expect(ChatLogRequest.requiresRestart(from: base, to: moved))
        var more = base
        more.channels.append(ChannelRef(name: "chat.Demo"))
        #expect(ChatLogRequest.requiresRestart(from: base, to: more))
        var noLocation = base
        noLocation.followsLocation = false
        #expect(ChatLogRequest.requiresRestart(from: base, to: noLocation))
        #expect(ChatLogRequest.requiresRestart(from: nil, to: base))
        #expect(ChatLogRequest.requiresRestart(from: base, to: nil))
        #expect(!ChatLogRequest.requiresRestart(from: nil, to: nil))
    }

    /// 打开翻译、而翻译的频道全在预警的频道里：频道并集不变，只有补读时长与已打开的功能变了，也要重建（复审 R3）；
    /// 功能不变、只改补读时长仍不重建。
    @Test func enablingFeatureWithSubsetChannelsRestarts() {
        var intelOnly = base
        intelOnly.enabledFeatures = [.intel]
        var both = intelOnly
        both.enabledFeatures = [.intel, .translation]
        both.backfillSeconds = 600
        #expect(intelOnly.channels == both.channels)
        #expect(ChatLogRequest.requiresRestart(from: intelOnly, to: both))
        #expect(ChatLogRequest.requiresRestart(from: both, to: intelOnly))
        var longerWindow = both
        longerWindow.backfillSeconds = 3_600
        #expect(!ChatLogRequest.requiresRestart(from: both, to: longerWindow))
        // 跟踪服务对相同的请求不做任何事；功能不同的两个请求不相等，所以会重建。
        #expect(intelOnly != both)
    }
}
