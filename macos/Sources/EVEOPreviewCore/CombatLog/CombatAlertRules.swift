// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒的规则（反馈文档 7.7 节）：
// - events：一次读取里一个文件至多产生两条受击事件（伤害最大的一条与未命中各一条），其他种类不上报。
//   数字为 0 的命中按未命中对待，不会被同批里较小的正数伤害盖住。
// - triggers：按配置决定一条受击事件是否提醒。
// - extended：持续受击时提醒一直延长，startedAt 不变；到期后再受击重新开始。
// 时间都是协调器在主线程读的单调时钟秒数，不用日志行里的时间（日志时间是 UTC 的整秒）。

import Foundation

/// 战斗提醒的规则。
public enum CombatAlertRules {
    /// 把一次读取得到的各行归类结果合并成至多两条事件。
    ///
    /// 有 `incomingDamage` 时上报其中数字最大的一条；有 `incomingMiss` 时另外上报一条。两种各自上报，
    /// 所以「一次小于阈值的伤害加一次未命中」仍能按未命中触发提醒。
    /// 数字为 0 的命中属于未命中一类：同批里有正数伤害时，另报一条 `incomingMiss`，否则 0 会被较大的数字盖住；
    /// 同批里没有正数伤害时，上报的伤害事件本身就是 `incomingDamage(0)`，由 `triggers` 按未命中处理。
    public static func events(for listener: String, kinds: [CombatLineKind]) -> [CombatLogEvent] {
        var maxDamage: Int?
        var sawMiss = false
        var sawZeroHit = false
        for kind in kinds {
            switch kind {
            case .incomingDamage(let amount):
                maxDamage = max(maxDamage ?? amount, amount)
                if amount == 0 { sawZeroHit = true }
            case .incomingMiss:
                sawMiss = true
            case .outgoingDamage, .outgoingMiss, .otherCombat, .other:
                break
            }
        }
        var events: [CombatLogEvent] = []
        if let maxDamage {
            events.append(CombatLogEvent(character: listener, kind: .incomingDamage(amount: maxDamage)))
        }
        // 最大伤害为 0 时，伤害事件已经代表这些 0 命中，不必再报一条未命中。
        if sawMiss || (sawZeroHit && (maxDamage ?? 0) > 0) {
            events.append(CombatLogEvent(character: listener, kind: .incomingMiss))
        }
        return events
    }

    /// 一条受击事件是否提醒。
    ///
    /// | 种类 | 条件 |
    /// | --- | --- |
    /// | `incomingDamage(amount)` | `amount >= minimumDamage` |
    /// | `incomingDamage(0)` | `includeMisses` 为真（数字为 0 的命中按未命中对待） |
    /// | `incomingMiss` | `includeMisses` 为真 |
    /// | 其他 | 不提醒 |
    public static func triggers(_ kind: CombatLineKind, settings: CombatAlertSettings) -> Bool {
        switch kind {
        case .incomingDamage(let amount):
            if amount >= settings.minimumDamage { return true }
            return amount == 0 && settings.includeMisses
        case .incomingMiss:
            return settings.includeMisses
        case .outgoingDamage, .outgoingMiss, .otherCombat, .other:
            return false
        }
    }

    /// 收到一条会提醒的事件后，窗口的新提醒时段。
    ///
    /// `existing` 未到期（`now < until`）时保留 `startedAt`，`until` 取原值与 `now + duration` 中较大的一个，
    /// 不会缩短；否则从 `now` 重新开始。
    public static func extended(_ existing: CombatAlertWindow?, now: Double, duration: Double) -> CombatAlertWindow {
        if let existing, existing.isActive(at: now) {
            return CombatAlertWindow(startedAt: existing.startedAt, until: max(existing.until, now + duration))
        }
        return CombatAlertWindow(startedAt: now, until: now + duration)
    }
}
