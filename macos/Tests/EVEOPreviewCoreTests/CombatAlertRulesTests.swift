// SPDX-License-Identifier: GPL-3.0-or-later
//
// CombatAlertRules 的用例（反馈文档 7.7 节、10.1 节）：事件的合并、触发表与 minimumDamage 的边界、提醒的延长。

import Testing
import EVEOPreviewCore

/// 战斗提醒的规则。
struct CombatAlertRulesTests {
    /// 默认设置：最小伤害 1，未命中也提醒。
    private let defaults = CombatAlertSettings()

    // MARK: - 事件的合并

    /// 一次读取里只上报伤害最大的一条与一条未命中；其他种类不上报。
    @Test func eventsCoalesced() {
        let kinds: [CombatLineKind] = [
            .incomingDamage(amount: 12), .outgoingDamage(amount: 900), .incomingDamage(amount: 87),
            .incomingMiss, .incomingMiss, .incomingDamage(amount: 3), .otherCombat, .other, .outgoingMiss,
        ]
        #expect(CombatAlertRules.events(for: "Aurora Vale", kinds: kinds) == [
            CombatLogEvent(character: "Aurora Vale", kind: .incomingDamage(amount: 87)),
            CombatLogEvent(character: "Aurora Vale", kind: .incomingMiss),
        ])
    }

    /// 只有己方的行或非战斗行时没有事件；只有未命中时只有一条。
    @Test func eventsOnlyForIncoming() {
        #expect(CombatAlertRules.events(for: "X", kinds: [.outgoingDamage(amount: 5), .other, .otherCombat]).isEmpty)
        #expect(CombatAlertRules.events(for: "X", kinds: [.incomingMiss])
                == [CombatLogEvent(character: "X", kind: .incomingMiss)])
        #expect(CombatAlertRules.events(for: "X", kinds: [.incomingDamage(amount: 0)])
                == [CombatLogEvent(character: "X", kind: .incomingDamage(amount: 0))])
    }

    // MARK: - 触发表

    /// 触发表的每一行。
    @Test func triggerTable() {
        #expect(CombatAlertRules.triggers(.incomingDamage(amount: 1), settings: defaults))
        #expect(CombatAlertRules.triggers(.incomingDamage(amount: 0), settings: defaults))
        #expect(CombatAlertRules.triggers(.incomingMiss, settings: defaults))
        #expect(!CombatAlertRules.triggers(.outgoingDamage(amount: 500), settings: defaults))
        #expect(!CombatAlertRules.triggers(.outgoingMiss, settings: defaults))
        #expect(!CombatAlertRules.triggers(.otherCombat, settings: defaults))
        #expect(!CombatAlertRules.triggers(.other, settings: defaults))
    }

    /// 关掉未命中后：未命中与数字为 0 的伤害都不提醒，正常伤害照常提醒。
    @Test func missesDisabled() {
        var settings = defaults
        settings.includeMisses = false
        #expect(!CombatAlertRules.triggers(.incomingMiss, settings: settings))
        #expect(!CombatAlertRules.triggers(.incomingDamage(amount: 0), settings: settings))
        #expect(CombatAlertRules.triggers(.incomingDamage(amount: 1), settings: settings))
    }

    /// minimumDamage 的边界：等于阈值提醒，小于阈值不提醒（数字为 0 仍按未命中处理）。
    @Test func minimumDamageBoundary() {
        var settings = defaults
        settings.minimumDamage = 100
        #expect(CombatAlertRules.triggers(.incomingDamage(amount: 100), settings: settings))
        #expect(!CombatAlertRules.triggers(.incomingDamage(amount: 99), settings: settings))
        #expect(CombatAlertRules.triggers(.incomingDamage(amount: 0), settings: settings))
        settings.includeMisses = false
        #expect(!CombatAlertRules.triggers(.incomingDamage(amount: 0), settings: settings))
    }

    // MARK: - 延长

    /// 没有旧提醒时从 now 开始。
    @Test func extendedStartsFresh() {
        #expect(CombatAlertRules.extended(nil, now: 10, duration: 3) == CombatAlertWindow(startedAt: 10, until: 13))
    }

    /// 未到期时保留 startedAt 并延长。
    @Test func extendedWhileActive() {
        let existing = CombatAlertWindow(startedAt: 10, until: 13)
        #expect(CombatAlertRules.extended(existing, now: 12, duration: 3) == CombatAlertWindow(startedAt: 10, until: 15))
    }

    /// until 不会缩短：时长调短后再受击，仍保留原来较晚的到期时刻。
    @Test func extendedNeverShortens() {
        let existing = CombatAlertWindow(startedAt: 10, until: 20)
        #expect(CombatAlertRules.extended(existing, now: 11, duration: 1) == CombatAlertWindow(startedAt: 10, until: 20))
    }

    /// 到期后（now >= until）再受击，重新开始。
    @Test func extendedAfterExpiry() {
        let existing = CombatAlertWindow(startedAt: 10, until: 13)
        #expect(CombatAlertRules.extended(existing, now: 13, duration: 3) == CombatAlertWindow(startedAt: 13, until: 16))
    }
}
