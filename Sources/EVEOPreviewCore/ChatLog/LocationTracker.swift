// SPDX-License-Identifier: GPL-3.0-or-later
//
// 角色位置的记录（docs/design-intel-translate.md 6.2 节）。位置有两个自动来源（Local 聊天日志的系统消息、
// 游戏日志的跳跃与离站记录）与手动设置；不知道角色位置时，跳数从参考星系算。
// CharacterLocation 与 LocationSource 由 WP-0 建在 ChatLogModels.swift（ChatState 引用它们），规则在这里。
//
// apply 的规则：
// 1. 按线索的来源用 LocationLineParser 取星系名，再用 data.system(named:) 查星系。
// 2. 取不到或查不到时兜底：对正文做术语匹配，取最后一个种类是星系的匹配（应对表以外语言的句式，V32）。
// 3. 仍没有结果时不改任何记录。
// 4. 角色的键先原样比较，没有时再不区分大小写比较（CharacterNameMatch）。
// 5. 补读的线索只在没有记录、或时间晚于记录时写入；运行中的线索直接写入，不比较时间
//    （日志时间来自游戏，手动设置的时间来自本机时钟，两者可能差几秒）。
// 6. 写入（星系，线索的时间，来源）；星系与来源都没变时返回假（时间仍更新）。

import Foundation

/// 跳数的出发点。
public enum LocationOrigin: Sendable, Equatable {
    /// 角色有位置记录。
    case character(CharacterLocation)
    /// 角色没有位置，用参考星系。
    case reference(systemID: Int)
    /// 都没有。
    case unknown

    /// 出发星系的 ID；unknown 时为 nil。
    public var systemID: Int? {
        switch self {
        case .character(let location): location.systemID
        case .reference(let systemID): systemID
        case .unknown: nil
        }
    }
}

/// 各角色的位置记录。
public struct LocationTracker: Sendable, Equatable {
    /// 角色名 → 位置。
    public private(set) var locations: [String: CharacterLocation]
    /// 参考星系；不知道角色位置时跳数从它算。
    public var referenceSystemID: Int?

    /// 用 state.json 里的手动位置与参考星系建记录。
    public init(manual: [String: CharacterLocation] = [:], referenceSystemID: Int? = nil) {
        locations = manual
        self.referenceSystemID = referenceSystemID
    }

    /// 把一条位置线索解析成星系并记下，返回位置（星系或来源）是否变了。
    @discardableResult
    public mutating func apply(_ hint: LocationHint, data: EVEStaticData) -> Bool {
        guard let systemID = LocationTracker.resolveSystem(hint, data: data) else { return false }
        let source: LocationSource = hint.source == .localChannel ? .localChannel : .gameLog
        let key = CharacterNameMatch.key(for: hint.character, in: locations) ?? hint.character
        let current = locations[key]
        if hint.isBackfill, let current, hint.time <= current.time { return false }
        locations[key] = CharacterLocation(systemID: systemID, time: hint.time, source: source)
        return current?.systemID != systemID || current?.source != source
    }

    /// 手动设置位置：systemID 为 nil 时删掉这个角色的记录；否则写入（星系，now，手动）。返回记录是否变了。
    @discardableResult
    public mutating func setManual(character: String, systemID: Int?, now: Double) -> Bool {
        let key = CharacterNameMatch.key(for: character, in: locations)
        guard let systemID else {
            guard let key else { return false }
            locations[key] = nil
            return true
        }
        let record = CharacterLocation(systemID: systemID, time: now, source: .manual)
        let current = key.flatMap { locations[$0] }
        locations[key ?? character] = record
        return current?.systemID != systemID || current?.source != .manual
    }

    /// 跳数的出发点：角色有记录时是它的位置；否则有参考星系时是参考星系；都没有时是 unknown。
    public func origin(for character: String?) -> LocationOrigin {
        if let character, let location = CharacterNameMatch.value(for: character, in: locations) {
            return .character(location)
        }
        if let referenceSystemID { return .reference(systemID: referenceSystemID) }
        return .unknown
    }

    /// 要写进 state.json 的手动位置：来源是 manual 的记录。
    public var manualLocations: [String: CharacterLocation] {
        locations.filter { $0.value.source == .manual }
    }

    /// 线索里的星系：先按句式取名称再查星系，取不到时取正文里最后一个星系。
    static func resolveSystem(_ hint: LocationHint, data: EVEStaticData) -> Int? {
        let name: String?
        switch hint.source {
        case .localChannel: name = LocationLineParser.systemName(fromLocalSystemLine: hint.text)
        case .gameLog: name = LocationLineParser.systemName(fromGameNote: hint.text)
        }
        if let name, let system = data.system(named: name) { return system.id }
        let systems = data.matcher.matches(in: hint.text).compactMap { match -> Int? in
            if case .system(let id) = match.kind { return id }
            return nil
        }
        return systems.last
    }
}
