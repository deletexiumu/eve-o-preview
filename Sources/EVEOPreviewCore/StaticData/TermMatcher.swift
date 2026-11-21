// SPDX-License-Identifier: GPL-3.0-or-later
//
// 术语匹配（docs/design-intel-translate.md 6.3 节）：在聊天正文里找星系、星域、舰船、舰船分组与情报用语。
// 类型由 WP-0 冻结；索引的建立与扫描规则归 WP-B。
// WP-0 的空实现：matches(in:) 返回空数组。消息仍然显示，只是不认星系与舰船；翻译照常，只是不钉术语。

import Foundation

/// 情报用语。
public enum IntelWord: String, Sendable, Equatable {
    /// 安全（clr、clear）。
    case clear
    /// 未见（nv、no visual）。
    case noVisual
}

/// 一个术语的种类。
public enum TermKind: Sendable, Equatable {
    /// 星系。
    case system(id: Int)
    /// 星域。
    case region(id: Int)
    /// 舰船（舰船类型 ID）。
    case ship(typeID: Int)
    /// 舰船分组。
    case shipGroup(groupID: Int)
    /// 情报用语。
    case intelWord(IntelWord)
}

/// 正文里的一处术语。
public struct TermMatch: Sendable, Equatable {
    /// 在原文里的范围，含名称后面的 `*`。
    public var range: Range<String.Index>
    /// 种类。
    public var kind: TermKind
    /// 英文名；情报用语是它的规范写法。
    public var english: String
    /// 与英文不同的其他语言名称，键是语言代码。
    public var localized: [String: String]

    /// 用各字段建一处匹配。
    public init(range: Range<String.Index>, kind: TermKind, english: String, localized: [String: String]) {
        self.range = range
        self.kind = kind
        self.english = english
        self.localized = localized
    }

    /// 某种语言下的名称；没有译名时取英文名。
    public func name(in language: AppLanguage) -> String {
        localized[language.rawValue] ?? english
    }
}

/// 术语匹配器。由 `EVEStaticData` 在解码时建立，之后只读。
public struct TermMatcher: Sendable {
    /// 用全部星系、星域、舰船与舰船分组建索引。WP-0 的空实现不建索引。
    public init(systems: [SolarSystem], regions: [StaticDataFile.Named], ships: [ShipName]) {}

    /// 文字里出现的术语，按位置排序，互不重叠。WP-0 的空实现返回空数组。
    public func matches(in text: String) -> [TermMatch] {
        []
    }
}
