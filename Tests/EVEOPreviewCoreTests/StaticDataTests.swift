// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVEStaticData 的用例（docs/design-intel-translate.md 4.3 节、14.1 节），用 StaticDataFixtures 的小份数据。

import Foundation
import Testing
import EVEOPreviewCore

/// 星图数据：解码、按名称找星系、重名、搜索、显示用的安全等级与译名。
struct StaticDataTests {
    /// 夹具解码后各类数量正确，舰船与分组分开查。
    @Test func fixtureCounts() throws {
        let data = try StaticDataFixtures.data()
        #expect(data.sdeBuild == 3_720_952)
        #expect(data.systems.count == 14)
        #expect(data.ships.filter { $0.groupID != nil }.count == 10)
        #expect(data.ships.filter { $0.groupID == nil }.count == 4)
        #expect(data.ship(id: StaticDataFixtures.sabre)?.groupID == StaticDataFixtures.interdictorGroup)
        #expect(data.shipGroup(id: StaticDataFixtures.interceptorGroup)?.name == "Interceptor")
        #expect(data.ship(id: StaticDataFixtures.interceptorGroup) == nil)
        #expect(data.system(id: StaticDataFixtures.thera)?.kind == .wormhole)
        #expect(data.system(id: StaticDataFixtures.jita)?.kind == .known)
        #expect(data.regionName(id: StaticDataFixtures.theForge, in: .zh) == "伏尔戈")
        #expect(data.regionName(id: StaticDataFixtures.heimatar, in: .ru) == "Heimatar")
        #expect(data.regionName(id: 1, in: .en) == nil)
    }

