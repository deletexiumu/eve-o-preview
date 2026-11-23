// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗的一行（docs/design-intel-translate.md 7.10 节，14.1 节 TranslationPresenterTests）：表里的 5 行；
// 多于一个频道时显示频道名；foreignOnly 隐藏的两种情形；copyText。说话人与频道名是虚构的。

import Testing
import Foundation
import EVEOPreviewCore

/// 测试用的格式器：时间写成秒数，状态词固定。
private struct StubFormatter: TranslationLineFormatting {
    func time(_ utc: Double) -> String { "T\(Int(utc))" }
    var pending: String { "PENDING" }
    var failed: String { "FAILED" }
}

/// 翻译浮窗的一行。
struct TranslationPresenterTests {
    /// 一个频道、显示原文的设置。
    func settings(channels: Int = 1, showOriginal: Bool = true, foreignOnly: Bool = false) -> TranslationSettings {
        var value = TranslationSettings()
        value.channels = (0..<channels).map { ChannelRef(name: "chat\($0).Demo") }
        value.showOriginal = showOriginal
        value.foreignOnly = foreignOnly
        return value
    }

    /// 一行。
    func line(_ phase: TranslationPhase, _ settings: TranslationSettings) -> OverlayLine? {
        let item = TranslationItem(id: 5, message: trMessage("hola amigos", time: 60), phase: phase)
        return TranslationPresenter.line(item, settings: settings, formatter: StubFormatter())
    }

    /// 第一行开头的固定部分：时间、空格、说话人、冒号。
    let head = [OverlaySpan("T60", .dim), OverlaySpan(" ", .plain), OverlaySpan("Vex Oran", .speaker),
                OverlaySpan(": ", .dim)]

    /// done：译文用 translated，showOriginal 时第二行是原文。
    @Test func doneRow() throws {
        let row = try #require(line(.done(text: "hello friends", sourceLanguage: "es"), settings()))
        #expect(row.id == 5)
        #expect(row.primary == head + [OverlaySpan("hello friends", .translated)])
        #expect(row.secondary == [OverlaySpan("hola amigos", .dim)])
        #expect(row.emphasis == .none && row.links.isEmpty)
        let hidden = try #require(line(.done(text: "hello friends", sourceLanguage: nil), settings(showOriginal: false)))
        #expect(hidden.secondary.isEmpty)
    }

    /// skipped 且有 rendered：rendered 用 plain，showOriginal 时第二行是原文。
    @Test func renderedRow() throws {
        let row = try #require(line(.skipped(.termsOnly, rendered: "吉他 2"), settings()))
        #expect(row.primary == head + [OverlaySpan("吉他 2", .plain)])
        #expect(row.secondary == [OverlaySpan("hola amigos", .dim)])
    }

    /// skipped 没有 rendered 与 off：原文用 plain，没有第二行。
    @Test func plainRows() throws {
        for phase in [TranslationPhase.skipped(.sameLanguage, rendered: nil), .off] {
            let row = try #require(line(phase, settings()))
            #expect(row.primary == head + [OverlaySpan("hola amigos", .plain)])
            #expect(row.secondary.isEmpty)
        }
    }

    /// pending、inFlight：原文后面加「翻译中…」；failed：加「未翻译」。
    @Test func pendingAndFailedRows() throws {
        for phase in [TranslationPhase.pending, .inFlight] {
            let row = try #require(line(phase, settings()))
            #expect(row.primary == head + [OverlaySpan("hola amigos", .plain), OverlaySpan(" PENDING", .pending)])
            #expect(row.secondary.isEmpty)
        }
        let failed = try #require(line(.failed, settings()))
        #expect(failed.primary.last == OverlaySpan(" FAILED", .failed))
        #expect(failed.secondary.isEmpty)
    }

    /// 多于一个频道时，说话人前面加 [频道名]（channel 样式）。
    @Test func channelShownWhenSeveral() throws {
        let row = try #require(line(.off, settings(channels: 2)))
        #expect(row.primary[2] == OverlaySpan("[chat.Demo]", .channel))
        #expect(row.primary[4] == OverlaySpan("Vex Oran", .speaker))
        #expect(try #require(line(.off, settings(channels: 1))).primary[2] == OverlaySpan("Vex Oran", .speaker))
    }

    /// foreignOnly：已是目标语言与空消息不显示；只有术语的消息与译文照常显示。
    @Test func foreignOnlyHides() {
        let onlyForeign = settings(foreignOnly: true)
        #expect(line(.skipped(.sameLanguage, rendered: nil), onlyForeign) == nil)
        #expect(line(.skipped(.empty, rendered: nil), onlyForeign) == nil)
        #expect(line(.skipped(.termsOnly, rendered: nil), onlyForeign) != nil)
        #expect(line(.done(text: "x", sourceLanguage: nil), onlyForeign) != nil)
        #expect(line(.skipped(.sameLanguage, rendered: nil), settings()) != nil)
    }

    /// copyText：说话人与原文；有译文时另起一行。
    @Test func copyText() {
        #expect(line(.off, settings())?.copyText == "Vex Oran: hola amigos")
        #expect(line(.done(text: "hello friends", sourceLanguage: nil), settings())?.copyText
            == "Vex Oran: hola amigos\nhello friends")
        #expect(line(.skipped(.termsOnly, rendered: "吉他"), settings())?.copyText == "Vex Oran: hola amigos\n吉他")
    }
}
