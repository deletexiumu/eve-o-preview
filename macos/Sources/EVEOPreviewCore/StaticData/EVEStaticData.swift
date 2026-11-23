// SPDX-License-Identifier: GPL-3.0-or-later
//
// 解码后的星图数据（docs/macos/design-intel-translate.md 4.3 节）：星系、星域、舰船与舰船分组的名称，星门的邻接表，
// 以及按名称查星系的索引与术语匹配器。建一次，在本次运行内不变，可在任何线程读。
//
// 规则：
// - name(in:)：localized[语言代码] 有值时取它，否则取英文名。
// - 星系的种类：ID 小于 31,000,000 是已知空间，否则是虫洞空间。
// - system(named:) 的索引：英文名与 localized 里的每个名称转小写作键。同一个键对应多个星系时（S7），
//   取已知空间的；仍有多个时取 ID 最小的。
// - neighbors(of:) 的邻接表由 jumps 双向建立。

import Foundation

/// 星图数据读不了的原因。
public enum StaticDataError: Error, Sendable, Equatable {
    /// JSON 解不开，关联值是系统给的说明。
    case unreadable(String)
    /// 不认识的文件格式版本。
    case unsupportedFormat(found: Int)
    /// 没有星系。
    case empty

    /// 写进系统日志的名字：只有种类与格式版本，不含 unreadable 的说明（说明可能含文件路径）。
    public var logName: String {
        switch self {
        case .unreadable: "unreadable"
        case .unsupportedFormat(let found): "unsupportedFormat(\(found))"
        case .empty: "empty"
        }
    }
}

/// 星系所在的空间。
public enum SpaceKind: Sendable, Equatable {
    /// 已知空间（ID 小于 31,000,000）。
    case known
    /// 虫洞空间。
    case wormhole
}

/// 一个星系。
public struct SolarSystem: Sendable, Equatable, Identifiable {
    /// 星系 ID。
    public var id: Int
    /// 英文名。
    public var name: String
    /// 与英文不同的其他语言名称，键是语言代码。
    public var localized: [String: String]
    /// 安全等级（3 位小数）；没有时为 nil。
    public var security: Double?
    /// 星域 ID。
    public var regionID: Int?
    /// 已知空间或虫洞空间。
    public var kind: SpaceKind

    /// 用各字段建一个星系。
    public init(id: Int, name: String, localized: [String: String] = [:], security: Double? = nil,
                regionID: Int? = nil, kind: SpaceKind) {
        self.id = id
        self.name = name
        self.localized = localized
        self.security = security
        self.regionID = regionID
        self.kind = kind
    }

    /// 某种语言下的名称；没有译名时取英文名。
    public func name(in language: AppLanguage) -> String {
        localized[language.rawValue] ?? name
    }

    /// 游戏里显示的安全等级：大于 0 且小于 0.05 时显示 0.1，其余四舍五入到一位小数。
    public var displaySecurity: Double? {
        guard let security else { return nil }
        if security > 0, security < 0.05 { return 0.1 }
        // 先乘 10 再取整，再除回去；-0.0 写成 0.0。
        let rounded = (security * 10).rounded() / 10
        return rounded == 0 ? 0 : rounded
    }
}

/// 一艘舰船或一个舰船分组的名称。
public struct ShipName: Sendable, Equatable {
    /// 舰船类型 ID，或舰船分组 ID（groupID 为 nil 时）。
    public var id: Int
    /// 舰船所属的分组 ID；nil 表示这一项本身是一个舰船分组。
    public var groupID: Int?
    /// 英文名。
    public var name: String
    /// 与英文不同的其他语言名称。
    public var localized: [String: String]

    /// 用各字段建一项。
    public init(id: Int, groupID: Int?, name: String, localized: [String: String] = [:]) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.localized = localized
    }

    /// 某种语言下的名称；没有译名时取英文名。
    public func name(in language: AppLanguage) -> String {
        localized[language.rawValue] ?? name
    }
}

/// 解码后的星图数据。
public struct EVEStaticData: Sendable {
    /// 生成数据时用的 SDE 版本号。
    public let sdeBuild: Int
    /// 全部星系，按 ID 排序。
    public let systems: [SolarSystem]
    /// 舰船与舰船分组，先舰船后分组，各按 ID 排序。
    public let ships: [ShipName]
    /// 术语匹配器，用全部星系、星域、舰船与舰船分组建立（6.3 节）。
    public let matcher: TermMatcher

    /// 星系 ID → 在 systems 里的下标。
    private let systemIndex: [Int: Int]
    /// 小写的名称（任一语言）→ 星系 ID。
    private let systemsByName: [String: Int]
    /// 星域 ID → 星域。
    private let regions: [Int: StaticDataFile.Named]
    /// 舰船类型 ID → 舰船。
    private let shipsByID: [Int: ShipName]
    /// 舰船分组 ID → 分组。
    private let groupsByID: [Int: ShipName]
    /// 星系 ID → 相邻的星系 ID（升序）。
    private let adjacency: [Int: [Int]]

