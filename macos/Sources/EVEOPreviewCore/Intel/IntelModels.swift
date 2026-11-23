// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的解析结果（docs/design-intel-translate.md 6.4 节）：把一条消息分成星系、舰船、人数、情报用语、
// 推断的人名与普通文字几段，并汇总出星系、舰船数量、人名与敌对数量。由 IntelParser 产出，WP-0 冻结。

import Foundation

/// 一段文字的种类。
public enum IntelSegmentKind: Sendable, Equatable {
    /// 星系。
    case system(id: Int)
    /// 星域。
    case region(id: Int)
    /// 舰船。
    case ship(typeID: Int)
    /// 舰船分组。
    case shipGroup(groupID: Int)
    /// 情报用语。
    case word(IntelWord)
    /// 人数，关联值是数值。
    case count(Int)
    /// 推断的人名。
    case pilot
    /// 普通文字与空白。
    case plain
}

/// 原文里的一段。各段依次拼起来就是原文。
public struct IntelSegment: Sendable, Equatable {
    /// 原文里的这一段。
    public var text: String
    /// 种类。
    public var kind: IntelSegmentKind

    /// 用文字与种类建一段。
    public init(text: String, kind: IntelSegmentKind) {
        self.text = text
        self.kind = kind
    }
}

/// 消息里提到的一艘舰船或一个舰船分组。
public struct IntelShipMention: Sendable, Equatable {
    /// `.ship` 或 `.shipGroup`。
    public var kind: TermKind
    /// 归给它的数量；没写数量时是 1。
    public var count: Int

    /// 用种类与数量建一项。
    public init(kind: TermKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// 一条消息的解析结果。
public struct IntelReport: Sendable, Equatable {
    /// 分好的各段。
    public var segments: [IntelSegment]
    /// 星系 ID，去重，按出现顺序。
    public var systemIDs: [Int]
    /// 舰船与数量。
    public var ships: [IntelShipMention]
    /// 推断的人名。
    public var pilots: [String]
    /// 敌对数量；nil 表示判断不出。
    public var hostileCount: Int?
    /// 数量来自消息里写明的数字。
    public var countIsExplicit: Bool
    /// 消息里有「安全」一类的用语。
    public var isClear: Bool
    /// 消息里有「未见」一类的用语。
    public var isNoVisual: Bool

    /// 用各字段建一个结果。
    public init(segments: [IntelSegment], systemIDs: [Int] = [], ships: [IntelShipMention] = [],
                pilots: [String] = [], hostileCount: Int? = nil, countIsExplicit: Bool = false,
                isClear: Bool = false, isNoVisual: Bool = false) {
        self.segments = segments
        self.systemIDs = systemIDs
        self.ships = ships
        self.pilots = pilots
        self.hostileCount = hostileCount
        self.countIsExplicit = countIsExplicit
        self.isClear = isClear
        self.isNoVisual = isNoVisual
    }

    /// 认出了星系或舰船（含舰船分组），可以当作一条情报。
    public var isIntelLike: Bool { !systemIDs.isEmpty || !ships.isEmpty }

    /// 什么也没认出、也没有文字的结果。
    public static let empty = IntelReport(segments: [])

    /// 什么也没认出的结果：全文是一段 plain（空文字时没有段）。
    public static func plain(_ text: String) -> IntelReport {
        IntelReport(segments: text.isEmpty ? [] : [IntelSegment(text: text, kind: .plain)])
    }
}
