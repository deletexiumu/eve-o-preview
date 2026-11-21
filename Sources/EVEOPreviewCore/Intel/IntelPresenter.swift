// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警浮窗每一行的内容（docs/design-intel-translate.md 6.7 节，6.9 节改了数量与人名两部分）。
// 界面文字由 App 用 L10n.intel 实现 IntelLineFormatting 交进来，Core 不碰界面文字。
//
// 一条情报（isIntelLike）的第一行，各部分之间隔一个空格：
// | 时间       | 不足 60 秒时向下取到 10 秒的倍数；不足 120 秒 ageFresh，不足 300 秒 ageRecent，其余 ageOld |
// | 每个星系   | 名称加显示用的安全等级；≥0.5 systemHigh，0.1～0.4 systemLow，≤0.0 systemNull，没有或虫洞 systemUnknown |
// | 星系的跳数 | 跟在星系后面；alertJumps>0 且不超过它 jumpsNear，不超过 2 倍 jumpsMid，更远 jumpsFar，其余 jumpsUnknown |
// | 数量       | PilotSegmenter.resolve 给出的 hostileCount 大于 0 时显示，count 样式                       |
// | 舰船       | 名称；数量大于 1 时加「×数量」，ship 样式                                                  |
// | 人名       | 查到的总是列出（pilot）；未核对的只在不显示原文时列出（pilot）；没查到的只在不显示原文时列出，加「?」（dim） |
// | 用语       | clear、noVisual                                                                           |
// 相邻两个人名之间加「 · 」（dim）：人名里有空格，只隔一个空格分不清。
// 第二行：显示原文时是「说话人: 原文」。不是情报的消息：第一行是时间、说话人与原文，没有第二行。
// emphasis：isClear 时 clear；否则 alertJumps>0 且某个星系的跳数不超过它时 alert；其余 none。
// copyText：「[HH:mm:ss] 说话人 > 原文」，时间是日志里的 EVE 时间（UTC）。
// links：每个查到的、角色 ID 大于 0 的人名一项，指向 zKillboard 的角色页；地址里只有数字 ID。

import Foundation

/// 消息的新旧。
public enum IntelFreshness: Sendable, Equatable {
    /// 不足 120 秒。
    case fresh
    /// 不足 300 秒。
    case recent
    /// 更早。
    case old
}

/// 预警行里随界面语言变的文字。
public protocol IntelLineFormatting: Sendable {
    /// 多久以前，如「40 秒」「3 分钟」。
    func age(seconds: Int) -> String
    /// 跳数。
    func jumps(_ distance: JumpDistance) -> String
    /// 敌对数量；isExplicit 为假时显示成「约 ×N」。
    func count(_ value: Int, isExplicit: Bool) -> String
    /// 「安全」。
    var clear: String { get }
    /// 「未见」。
    var noVisual: String { get }
}

/// 生成一行时用到的上下文。
public struct IntelPresentationContext: Sendable {
    /// 跳数的出发点。
    public var origin: LocationOrigin
    /// 从 origin 算出的跳数表；origin 未知时为 nil。
    public var distances: [Int: Int]?
    /// 预警设置。
    public var settings: IntelSettings
    /// 舰船与星系名的显示语言（界面语言）。
    public var language: AppLanguage
    /// 当前时刻（墙上时钟）。
    public var now: Double
    /// 人名核对的结果；开关关闭时是 .empty（6.9 节）。
    public var pilots: PilotDirectory

    /// 用各字段建上下文。
    public init(origin: LocationOrigin, distances: [Int: Int]?, settings: IntelSettings, language: AppLanguage,
                now: Double, pilots: PilotDirectory = .empty) {
        self.origin = origin
        self.distances = distances
        self.settings = settings
        self.language = language
        self.now = now
        self.pilots = pilots
    }
}

/// 预警行的生成规则。
public enum IntelPresenter {
    /// 不足这么多秒是「新」。
    public static let freshSeconds = 120.0
    /// 不足这么多秒是「较新」。
    public static let recentSeconds = 300.0

    /// 按消息的年龄分档。
    public static func freshness(age: Double) -> IntelFreshness {
        if age < freshSeconds { return .fresh }
        if age < recentSeconds { return .recent }
        return .old
    }