    /// 由文件结构建数据。format 不认识时抛 `unsupportedFormat`，没有星系时抛 `empty`。
    public init(file: StaticDataFile) throws(StaticDataError) {
        guard file.format == StaticDataFile.currentFormat else {
            throw .unsupportedFormat(found: file.format)
        }
        guard !file.systems.isEmpty else { throw .empty }
        sdeBuild = file.sdeBuild
        let systems = file.systems.sorted { $0.i < $1.i }.map { record in
            SolarSystem(id: record.i, name: record.n, localized: record.l ?? [:], security: record.s,
                        regionID: record.r, kind: record.i < 31_000_000 ? .known : .wormhole)
        }
        self.systems = systems
        var index: [Int: Int] = [:]
        for (offset, system) in systems.enumerated() { index[system.id] = offset }
        systemIndex = index
        systemsByName = EVEStaticData.nameIndex(systems)
        regions = Dictionary(file.regions.map { ($0.i, $0) }, uniquingKeysWith: { first, _ in first })
        let shipList = file.ships.sorted { $0.i < $1.i }.map {
            ShipName(id: $0.i, groupID: $0.g, name: $0.n, localized: $0.l ?? [:])
        }
        let groupList = file.shipGroups.sorted { $0.i < $1.i }.map {
            ShipName(id: $0.i, groupID: nil, name: $0.n, localized: $0.l ?? [:])
        }
        ships = shipList + groupList
        shipsByID = Dictionary(shipList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupsByID = Dictionary(groupList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var neighbors: [Int: Set<Int>] = [:]
        for pair in file.jumps where pair.count == 2 && pair[0] != pair[1] {
            neighbors[pair[0], default: []].insert(pair[1])
            neighbors[pair[1], default: []].insert(pair[0])
        }
        adjacency = neighbors.mapValues { $0.sorted() }
        matcher = TermMatcher(systems: systems, regions: file.regions.sorted { $0.i < $1.i },
                              ships: shipList + groupList)
    }

    /// 解码 eve-static.json 的内容。先只读 format，不认识时抛 `unsupportedFormat`，不去解后面可能已变的结构。
    public static func decode(_ data: Data) throws(StaticDataError) -> EVEStaticData {
        /// 只含 format 的外壳。
        struct Header: Decodable { var format: Int? }
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
        guard let format = header.format else { throw .unreadable("missing format") }
        guard format == StaticDataFile.currentFormat else { throw .unsupportedFormat(found: format) }
        let file: StaticDataFile
        do {
            file = try decoder.decode(StaticDataFile.self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
        return try EVEStaticData(file: file)
    }

    // MARK: - 查询

    /// 按 ID 找星系。
    public func system(id: Int) -> SolarSystem? {
        systemIndex[id].map { systems[$0] }
    }

    /// 按任一语言的名称找星系。先去掉首尾空白与末尾的 `*`，比较不区分大小写。
    public func system(named name: String) -> SolarSystem? {
        let key = EVEStaticData.lookupKey(name)
        guard !key.isEmpty, let id = systemsByName[key] else { return nil }
        return system(id: id)
    }

    /// 名称（任一语言）以 prefix 开头的星系，至多 limit 个；给设置界面的星系输入框用。
    ///
    /// 比较不区分大小写。排序：名称与 prefix 完全相同的在最前，其余按匹配到的名称从短到长、再按英文名、再按 ID。
    public func searchSystems(prefix: String, limit: Int) -> [SolarSystem] {
        let key = EVEStaticData.lookupKey(prefix)
        guard !key.isEmpty, limit > 0 else { return [] }
        var found: [(system: SolarSystem, exact: Bool, length: Int)] = []
        for system in systems {
            let names = [system.name] + system.localized.values.sorted()
            let hits = names.map { $0.lowercased() }.filter { $0.hasPrefix(key) }
            guard let shortest = hits.min(by: { $0.count < $1.count }) else { continue }
            found.append((system, hits.contains(key), shortest.count))
        }
        found.sort { a, b in
            if a.exact != b.exact { return a.exact }
            if a.length != b.length { return a.length < b.length }
            if a.system.name != b.system.name { return a.system.name < b.system.name }
            return a.system.id < b.system.id
        }
        return found.prefix(limit).map(\.system)
    }

    /// 星域在某种语言下的名称；没有这个星域时返回 nil。
    public func regionName(id: Int, in language: AppLanguage) -> String? {
        guard let region = regions[id] else { return nil }
        return region.l?[language.rawValue] ?? region.n
    }

    /// 按舰船类型 ID 找舰船。
    public func ship(id: Int) -> ShipName? {
        shipsByID[id]
    }

    /// 按舰船分组 ID 找分组。
    public func shipGroup(id: Int) -> ShipName? {
        groupsByID[id]
    }

    /// 与某个星系有星门相连的星系 ID，升序；没有星门时为空。
    public func neighbors(of systemID: Int) -> [Int] {
        adjacency[systemID] ?? []
    }

    // MARK: - 内部

    /// 查名称用的键：去掉首尾空白与末尾的 `*`（中文客户端在译名后加 `*`），转小写。
    static func lookupKey(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("*") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 建名称索引：同一个键对应多个星系时，已知空间优先，再取 ID 小的。
    private static func nameIndex(_ systems: [SolarSystem]) -> [String: Int] {
        var index: [String: SolarSystem] = [:]
        for system in systems {
            for name in [system.name] + Array(system.localized.values) {
                let key = name.lowercased()
                guard !key.isEmpty else { continue }
                if let current = index[key], !prefers(system, over: current) { continue }
                index[key] = system
            }
        }
        return index.mapValues(\.id)
    }

    /// 重名时 candidate 是否比 current 更该留下：已知空间优先，同种空间取 ID 小的。
    private static func prefers(_ candidate: SolarSystem, over current: SolarSystem) -> Bool {
        if candidate.kind != current.kind { return candidate.kind == .known }
        return candidate.id < current.id
    }
}
