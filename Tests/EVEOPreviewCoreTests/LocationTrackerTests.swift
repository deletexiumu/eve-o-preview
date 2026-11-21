// SPDX-License-Identifier: GPL-3.0-or-later
//
// 位置记录的测试（docs/design-intel-translate.md 6.2 节、14.1 节）。角色名是虚构的；
// 线索的正文按 5.6 节的句式写，星系取自 StaticDataFixtures。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct LocationTrackerTests {
    typealias F = StaticDataFixtures
    /// 夹具的星图数据。
    private let data: EVEStaticData
    init() throws { data = try StaticDataFixtures.data() }

    /// 一条线索。
    private func hint(_ text: String, source: LocationHintSource = .gameLog, time: Double = 100,
                      character: String = "Kael Doran", backfill: Bool = false) -> LocationHint {
        LocationHint(character: character, time: time, source: source, text: text, isBackfill: backfill)
    }

    /// Local 的系统消息与游戏日志的跳跃记录各自生效。
    @Test func bothSourcesApply() {
        var tracker = LocationTracker()
        do { let changed = tracker.apply(hint("Channel changed to Local : Jita", source: .localChannel), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"] == CharacterLocation(systemID: F.jita, time: 100, source: .localChannel))
        do { let changed = tracker.apply(hint("从吉他*跳到皮尔米特*", time: 110), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.perimeter)
        #expect(tracker.locations["Kael Doran"]?.source == .gameLog)
        do { let changed = tracker.apply(hint("正在从 某空间站* 离站进入 赫克* 恒星系。", time: 120), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.hek)
    }

    /// 星系与来源都没变时返回假，但时间更新。
    @Test func unchangedReturnsFalse() {
        var tracker = LocationTracker()
        tracker.apply(hint("从吉他*跳到赫克*", time: 100), data: data)
        do { let changed = tracker.apply(hint("从吉他*跳到赫克*", time: 200), data: data); #expect(!changed) }
        #expect(tracker.locations["Kael Doran"]?.time == 200)
    }

    /// 补读的线索只在没有记录或时间更晚时写入；运行中的线索不比较时间。
    @Test func backfillOnlyWhenNewer() {
        var tracker = LocationTracker()
        tracker.apply(hint("从吉他*跳到赫克*", time: 200), data: data)
        do { let changed = tracker.apply(hint("从吉他*跳到艾玛*", time: 150, backfill: true), data: data); #expect(!changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.hek)
        do { let changed = tracker.apply(hint("从吉他*跳到艾玛*", time: 250, backfill: true), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.amarr)
        // 运行中的线索时间更早也写入。
        do { let changed = tracker.apply(hint("从吉他*跳到乌尔仑*", time: 10), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.urlen)
    }

    /// 手动位置被之后的线索覆盖；setManual(nil) 删除；manualLocations 只含手动的记录。
    @Test func manualLocations() {
        var tracker = LocationTracker(manual: ["Kael Doran": CharacterLocation(systemID: F.jita, time: 50,
                                                                               source: .manual)])
        #expect(tracker.manualLocations.count == 1)
        do { let changed = tracker.setManual(character: "Mira Voss", systemID: F.hek, now: 60); #expect(changed) }
        do { let changed = tracker.setManual(character: "MIRA VOSS", systemID: F.hek, now: 70); #expect(!changed) }
        #expect(tracker.manualLocations.keys.sorted() == ["Kael Doran", "Mira Voss"])
        tracker.apply(hint("从吉他*跳到艾玛*", time: 80), data: data)
        #expect(tracker.manualLocations.keys.sorted() == ["Mira Voss"])
        do { let changed = tracker.setManual(character: "mira voss", systemID: nil, now: 90); #expect(changed) }
        do { let changed = tracker.setManual(character: "Mira Voss", systemID: nil, now: 90); #expect(!changed) }
        #expect(tracker.manualLocations.isEmpty)
    }

    /// 补读的线索与恢复出来的手动位置按时间取新的。
    @Test func backfillVersusRestoredManual() {
        var tracker = LocationTracker(manual: ["Kael Doran": CharacterLocation(systemID: F.jita, time: 500,
                                                                               source: .manual)])
        do { let changed = tracker.apply(hint("从吉他*跳到赫克*", time: 400, backfill: true), data: data); #expect(!changed) }
        #expect(tracker.locations["Kael Doran"]?.source == .manual)
    }

    /// 句式不认识时取正文末尾的星系；星系名查不到时不改记录。
    @Test func fallbackAndUnknown() {
        var tracker = LocationTracker()
        do { let changed = tracker.apply(hint("Прыжок из Jita в Perimeter"), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.perimeter)
        // 目的星系名查不到：认得出的吉他不在正文末尾，不用这条线索，位置不变。
        do { let changed = tracker.apply(hint("从吉他*跳到不存在*", time: 200), data: data); #expect(!changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.perimeter)
        var empty = LocationTracker()
        do { let changed = empty.apply(hint("Jumping from Nowhere to Elsewhere"), data: data); #expect(!changed) }
        #expect(empty.locations.isEmpty)
    }

    /// 兜底的两个条件：最后一个星系后面只剩空白或标点；正文里至多 2 个星系。
    @Test func fallbackConditions() {
        var tracker = LocationTracker()
        do { let changed = tracker.apply(hint("Saut de Jita vers Hek."), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.hek)
        do { let changed = tracker.apply(hint("Sprung nach Amarr！ ", time: 110), data: data); #expect(changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.amarr)
        // 星系后面还有别的词：不用。
        do { let changed = tracker.apply(hint("Jita gate camp", time: 120), data: data); #expect(!changed) }
        // 3 个星系：不用（多半是一句闲聊或情报，不是跳跃记录）。
        do { let changed = tracker.apply(hint("Jita Hek Urlen", time: 130), data: data); #expect(!changed) }
        #expect(tracker.locations["Kael Doran"]?.systemID == F.amarr)
    }

    /// 角色名先原样比较，再不区分大小写比较。
    @Test func characterKeyFallback() {
        var tracker = LocationTracker()
        tracker.apply(hint("从吉他*跳到赫克*", character: "Kael Doran"), data: data)
        tracker.apply(hint("从吉他*跳到艾玛*", time: 200, character: "KAEL DORAN"), data: data)
        #expect(tracker.locations.count == 1)
        #expect(tracker.origin(for: "kael doran").systemID == F.amarr)
    }

    /// origin 的 3 种结果。
    @Test func origins() {
        var tracker = LocationTracker(referenceSystemID: nil)
        #expect(tracker.origin(for: "Kael Doran") == .unknown)
        #expect(tracker.origin(for: nil) == .unknown)
        tracker.referenceSystemID = F.amarr
        #expect(tracker.origin(for: "Kael Doran") == .reference(systemID: F.amarr))
        tracker.apply(hint("从吉他*跳到赫克*"), data: data)
        #expect(tracker.origin(for: "Kael Doran")
                == .character(CharacterLocation(systemID: F.hek, time: 100, source: .gameLog)))
        #expect(tracker.origin(for: nil) == .reference(systemID: F.amarr))
        #expect(LocationOrigin.unknown.systemID == nil)
    }
}
