// SPDX-License-Identifier: GPL-3.0-or-later
//
// 测试用的小份星图数据（docs/macos/design-intel-translate.md 14.1 节）。经 StaticDataFile 的 JSON 解码得到，
// 名称、ID 与安全等级取自 SDE 3720952；星门连接是这里编的，与游戏的星图无关。三个并行的工作包只读不改。
//
// 内容：
// - 一条链：Jita（吉他）— Perimeter — New Caldari — Urlen — Hek — Amarr。
// - 一条支线：New Caldari — 1DQ1-A — T5ZI-S — HED-GP，这 3 个星系没有译名。
// - 另一个连通块：Naga（纳伽，0.034）— EC-P8R。Naga 与舰船同名。
// - 没有星门的 Onsooh 与 Aunsou，日文名都是 オンスー（S7）。
// - 虫洞星系 Thera（席拉）。
// - 星域 The Forge（伏尔戈）与 Heimatar。
// - 舰船分组 Frigate、Interdictor、Interceptor、Logistics；10 艘舰船，Naga、Crow、Stabber 另带日文与韩文名称。

import Foundation
import EVEOPreviewCore

/// 测试用的星图数据。
enum StaticDataFixtures {
    // MARK: 星系 ID

    /// 链上的星系。
    static let jita = 30_000_142
    static let perimeter = 30_000_144
    static let newCaldari = 30_000_145
    static let urlen = 30_000_139
    static let hek = 30_002_053
    static let amarr = 30_002_187
    /// 支线上的星系。
    static let oneDQ = 30_004_759
    static let t5zi = 30_004_735
    static let hedGP = 30_001_161
    /// 另一个连通块。
    static let nagaSystem = 30_004_300
    static let ecP8R = 30_001_984
    /// 没有星门的两个星系，日文名相同。
    static let onsooh = 30_000_013
    static let aunsou = 30_003_801
    /// 虫洞星系。
    static let thera = 31_000_005

    // MARK: 星域、分组与舰船 ID

    /// 星域。
    static let theForge = 10_000_002
    static let heimatar = 10_000_030
    /// 舰船分组。
    static let frigateGroup = 25
    static let interdictorGroup = 541
    static let interceptorGroup = 831
    static let logisticsGroup = 832
    /// 舰船。
    static let nagaShip = 4_306
    static let nagaNavyIssue = 95_630
    static let sabre = 22_456
    static let rapier = 11_963
    static let crow = 11_176
    static let stabber = 622
    static let astarte = 22_466
    static let machariel = 17_738
    static let rifter = 587
    static let vexorNavyIssue = 17_843

    /// 数据文件的 JSON 文本，格式与 shared/static/eve-static.json 相同。
    static let json = """
    {"format":1,"sdeBuild":3720952,"sdeReleaseDate":"2026-11-19T11:07:08Z",
    "regions":[{"i":10000002,"n":"The Forge","l":{"zh":"伏尔戈"}},{"i":10000030,"n":"Heimatar","l":{"zh":"西玛特尔"}}],
    "systems":[
    {"i":30000013,"n":"Onsooh","l":{"ja":"オンスー"},"s":0.443,"r":10000001},
    {"i":30000139,"n":"Urlen","l":{"zh":"乌尔仑"},"s":0.949,"r":10000002},
    {"i":30000142,"n":"Jita","l":{"zh":"吉他"},"s":0.946,"r":10000002},
    {"i":30000144,"n":"Perimeter","l":{"zh":"皮尔米特"},"s":0.949,"r":10000002},
    {"i":30000145,"n":"New Caldari","l":{"zh":"新加达里"},"s":0.949,"r":10000002},
    {"i":30001161,"n":"HED-GP","s":-0.146,"r":10000014},
    {"i":30001984,"n":"EC-P8R","s":-0.447,"r":10000023},
    {"i":30002053,"n":"Hek","l":{"zh":"赫克"},"s":0.8,"r":10000042},
    {"i":30002187,"n":"Amarr","l":{"zh":"艾玛"},"s":0.949,"r":10000043},
    {"i":30003801,"n":"Aunsou","l":{"ja":"オンスー"},"s":0.183,"r":10000048},
    {"i":30004300,"n":"Naga","l":{"zh":"纳伽"},"s":0.034,"r":10000054},
    {"i":30004735,"n":"T5ZI-S","s":-0.143,"r":10000060},
    {"i":30004759,"n":"1DQ1-A","s":-0.386,"r":10000060},
    {"i":31000005,"n":"Thera","l":{"zh":"席拉"},"s":-0.99,"r":11000031}],
    "jumps":[[30000139,30000145],[30000139,30002053],[30000142,30000144],[30000144,30000145],
    [30000145,30004759],[30001161,30004735],[30001984,30004300],[30002053,30002187],[30004735,30004759]],
    "shipGroups":[{"i":25,"n":"Frigate","l":{"zh":"护卫舰"}},{"i":541,"n":"Interdictor","l":{"zh":"拦截舰"}},
    {"i":831,"n":"Interceptor","l":{"zh":"截击舰"}},{"i":832,"n":"Logistics","l":{"zh":"后勤舰"}}],
    "ships":[
    {"i":587,"g":25,"n":"Rifter","l":{"zh":"裂谷级"}},
    {"i":622,"g":26,"n":"Stabber","l":{"zh":"刺客级","ja":"スタッバー","ko":"스태버"}},
    {"i":4306,"g":1201,"n":"Naga","l":{"zh":"娜迦级","ja":"ナーガ","ko":"나가"}},
    {"i":11176,"g":831,"n":"Crow","l":{"zh":"黑鸦级","ja":"クロウ","ko":"크로우"}},
    {"i":11963,"g":833,"n":"Rapier","l":{"zh":"长剑级"}},
    {"i":17738,"g":27,"n":"Machariel","l":{"zh":"马克瑞级"}},
    {"i":17843,"g":26,"n":"Vexor Navy Issue","l":{"zh":"狂怒者级海军型"}},
    {"i":22456,"g":541,"n":"Sabre","l":{"zh":"剑齿虎级"}},
    {"i":22466,"g":540,"n":"Astarte","l":{"zh":"阿施塔特级"}},
    {"i":95630,"g":1201,"n":"Naga Navy Issue","l":{"zh":"娜迦级海军型"}}]}
    """

    /// 解码出的文件结构。
    static func file() throws -> StaticDataFile {
        try JSONDecoder().decode(StaticDataFile.self, from: Data(json.utf8))
    }

    /// 解码出的星图数据。夹具是合法的，解码失败说明解码规则坏了。
    static func data() throws -> EVEStaticData {
        try EVEStaticData.decode(Data(json.utf8))
    }
}
