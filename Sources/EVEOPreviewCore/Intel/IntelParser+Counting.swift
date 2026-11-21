// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的汇总（docs/design-intel-translate.md 6.4 节「舰船的数量与敌对数量」）：由分好的段算出星系、
// 舰船与数量、人名、敌对数量与两个用语标志。
//
// 数量的归属：
// 1. 人数与它前面最近的非 plain 段之间只有空白、且那一段是还没有数量的舰船或舰船分组时，归给那艘船。
//    「还没有数量」是 WP-B 补的条件：`2 Naga 3 Machariel` 里的 3 应归给 Machariel（R31 把这种写法列为能认对的）。
// 2. 否则，写法是 `3`、`3x`、`3×`，且它后面最近的非 plain 段是还没有数量的舰船或舰船分组、中间只有空白时，归给后面那艘船。
// 3. 其余是独立人数。
// 敌对数量：甲是各船数量之和，乙是独立人数里最大的，丙是人名个数。isClear 且甲、丙都是 0 时是 0；
// 否则取三者最大，最大是 0 时为 nil。取最大不相加：同一批敌对常常既写人名又写船型。

import Foundation

extension IntelParser {
    /// 由分好的段算出解析结果。countForms 与段里的 count 一一对应，按出现顺序。
    static func summarize(_ segments: [IntelSegment], countForms: [CountForm]) -> IntelReport {
        // 非 plain 段的下标，以及相邻两个非 plain 段之间是否只有空白。
        let marked = segments.indices.filter { segments[$0].kind != .plain }
        func onlySpaceBetween(_ left: Int, _ right: Int) -> Bool {
            guard left < right else { return false }
            return segments[(left + 1)..<right].allSatisfy { segment in
                segment.kind == .plain && segment.text.allSatisfy(\.isWhitespace)
            }
        }
        // 每个舰船段归到的数量；独立人数。
        var shipCounts: [Int: Int] = [:]
        var independent: [Int] = []
        var formIndex = 0
        for (position, index) in marked.enumerated() {
            guard case .count(let value) = segments[index].kind else { continue }
            let form = formIndex < countForms.count ? countForms[formIndex] : .other
            formIndex += 1
            if position > 0 {
                let previous = marked[position - 1]
                if segments[previous].kind.isShip, shipCounts[previous] == nil, onlySpaceBetween(previous, index) {
                    shipCounts[previous] = value
                    continue
                }
            }
            if form == .leading, position + 1 < marked.count {
                let next = marked[position + 1]
                if segments[next].kind.isShip, shipCounts[next] == nil, onlySpaceBetween(index, next) {
                    shipCounts[next] = value
                    continue
                }
            }
            independent.append(value)
        }

        var systemIDs: [Int] = []
        var ships: [IntelShipMention] = []
        var pilots: [String] = []
        var isClear = false
        var isNoVisual = false
        for (index, segment) in segments.enumerated() {
            switch segment.kind {
            case .system(let id) where !systemIDs.contains(id):
                systemIDs.append(id)
            case .ship(let typeID):
                ships.append(IntelShipMention(kind: .ship(typeID: typeID), count: shipCounts[index] ?? 1))
            case .shipGroup(let groupID):
                ships.append(IntelShipMention(kind: .shipGroup(groupID: groupID), count: shipCounts[index] ?? 1))
            case .pilot:
                pilots.append(segment.text)
            case .word(.clear):
                isClear = true
            case .word(.noVisual):
                isNoVisual = true
            default:
                break
            }
        }

        let shipTotal = ships.reduce(0) { $0 + $1.count }
        let independentMax = independent.max() ?? 0
        let pilotCount = pilots.count
        var hostileCount: Int?
        var countIsExplicit = false
        if isClear, shipTotal == 0, pilotCount == 0 {
            hostileCount = 0
        } else {
            let best = max(shipTotal, independentMax, pilotCount)
            hostileCount = best == 0 ? nil : best
            countIsExplicit = best > 0 && ((best == independentMax && independentMax > 0)
                || (best == shipTotal && !shipCounts.isEmpty))
        }
        return IntelReport(segments: segments, systemIDs: systemIDs, ships: ships, pilots: pilots,
                           hostileCount: hostileCount, countIsExplicit: countIsExplicit,
                           isClear: isClear, isNoVisual: isNoVisual)
    }
}