    /// 邻接表双向建立；没有星门的星系没有邻居。
    @Test func neighbors() throws {
        let data = try StaticDataFixtures.data()
        #expect(data.neighbors(of: StaticDataFixtures.newCaldari)
                == [StaticDataFixtures.urlen, StaticDataFixtures.perimeter, StaticDataFixtures.oneDQ])
        #expect(data.neighbors(of: StaticDataFixtures.jita) == [StaticDataFixtures.perimeter])
        #expect(data.neighbors(of: StaticDataFixtures.onsooh).isEmpty)
        #expect(data.neighbors(of: StaticDataFixtures.thera).isEmpty)
    }

    /// format 不认识时抛 unsupportedFormat；没有星系时抛 empty；JSON 坏了抛 unreadable。
    @Test func errors() throws {
        let newer = StaticDataFixtures.json.replacingOccurrences(of: #"{"format":1"#, with: #"{"format":2"#)
        #expect(throws: StaticDataError.unsupportedFormat(found: 2)) {
            try EVEStaticData.decode(Data(newer.utf8))
        }
        var file = try StaticDataFixtures.file()
        file.systems = []
        #expect(throws: StaticDataError.empty) { try EVEStaticData(file: file) }
        #expect(throws: StaticDataError.self) { try EVEStaticData.decode(Data("not json".utf8)) }
        do {
            _ = try EVEStaticData.decode(Data(#"{"format":1}"#.utf8))
            Issue.record("缺字段的文件应解码失败")
        } catch {
            guard case .unreadable = error else { Issue.record("应为 unreadable：\(error)"); return }
        }
    }

    /// system(named:) 认英文、中文、带 `*`、大小写不同、带首尾空白的写法。
    @Test func systemByName() throws {
        let data = try StaticDataFixtures.data()
        #expect(data.system(named: "Jita")?.id == StaticDataFixtures.jita)
        #expect(data.system(named: "吉他")?.id == StaticDataFixtures.jita)
        #expect(data.system(named: "吉他*")?.id == StaticDataFixtures.jita)
        #expect(data.system(named: "  jITA ** ")?.id == StaticDataFixtures.jita)
        #expect(data.system(named: "hed-gp")?.id == StaticDataFixtures.hedGP)
        #expect(data.system(named: "") == nil)
        #expect(data.system(named: "*") == nil)
        #expect(data.system(named: "Nowhere") == nil)
    }

    /// 日文名相同的 Onsooh 与 Aunsou：取 ID 小的 Onsooh（两个都是已知空间）。
    @Test func duplicateNamePrefersLowerID() throws {
        let data = try StaticDataFixtures.data()
        #expect(data.system(named: "オンスー")?.id == StaticDataFixtures.onsooh)
        #expect(data.system(named: "Aunsou")?.id == StaticDataFixtures.aunsou)
    }

    /// 已知空间与虫洞空间重名时取已知空间。种类由 ID 决定，虫洞星系的 ID 总是更大，
    /// 所以这条与「取 ID 小的」结果一致；用例只确认虫洞星系不会盖掉已知空间的名称。
    @Test func duplicateNamePrefersKnownSpace() throws {
        var file = try StaticDataFixtures.file()
        file.systems.append(StaticDataFile.System(i: 31_000_001, n: "Shadow", l: ["zh": "回声"]))
        file.systems.append(StaticDataFile.System(i: 30_009_999, n: "Echo", l: ["zh": "回声"]))
        let data = try EVEStaticData(file: file)
        #expect(data.system(named: "回声")?.id == 30_009_999)
    }

    /// searchSystems：完全相同的排最前，其余按名称长度；遵守 limit。
    @Test func search() throws {
        let data = try StaticDataFixtures.data()
        let names = data.searchSystems(prefix: "naga", limit: 5).map(\.name)
        #expect(names == ["Naga"])
        var file = try StaticDataFixtures.file()
        file.systems.append(StaticDataFile.System(i: 30_009_998, n: "Jitana"))
        file.systems.append(StaticDataFile.System(i: 30_009_997, n: "Jit"))
        let extended = try EVEStaticData(file: file)
        #expect(extended.searchSystems(prefix: "jit", limit: 10).map(\.name) == ["Jit", "Jita", "Jitana"])
        #expect(extended.searchSystems(prefix: "JITA", limit: 10).map(\.name) == ["Jita", "Jitana"])
        #expect(extended.searchSystems(prefix: "jit", limit: 2).count == 2)
        #expect(extended.searchSystems(prefix: "吉", limit: 10).map(\.name) == ["Jita"])
        #expect(extended.searchSystems(prefix: " ", limit: 10).isEmpty)
    }

    /// 显示用的安全等级：0.034 显示 0.1，0.05 显示 0.1，0.449 显示 0.4，-0.386 显示 -0.4，0.946 显示 0.9。
    @Test func displaySecurity() throws {
        let data = try StaticDataFixtures.data()
        #expect(data.system(id: StaticDataFixtures.nagaSystem)?.displaySecurity == 0.1)
        #expect(data.system(id: StaticDataFixtures.oneDQ)?.displaySecurity == -0.4)
        #expect(data.system(id: StaticDataFixtures.jita)?.displaySecurity == 0.9)
        func shown(_ value: Double?) -> Double? { SolarSystem(id: 1, name: "X", security: value, kind: .known).displaySecurity }
        #expect(shown(0.05) == 0.1)
        #expect(shown(0.449) == 0.4)
        #expect(shown(0.0) == 0)
        #expect(shown(-0.04) == 0)
        #expect(shown(nil) == nil)
    }

    /// name(in:) 有译名时取译名，没有时回到英文。
    @Test func localizedNames() throws {
        let data = try StaticDataFixtures.data()
        let jita = try #require(data.system(id: StaticDataFixtures.jita))
        #expect(jita.name(in: .zh) == "吉他")
        #expect(jita.name(in: .ja) == "Jita")
        #expect(data.system(id: StaticDataFixtures.t5zi)?.name(in: .zh) == "T5ZI-S")
        let crow = try #require(data.ship(id: StaticDataFixtures.crow))
        #expect(crow.name(in: .ko) == "크로우" && crow.name(in: .de) == "Crow")
    }

    /// 文件结构往返一致：l、s、r 缺失时编码里也省略。
    @Test func fileRoundTrip() throws {
        let file = try StaticDataFixtures.file()
        let again = try JSONDecoder().decode(StaticDataFile.self, from: JSONEncoder().encode(file))
        #expect(again == file)
        let hed = try #require(file.systems.first { $0.n == "HED-GP" })
        let json = try #require(String(data: JSONEncoder().encode(hed), encoding: .utf8))
        #expect(!json.contains("\"l\""))
    }
}