    /// 一条消息的一行。
    public static func line(_ item: IntelItem, context: IntelPresentationContext, data: EVEStaticData,
                            formatter: any IntelLineFormatting) -> OverlayLine {
        let report = item.report
        guard report.isIntelLike else { return plainLine(item, now: context.now, formatter: formatter) }
        let settings = context.settings
        let resolved = PilotSegmenter.resolve(report, directory: context.pilots)
        var parts: [[OverlaySpan]] = [[ageSpan(item, now: context.now, formatter: formatter)]]
        var isAlert = false
        for systemID in report.systemIDs {
            guard let system = data.system(id: systemID) else { continue }
            let distance = JumpGraph.distance(to: systemID, table: context.distances, maxJumps: settings.maxJumps,
                                              in: data)
            if case .jumps(let jumps) = distance, settings.alertJumps > 0, jumps <= settings.alertJumps {
                isAlert = true
            }
            parts.append([systemSpan(system, language: context.language)])
            parts.append([OverlaySpan(formatter.jumps(distance), jumpStyle(distance, alertJumps: settings.alertJumps))])
        }
        if let count = resolved.hostileCount, count > 0 {
            parts.append([OverlaySpan(formatter.count(count, isExplicit: resolved.countIsExplicit), .count)])
        }
        for mention in report.ships {
            guard let name = shipName(mention.kind, data: data, language: context.language) else { continue }
            parts.append([OverlaySpan(mention.count > 1 ? "\(name)×\(mention.count)" : name, .ship)])
        }
        let pilotSpans = pilotSpans(resolved.pilots, showOriginal: settings.showOriginal)
        if !pilotSpans.isEmpty { parts.append(pilotSpans) }
        if report.isClear { parts.append([OverlaySpan(formatter.clear, .clear)]) }
        if report.isNoVisual { parts.append([OverlaySpan(formatter.noVisual, .noVisual)]) }

        var primary: [OverlaySpan] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { primary.append(OverlaySpan(" ", .plain)) }
            primary += part
        }
        let message = item.message
        let secondary = settings.showOriginal
            ? [OverlaySpan(message.speaker, .speaker), OverlaySpan(": " + message.text, .dim)]
            : []
        let emphasis: OverlayEmphasis = report.isClear ? .clear : (isAlert ? .alert : .none)
        let links = resolved.pilots.compactMap { pilot -> OverlayLink? in
            guard case .matched(let id) = pilot.status, id > 0 else { return nil }
            return OverlayLink(title: "\(pilot.name) · zKillboard", url: "https://zkillboard.com/character/\(id)/")
        }
        return OverlayLine(id: item.id, primary: primary, secondary: secondary, emphasis: emphasis,
                           copyText: copyText(message), links: links)
    }

    /// 不是情报的消息（或没有星图数据时）的一行：时间、说话人与原文，原文用 plain 样式，没有第二行。
    public static func plainLine(_ item: IntelItem, now: Double, formatter: any IntelLineFormatting) -> OverlayLine {
        let message = item.message
        let primary = [ageSpan(item, now: now, formatter: formatter), OverlaySpan(" ", .plain),
                       OverlaySpan(message.speaker, .speaker), OverlaySpan(": " + message.text, .plain)]
        return OverlayLine(id: item.id, primary: primary, copyText: copyText(message))
    }

    /// 下一次要按时间刷新的时刻：有不足 60 秒的消息时 now + 10；否则有消息时 now + 30；没有消息时 nil。
    public static func nextRefresh(items: [IntelItem], now: Double) -> Double? {
        guard !items.isEmpty else { return nil }
        return items.contains { now - $0.message.time < 60 } ? now + 10 : now + 30
    }

    // MARK: - 各部分

    /// 时间：不足 60 秒时向下取到 10 秒的倍数。
    static func ageSpan(_ item: IntelItem, now: Double, formatter: any IntelLineFormatting) -> OverlaySpan {
        let age = max(0, now - item.message.time)
        let whole = age.isFinite ? Int(min(age, 1e9)) : 0
        let seconds = whole < 60 ? whole / 10 * 10 : whole
        let style: OverlaySpanStyle
        switch freshness(age: age) {
        case .fresh: style = .ageFresh
        case .recent: style = .ageRecent
        case .old: style = .ageOld
        }
        return OverlaySpan(formatter.age(seconds: seconds), style)
    }

    /// 星系：名称加显示用的安全等级（虫洞星系不加）。
    static func systemSpan(_ system: SolarSystem, language: AppLanguage) -> OverlaySpan {
        let name = system.name(in: language)
        guard system.kind == .known, let security = system.displaySecurity else {
            return OverlaySpan(name, .systemUnknown)
        }
        let style: OverlaySpanStyle = security >= 0.5 ? .systemHigh : (security > 0 ? .systemLow : .systemNull)
        return OverlaySpan("\(name) \(String(format: "%.1f", security))", style)
    }

    /// 跳数的样式。
    static func jumpStyle(_ distance: JumpDistance, alertJumps: Int) -> OverlaySpanStyle {
        guard case .jumps(let jumps) = distance else { return .jumpsUnknown }
        guard alertJumps > 0 else { return .jumpsFar }
        if jumps <= alertJumps { return .jumpsNear }
        if jumps <= alertJumps * 2 { return .jumpsMid }
        return .jumpsFar
    }

    /// 舰船或舰船分组的名称。
    static func shipName(_ kind: TermKind, data: EVEStaticData, language: AppLanguage) -> String? {
        switch kind {
        case .ship(let typeID): data.ship(id: typeID)?.name(in: language)
        case .shipGroup(let groupID): data.shipGroup(id: groupID)?.name(in: language)
        default: nil
        }
    }

    /// 人名：查到的总是列出；未核对与没查到的只在不显示原文时列出，没查到的加「?」并用 dim。人名之间隔「 · 」。
    static func pilotSpans(_ pilots: [IntelPilot], showOriginal: Bool) -> [OverlaySpan] {
        var spans: [OverlaySpan] = []
        for pilot in pilots {
            let span: OverlaySpan
            switch pilot.status {
            case .matched:
                span = OverlaySpan(pilot.name, .pilot)
            case .unchecked where !showOriginal:
                span = OverlaySpan(pilot.name, .pilot)
            case .notFound where !showOriginal:
                span = OverlaySpan(pilot.name + "?", .dim)
            default:
                continue
            }
            if !spans.isEmpty { spans.append(OverlaySpan(" · ", .dim)) }
            spans.append(span)
        }
        return spans
    }

    /// 右键「复制」的文字：「[HH:mm:ss] 说话人 > 原文」，时间是 UTC。
    static func copyText(_ message: ChatMessage) -> String {
        let seconds = message.time.isFinite && abs(message.time) < 1e15 ? Int(message.time.rounded(.down)) : 0
        let day = ((seconds % 86_400) + 86_400) % 86_400
        let clock = String(format: "%02d:%02d:%02d", day / 3_600, day / 60 % 60, day % 60)
        return "[\(clock)] \(message.speaker) > \(message.text)"
    }
}
