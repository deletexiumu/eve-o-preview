// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警行的测试（docs/design-intel-translate.md 6.7 节、6.9 节、14.1 节）。说话人与人名是虚构的；
// 文字由固定输出的 IntelLineFormatting 给出，便于逐段比较。

import Testing
import Foundation
@testable import EVEOPreviewCore

/// 固定输出的文字：年龄写成「Ns」，跳数写成「Nj」等。
struct FixedIntelFormatter: IntelLineFormatting {
    func age(seconds: Int) -> String { "\(seconds)s" }
    func jumps(_ distance: JumpDistance) -> String {
        switch distance {
        case .jumps(let count): "\(count)j"
        case .beyond(let limit): ">\(limit)j"
        case .unreachable: "nogate"
        case .unknownOrigin: "?"
        }
    }
    func count(_ value: Int, isExplicit: Bool) -> String { isExplicit ? "×\(value)" : "~×\(value)" }
    var clear: String { "CLR" }
    var noVisual: String { "NV" }
}

@Suite struct IntelPresenterTests {
    typealias F = StaticDataFixtures
    /// 夹具的星图数据。
    private let data: EVEStaticData
    init() throws { data = try StaticDataFixtures.data() }

    /// 消息时间；now 默认比它晚 45 秒。
    private let messageTime = 1_000_000.0

    /// 解析一条消息放进缓冲项。
    private func item(_ text: String, time: Double? = nil, id: UInt64 = 1) -> IntelItem {
        let message = IntelTestMessages.message(text, time: time ?? messageTime)
        return IntelItem(id: id, message: message, report: IntelParser.parse(text, data: data))
    }

    /// 从 Jita 出发的上下文。
    private func context(showOriginal: Bool = true, alertJumps: Int = 5, origin: Int? = StaticDataFixtures.jita,
                         age: Double = 45, pilots: PilotDirectory = .empty) -> IntelPresentationContext {
        var settings = IntelSettings()
        settings.showOriginal = showOriginal
        settings.alertJumps = alertJumps
        let table = origin.map { JumpGraph.distances(from: $0, maxJumps: settings.maxJumps, in: data) }
        return IntelPresentationContext(origin: origin.map { .reference(systemID: $0) } ?? .unknown,
                                        distances: table, settings: settings, language: .en,
                                        now: messageTime + age, pilots: pilots)
    }

    /// 生成一行。
    private func line(_ item: IntelItem, _ context: IntelPresentationContext) -> OverlayLine {
        IntelPresenter.line(item, context: context, data: data, formatter: FixedIntelFormatter())
    }

    /// 去掉分隔用的空格，只看有内容的段。
    private func spans(_ line: OverlayLine) -> [OverlaySpan] {
        line.primary.filter { $0.text != " " }
    }

