// SPDX-License-Identifier: GPL-3.0-or-later
//
// 星图数据文件 eve-static.json 的结构（docs/design-intel-translate.md 4.2 节）。文件由 scripts/build-sde-data.py
// 从 CCP 的 SDE 生成，键名用短键以减小文件：i 是 ID，n 是英文名，l 是与英文不同的其他语言名称，
// s 是安全等级，r 是星域 ID，g 是舰船分组 ID。键名与 JSON 相同，用合成的 Codable。
// 读到不认识的 format 时按「数据无效」处理，见 EVEStaticData.decode。

import Foundation

/// eve-static.json 的顶层结构。
public struct StaticDataFile: Sendable, Equatable, Codable {
    /// 带名称的记录：星域与舰船分组。
    public struct Named: Sendable, Equatable, Codable {
        /// ID。
        public var i: Int
        /// 英文名。
        public var n: String
        /// 与英文不同的其他语言名称，键是语言代码（与 AppLanguage 的原始值相同）；没有时为 nil。
        public var l: [String: String]?

        /// 用各字段建一条记录。
        public init(i: Int, n: String, l: [String: String]? = nil) {
            self.i = i
            self.n = n
            self.l = l
        }
    }

    /// 一个星系。
    public struct System: Sendable, Equatable, Codable {
        /// 星系 ID。
        public var i: Int
        /// 英文名。
        public var n: String
        /// 与英文不同的其他语言名称。
        public var l: [String: String]?
        /// 安全等级，3 位小数；SDE 里缺失时为 nil。
        public var s: Double?
        /// 星域 ID；SDE 里缺失时为 nil。
        public var r: Int?

        /// 用各字段建一个星系。
        public init(i: Int, n: String, l: [String: String]? = nil, s: Double? = nil, r: Int? = nil) {
            self.i = i
            self.n = n
            self.l = l
            self.s = s
            self.r = r
        }
    }

    /// 一艘舰船（一个已发布的舰船类型）。
    public struct Ship: Sendable, Equatable, Codable {
        /// 舰船类型 ID。
        public var i: Int
        /// 舰船分组 ID。
        public var g: Int
        /// 英文名。
        public var n: String
        /// 与英文不同的其他语言名称。
        public var l: [String: String]?

        /// 用各字段建一艘舰船。
        public init(i: Int, g: Int, n: String, l: [String: String]? = nil) {
            self.i = i
            self.g = g
            self.n = n
            self.l = l
        }
    }

    /// 应用认识的文件格式版本。
    public static let currentFormat = 1

    /// 文件格式的版本，结构变化时加 1。
    public var format: Int
    /// 生成时用的 SDE 版本号（buildNumber）。
    public var sdeBuild: Int
    /// SDE 的发布时刻（ISO 8601）；用 `--build` 生成旧版本时可能缺失。
    public var sdeReleaseDate: String?
    /// 全部星域。
    public var regions: [Named]
    /// 已知空间与虫洞空间的星系。
    public var systems: [System]
    /// 星门连接，每项是两个星系 ID，小的在前。
    public var jumps: [[Int]]
    /// 已发布的舰船分组。
    public var shipGroups: [Named]
    /// 已发布的舰船。
    public var ships: [Ship]

    /// 用各字段建一份数据，测试夹具用。
    public init(format: Int = StaticDataFile.currentFormat, sdeBuild: Int, sdeReleaseDate: String? = nil,
                regions: [Named], systems: [System], jumps: [[Int]], shipGroups: [Named], ships: [Ship]) {
        self.format = format
        self.sdeBuild = sdeBuild
        self.sdeReleaseDate = sdeReleaseDate
        self.regions = regions
        self.systems = systems
        self.jumps = jumps
        self.shipGroups = shipGroups
        self.ships = ships
    }
}
