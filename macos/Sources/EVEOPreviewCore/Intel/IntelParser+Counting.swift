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
// 敌对数量：甲是各船数量之和，乙是独立人数里最大的，丙是人名个数。isClear、甲与丙都是 0、且消息里没有人数时是 0；
// 否则取三者最大，最大是 0 时为 nil。取最大不相加：同一批敌对常常既写人名又写船型。
// isClear（审查后补充）：有「安全」用语，且这个用语不是否定或疑问时才为真：
// - 前面 3 个词里有 not、no、never 或以 n't 结尾的词时不算（`Jita not clear`、`not yet clr`、`no longer clear`、
//   `never clr`，复审 N1）。只往回看到前一个不是普通文字的段（星系、舰船、人数、人名、用语）为止，
//   遇到以 `.`、`;`、`!`、`。`、`；`、`！` 结尾的词（上一句）也停；逗号不算句子结束；
// - 用语后面紧跟 `?` 或 `？`（中间可有空白），或整条消息以 `?`、`？` 结尾（`Amarr clear?`）时不算。

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
            case .word(.clear) where !isNegatedOrQuestion(segments, at: index):
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
        if isClear, shipTotal == 0, pilotCount == 0, independent.isEmpty, shipCounts.isEmpty {
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

    /// 往回看几个词找否定词。
    static let negationLookBack = 3

    /// 第 index 段的「安全」用语是否被否定或是疑问：前面至多 3 个普通词里有否定词（见文件头）；
    /// 用语后面（跳过空白）紧跟 `?`、`？`；或整条消息去掉末尾空白后以 `?`、`？` 结尾。
    static func isNegatedOrQuestion(_ segments: [IntelSegment], at index: Int) -> Bool {
        let before = segments[..<index].map(\.text).joined()
        let after = segments[(index + 1)...].map(\.text).joined()
        let questionMarks: Set<Character> = ["?", "？"]
        if let next = after.first(where: { !$0.isWhitespace }), questionMarks.contains(next) { return true }
        if let last = (before + segments[index].text + after).last(where: { !$0.isWhitespace }),
           questionMarks.contains(last) {
            return true
        }
        // 紧挨在前面的普通文字（相邻的 plain 已并成一段，所以至多一段）。
        guard index > 0, segments[index - 1].kind == .plain else { return false }
        var words = segments[index - 1].text.split(whereSeparator: \.isWhitespace).map(String.init)
        // 上一句结束的词及它前面的词不看。
        if let end = words.lastIndex(where: { word in word.last.map { ".;!。；！".contains($0) } ?? false }) {
            words.removeFirst(end + 1)
        }
        // 去掉两端不是字母的字符（保留中间的撇号），转成小写。
        let lowered = words.suffix(negationLookBack).map { raw in
            String(raw.drop(while: { !$0.isLetter }).reversed().drop(while: { !$0.isLetter }).reversed()).lowercased()
        }
        return lowered.indices.contains { i in
            let lower = lowered[i]
            // 「no reds clr」「no hostiles clr」里的 no 否定的是敌对，整句仍是安全，不算否定。
            if lower == "no", i + 1 < lowered.count, hostileNouns.contains(lowered[i + 1]) { return false }
            return ["not", "no", "never"].contains(lower) || lower.hasSuffix("n't") || lower.hasSuffix("n’t")
        }
    }

    /// 跟在 no 后面时表示「没有敌对」的名词：这时 no 不否定后面的安全用语。
    static let hostileNouns: Set<String> = [
        "red", "reds", "hostile", "hostiles", "neut", "neuts", "enemy", "enemies", "one", "contacts", "spike",
    ]
}