    /// 一条情报的各部分与样式；第二行是说话人与原文。
    @Test func intelLineParts() {
        let value = line(item("Hek* 3x Naga"), context())
        #expect(spans(value) == [OverlaySpan("40s", .ageFresh), OverlaySpan("Hek 0.8", .systemHigh),
                                 OverlaySpan("4j", .jumpsNear), OverlaySpan("×3", .count),
                                 OverlaySpan("Naga×3", .ship)])
        #expect(value.primary[1] == OverlaySpan(" ", .plain))
        #expect(value.secondary == [OverlaySpan("Mira Voss", .speaker), OverlaySpan(": Hek* 3x Naga", .dim)])
        #expect(value.emphasis == .alert)
        #expect(value.copyText == "[13:46:40] Mira Voss > Hek* 3x Naga")
        #expect(value.links.isEmpty)
    }

    /// 3 档新旧；不足 60 秒时向下取到 10 秒。
    @Test func freshness() {
        #expect(IntelPresenter.freshness(age: 119) == .fresh)
        #expect(IntelPresenter.freshness(age: 120) == .recent)
        #expect(IntelPresenter.freshness(age: 299) == .recent)
        #expect(IntelPresenter.freshness(age: 300) == .old)
        #expect(spans(line(item("Jita"), context(age: 59))).first == OverlaySpan("50s", .ageFresh))
        #expect(spans(line(item("Jita"), context(age: 200))).first == OverlaySpan("200s", .ageRecent))
        #expect(spans(line(item("Jita"), context(age: 400))).first == OverlaySpan("400s", .ageOld))
    }

    /// 4 档安全等级：高安、低安、00 与虫洞。
    @Test func securityStyles() {
        #expect(spans(line(item("Jita"), context()))[1] == OverlaySpan("Jita 0.9", .systemHigh))
        #expect(spans(line(item("纳伽"), context()))[1] == OverlaySpan("Naga 0.1", .systemLow))
        #expect(spans(line(item("1DQ1-A"), context()))[1] == OverlaySpan("1DQ1-A -0.4", .systemNull))
        #expect(spans(line(item("Thera"), context()))[1] == OverlaySpan("Thera", .systemUnknown))
        // 显示语言是上下文里的界面语言。
        var chinese = context()
        chinese.language = .zh
        #expect(spans(line(item("Jita"), chinese))[1] == OverlaySpan("吉他 0.9", .systemHigh))
    }

    /// 跳数的 4 种样式；alertJumps 为 0 时不高亮。
    @Test func jumpStyles() {
        let near = spans(line(item("Perimeter"), context(alertJumps: 2)))
        #expect(near[2] == OverlaySpan("1j", .jumpsNear))
        #expect(spans(line(item("Hek"), context(alertJumps: 2)))[2] == OverlaySpan("4j", .jumpsMid))
        #expect(spans(line(item("Amarr"), context(alertJumps: 2)))[2] == OverlaySpan("5j", .jumpsFar))
        #expect(spans(line(item("Onsooh"), context(alertJumps: 2)))[2] == OverlaySpan("nogate", .jumpsUnknown))
        #expect(spans(line(item("Jita"), context(origin: nil)))[2] == OverlaySpan("?", .jumpsUnknown))
        let off = line(item("Perimeter"), context(alertJumps: 0))
        #expect(spans(off)[2] == OverlaySpan("1j", .jumpsFar))
        #expect(off.emphasis == .none)
    }

    /// showOriginal 关闭时没有第二行，推断的人名列在第一行，人名之间有分隔。
    @Test func showOriginalOff() {
        let value = line(item("T5ZI-S  Jorn Halden  Tarn Vex nv"), context(showOriginal: false))
        #expect(value.secondary.isEmpty)
        let texts = spans(value).map(\.text)
        #expect(texts.contains("Jorn Halden"))
        #expect(texts.contains(" · "))
        #expect(texts.last == "NV")
        #expect(spans(value).first { $0.text == "Jorn Halden" }?.style == .pilot)
        // 显示原文时推断的人名不列。
        #expect(!spans(line(item("T5ZI-S  Jorn Halden"), context())).map(\.text).contains("Jorn Halden"))
    }

    /// 不是情报的消息：时间、说话人与原文，没有第二行。
    @Test func plainMessage() {
        let value = line(item("hello there"), context())
        #expect(value.primary == [OverlaySpan("40s", .ageFresh), OverlaySpan(" ", .plain),
                                  OverlaySpan("Mira Voss", .speaker), OverlaySpan(": hello there", .plain)])
        #expect(value.secondary.isEmpty)
        #expect(value.emphasis == .none)
    }

    /// emphasis 的 3 种取值。
    @Test func emphasis() {
        #expect(line(item("Hek* clr"), context()).emphasis == .clear)
        #expect(line(item("Perimeter Rifter"), context()).emphasis == .alert)
        #expect(line(item("HED-GP Rifter"), context(alertJumps: 3)).emphasis == .none)
        #expect(spans(line(item("Hek* clr"), context())).last == OverlaySpan("CLR", .clear))
    }

    /// nextRefresh 的 3 种结果。
    @Test func nextRefresh() {
        let recent = item("Jita", time: 100)
        #expect(IntelPresenter.nextRefresh(items: [], now: 0) == nil)
        #expect(IntelPresenter.nextRefresh(items: [recent], now: 130) == 140)
        #expect(IntelPresenter.nextRefresh(items: [recent], now: 200) == 230)
    }

    // MARK: - 6.9 增补

    /// 查到的人名在 showOriginal 为真时也列出；没查到的带「?」用 dim；数量取核对后的值；links 每个查到的一项。
    @Test func resolvedPilots() {
        let source = item("HED-GP  Brenn Ostvar Tyra Kelloway  Kael Dorann")
        let directory = PilotDirectory([
            "brenn": .notFound, "ostvar": .notFound, "tyra": .notFound, "kelloway": .notFound,
            "brenn ostvar": .matched(characterID: 91, name: "Brenn Ostvar"), "ostvar tyra": .notFound,
            "tyra kelloway": .matched(characterID: 92, name: "Tyra Kelloway"), "brenn ostvar tyra": .notFound,
            "ostvar tyra kelloway": .notFound, "kael": .matched(characterID: 0, name: "Kael"),
            "dorann": .notFound, "kael dorann": .notFound,
        ])
        let shown = line(source, context(pilots: directory))
        let texts = spans(shown).map(\.text)
        #expect(texts.contains("Brenn Ostvar") && texts.contains("Tyra Kelloway"))
        #expect(!texts.contains("Kael Dorann?"))
        #expect(texts.contains("~×3"))
        #expect(shown.links == [OverlayLink(title: "Brenn Ostvar · zKillboard",
                                            url: "https://zkillboard.com/character/91/"),
                                OverlayLink(title: "Tyra Kelloway · zKillboard",
                                            url: "https://zkillboard.com/character/92/")])
        let hidden = line(source, context(showOriginal: false, pilots: directory))
        #expect(spans(hidden).contains(OverlaySpan("Kael Dorann?", .dim)))
        // 角色 ID 是 0 时没有链接（演示模式的假核对服务）。
        let fake = PilotDirectory(["kael": .notFound, "doran": .notFound,
                                   "kael doran": .matched(characterID: 0, name: "Kael Doran")])
        #expect(line(item("HED-GP Kael Doran"), context(pilots: fake)).links.isEmpty)
    }

    /// 数量取核对后的值：推断是 2 人（「Brenn Ostvar Tyra」与「Kelloway」），4 个单个词都查到时是约 ×4。
    @Test func countUsesResolvedPilots() {
        let source = item("HED-GP  Brenn Ostvar Tyra Kelloway")
        #expect(source.report.hostileCount == 2)
        let run = ["Brenn", "Ostvar", "Tyra", "Kelloway"]
        var outcomes: [String: PilotLookupOutcome] = [:]
        for name in PilotSegmenter.combinations(of: run) { outcomes[PilotLookupAnswer.key(for: name)] = .notFound }
        for (index, name) in run.enumerated() {
            outcomes[name.lowercased()] = .matched(characterID: 10 + index, name: name)
        }
        let texts = spans(line(source, context(pilots: PilotDirectory(outcomes)))).map(\.text)
        #expect(texts.contains("~×4"))
        #expect(!texts.contains("~×2"))
        #expect(line(source, context(pilots: PilotDirectory(outcomes))).links.count == 4)
    }

    /// pilots 为空时与核对前的输出相同：人名未核对，数量取 report 的值，没有链接。
    @Test func emptyDirectoryMatchesInference() {
        let source = item("HED-GP  Brenn Ostvar Tyra Kelloway")
        let value = line(source, context(showOriginal: false))
        let texts = spans(value).map(\.text)
        #expect(texts.contains("Brenn Ostvar Tyra"))
        #expect(texts.contains("Kelloway"))
        #expect(texts.contains("~×2"))
        #expect(value.links.isEmpty)
    }
}
