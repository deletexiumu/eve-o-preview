// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跳数的测试（docs/design-intel-translate.md 6.6 节、14.1 节）。星门连接是夹具里编的：
// Jita — Perimeter — New Caldari — Urlen — Hek — Amarr，New Caldari — 1DQ1-A — T5ZI-S — HED-GP，
// Naga — EC-P8R 另成一块，Onsooh、Aunsou、Thera 没有星门。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct JumpGraphTests {
    typealias F = StaticDataFixtures
    /// 夹具的星图数据。
    private let data: EVEStaticData
    init() throws { data = try StaticDataFixtures.data() }

    /// 链上与支线上的跳数；出发星系是 0。
    @Test func chainAndBranch() {
        let table = JumpGraph.distances(from: F.jita, maxJumps: 15, in: data)
        #expect(table[F.jita] == 0)
        #expect(table[F.perimeter] == 1)
        #expect(table[F.amarr] == 5)
        #expect(table[F.oneDQ] == 3)
        #expect(table[F.hedGP] == 5)
        #expect(table.count == 9)
    }

    /// maxJumps 截断。
    @Test func limit() {
        let table = JumpGraph.distances(from: F.jita, maxJumps: 2, in: data)
        #expect(table.keys.sorted() == [F.jita, F.perimeter, F.newCaldari].sorted())
        #expect(JumpGraph.distance(to: F.amarr, table: table, maxJumps: 2, in: data) == .beyond(limit: 2))
        #expect(JumpGraph.distances(from: F.jita, maxJumps: 0, in: data) == [F.jita: 0])
    }

    /// distance 的 4 种结果。
    @Test func distanceKinds() {
        let table = JumpGraph.distances(from: F.jita, maxJumps: 15, in: data)
        #expect(JumpGraph.distance(to: F.hek, table: table, maxJumps: 15, in: data) == .jumps(4))
        #expect(JumpGraph.distance(to: F.jita, table: table, maxJumps: 15, in: data) == .jumps(0))
        // 不相连的星系：有星门，但不在同一块里。
        #expect(JumpGraph.distance(to: F.nagaSystem, table: table, maxJumps: 15, in: data) == .beyond(limit: 15))
        // 没有星门的星系与虫洞星系。
        #expect(JumpGraph.distance(to: F.onsooh, table: table, maxJumps: 15, in: data) == .unreachable)
        #expect(JumpGraph.distance(to: F.thera, table: table, maxJumps: 15, in: data) == .unreachable)
        #expect(JumpGraph.distance(to: F.hek, table: nil, maxJumps: 15, in: data) == .unknownOrigin)
    }
}
