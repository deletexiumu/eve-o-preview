// SPDX-License-Identifier: GPL-3.0-or-later
//
// 术语匹配（docs/design-intel-translate.md 6.3 节）：在聊天正文里找星系、星域、舰船、舰船分组与情报用语。
// 类型由 WP-0 冻结；索引的建立与扫描规则归 WP-B（本文件的 TermMatcher）。
//
// 索引：每个术语的每个名称（英文名与各语言名称）各建一个键。含汉字、假名或谚文的名称建「字符键」（原样，
// 2 个字符以上）；其余名称建「词键」（切成小写的词，用一个空格连接）。舰船缩写、情报用语另建键。
// 同一个键对应多个术语时，按「舰船、舰船分组、星域、星系、情报用语」的顺序取第一个；星系之间重名时
// 已知空间优先，再取 ID 小的（同 EVEStaticData.system(named:)）。
//
// 扫描：先在每个汉字、假名、谚文的位置上试最长的字符键；再在剩下的文字里取词，从每个词起试连续的 1～6 个词
// （两个词之间只隔一个空格或引号才算连续），最长的先试；查不到时把最后一个词的 es 或 s 去掉再查。
// 只有一个词的匹配另有两条限制（6.3 节第 4、5 条），见 passesSingleWordRules。匹配后紧跟的 `*` 并入范围。
//
// 字符键的边界（6.3 节扫描第 1 条，审查后补充）：字符键本身不看边界，以下两类另有要求，见 passesBoundary。
// - 中文情报用语（安全、无人）：前面 2 个字符里没有「不、非、未、没、沒」，后面不紧跟汉字、假名或谚文。
//   「不安全」「不太安全」「没有安全」「无人机」「安全等级」因此不认作「安全」（往回看 2 个字符：复审 N1）；
//   「非常」不算否定，「非常安全」仍认作「安全」。
// - commonWordLocalizedNames 里的译名（是日常中文词的星系与星域名，如 Exit 的「出口」、Cache 的「地窖」）：
//   后面紧跟 `*`，或前后都不紧挨汉字、假名、谚文时才算匹配。只看这张表，按键判断（复审 R1）：
//   「皮尔米特」这类音译名照常不看边界。
//
// 6.3 节第 5 条（3 个以内的 ASCII 字母、或在 ambiguousShortNames 里的词要首字母大写或带 `*`）的三处例外：
// - 情报用语不受限（6.4 节样例 `HED-GP* clr` 要认出 `clr`）。
// - 舰船缩写表的词不受限（`dic`、`hic`、`hac`、`fax`、`vni` 在情报里多以小写写出，缩写表专为它们而设）。
// - 舰船与舰船分组不受限（`moa`、`nyx`、`eos` 在情报里常以小写写出）。命中的键在 caseSensitiveShipNames
//   （`sin`、`imp`、`ark`）或 ambiguousShortNames（与星域同名的 `Curse`）里时仍受限。

import Foundation

/// 情报用语。
public enum IntelWord: String, Sendable, Equatable {
    /// 安全（clr、clear）。
    case clear
    /// 未见（nv、no visual）。
    case noVisual
}

/// 一个术语的种类。
public enum TermKind: Sendable, Equatable {
    /// 星系。
    case system(id: Int)
    /// 星域。
    case region(id: Int)
    /// 舰船（舰船类型 ID）。
    case ship(typeID: Int)
    /// 舰船分组。
    case shipGroup(groupID: Int)
    /// 情报用语。
    case intelWord(IntelWord)
}

/// 正文里的一处术语。
public struct TermMatch: Sendable, Equatable {
    /// 在原文里的范围，含名称后面的 `*`。
    public var range: Range<String.Index>
    /// 种类。
    public var kind: TermKind
    /// 英文名；情报用语是它的规范写法。
    public var english: String
    /// 与英文不同的其他语言名称，键是语言代码。
    public var localized: [String: String]

    /// 用各字段建一处匹配。
    public init(range: Range<String.Index>, kind: TermKind, english: String, localized: [String: String]) {
        self.range = range
        self.kind = kind
        self.english = english
        self.localized = localized
    }

    /// 某种语言下的名称；没有译名时取英文名。
    public func name(in language: AppLanguage) -> String {
        localized[language.rawValue] ?? english
    }
}

/// 术语匹配器。由 `EVEStaticData` 在解码时建立，之后只读，可在任何线程使用。
public struct TermMatcher: Sendable {
    /// 索引里的一项。
    struct Entry: Sendable {
        /// 种类。
        var kind: TermKind
        /// 英文名；情报用语是它的规范写法。
        var english: String
        /// 其他语言的名称。
        var localized: [String: String]
        /// 重名时的先后：舰船 0、舰船分组 1、星域 2、星系 3、情报用语 4，小的优先。
        var rank: Int
        /// 星系是否在已知空间；其他种类为假。
        var isKnownSpace: Bool
        /// 术语的 ID，同种类重名时取小的。
        var id: Int
        /// 这个键来自舰船缩写表；不受扫描第 5 条的限制。
        var isAlias: Bool
        /// 作为字符键匹配时的边界要求。
        var boundary: CharacterBoundary = .none

        /// 是舰船或舰船分组。
        var isShipKind: Bool {
            switch kind {
            case .ship, .shipGroup: true
            default: false
            }
        }
    }

    /// 字符键的边界要求（文件头的「字符键的边界」）。
    enum CharacterBoundary: Sendable {
        /// 不看边界。
        case none
        /// 中文情报用语：前面不是否定字，后面不紧跟汉字、假名或谚文。
        case intelWord
        /// 是日常词的星系与星域的译名：后面紧跟 `*`，或前后都不紧挨汉字、假名或谚文。
        case commonWord
    }

    /// 一个词在原文里的位置（字符下标，左闭右开）。
    private struct Word {
        var start: Int
        var end: Int
        /// 小写形式。
        var lower: String
        /// 原文的首字符。
        var first: Character
    }

    /// 至多看几个连续的词。
    static let maxTermWords = 6

    /// 字符键（小写）→ 术语。
    private let characterKeys: [String: Entry]
    /// 字符键的首字符（小写）→ 以它开头的字符键的长度，从长到短。
    private let characterKeyLengths: [Character: [Int]]
    /// 词键 → 术语。
    private let wordKeys: [String: Entry]

    /// 用全部星系、星域、舰船与舰船分组建索引，另收舰船缩写与情报用语。
    public init(systems: [SolarSystem], regions: [StaticDataFile.Named], ships: [ShipName]) {
        var builder = IndexBuilder()
        for ship in ships {
            let kind: TermKind = ship.groupID == nil ? .shipGroup(groupID: ship.id) : .ship(typeID: ship.id)
            let entry = Entry(kind: kind, english: ship.name, localized: ship.localized,
                              rank: ship.groupID == nil ? 1 : 0, isKnownSpace: false, id: ship.id, isAlias: false)
            builder.add(names: [ship.name] + ship.localized.values.sorted(), entry: entry)
        }
        for region in regions {
            let entry = Entry(kind: .region(id: region.i), english: region.n, localized: region.l ?? [:], rank: 2,
                              isKnownSpace: false, id: region.i, isAlias: false)
            builder.add(names: [region.n] + (region.l ?? [:]).values.sorted(), entry: entry)
        }
        for system in systems {
            let entry = Entry(kind: .system(id: system.id), english: system.name, localized: system.localized,
                              rank: 3, isKnownSpace: system.kind == .known, id: system.id, isAlias: false)
            builder.add(names: [system.name] + system.localized.values.sorted(), entry: entry)
        }
        TermMatcher.addAliases(to: &builder, ships: ships)
        TermMatcher.addIntelWords(to: &builder)
        characterKeys = builder.characterKeys
        wordKeys = builder.wordKeys
        var lengths: [Character: Set<Int>] = [:]
        for key in builder.characterKeys.keys {
            guard let first = key.first else { continue }
            lengths[first, default: []].insert(key.count)
        }
        characterKeyLengths = lengths.mapValues { $0.sorted(by: >) }
    }

    /// 文字里出现的术语，按位置排序，互不重叠。
    public func matches(in text: String) -> [TermMatch] {
        guard !characterKeys.isEmpty || !wordKeys.isEmpty, !text.isEmpty else { return [] }
        let characters = Array(text)
        // 字符下标 → 原文的 String.Index，多一项是 endIndex。范围都换回原文的下标，翻译按它切原文。
        var indices: [String.Index] = []
        indices.reserveCapacity(characters.count + 1)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            indices.append(cursor)
            cursor = text.index(after: cursor)
        }
        indices.append(text.endIndex)
        var covered = [Bool](repeating: false, count: characters.count)
        var found: [(start: Int, end: Int, entry: Entry)] = []
        scanCharacterKeys(characters, covered: &covered, found: &found)
        scanWordKeys(characters, covered: &covered, found: &found)
        found.sort { $0.start < $1.start }
        return found.map { item in
            TermMatch(range: indices[item.start]..<indices[item.end], kind: item.entry.kind,
                      english: item.entry.english, localized: item.entry.localized)
        }
    }

    // MARK: - 扫描

    /// 扫描第 1 步：在每个汉字、假名或谚文的位置上试最长的字符键，匹配后跳到匹配的末尾。
    /// 不满足边界要求的键跳过，接着试更短的键；都不行时这个位置不算匹配，也不盖住。
    private func scanCharacterKeys(_ characters: [Character], covered: inout [Bool],
                                   found: inout [(start: Int, end: Int, entry: Entry)]) {
        var index = 0
        while index < characters.count {
            guard IntelLexicon.isCJK(characters[index]),
                  let first = String(characters[index]).lowercased().first,
                  let lengths = characterKeyLengths[first] else {
                index += 1
                continue
            }
            var matchedEnd: Int?
            for length in lengths where index + length <= characters.count {
                let key = String(characters[index..<(index + length)]).lowercased()
                guard let entry = characterKeys[key],
                      TermMatcher.passesBoundary(entry.boundary, characters, start: index, end: index + length)
                else { continue }
                let end = TermMatcher.extendOverStars(characters, from: index + length, covered: covered)
                found.append((index, end, entry))
                matchedEnd = end
                break
            }
            if let end = matchedEnd {
                for position in index..<end { covered[position] = true }
                index = end
            } else {
                index += 1
            }
        }
    }

    /// 扫描第 2～5 步：在没被字符键盖住的文字里取词，从每个词起试连续的 1～6 个词，最长的先试。
    private func scanWordKeys(_ characters: [Character], covered: inout [Bool],
                              found: inout [(start: Int, end: Int, entry: Entry)]) {
        let words = TermMatcher.words(in: characters, covered: covered)
        guard !words.isEmpty else { return }
        // linked[i]：第 i 个词与第 i+1 个词之间只隔一个空格或一个引号。
        var linked = [Bool](repeating: false, count: words.count)
        for i in 0..<(words.count - 1) {
            let gap = words[i + 1].start - words[i].end
            linked[i] = gap == 1 && !covered[words[i].end] && IntelLexicon.isWordLink(characters[words[i].end])
        }
        var i = 0
        while i < words.count {
            var runLength = 1
            while runLength < TermMatcher.maxTermWords, i + runLength < words.count, linked[i + runLength - 1] {
                runLength += 1
            }
            var advanced = false
            for count in stride(from: runLength, through: 1, by: -1) {
                let slice = words[i..<(i + count)]
                guard let (entry, key) = lookup(slice.map(\.lower)) else { continue }
                if count == 1, !passesSingleWordRules(slice[i], key: key, entry: entry, characters: characters) {
                    continue
                }
                let end = TermMatcher.extendOverStars(characters, from: words[i + count - 1].end, covered: covered)
                found.append((words[i].start, end, entry))
                for position in words[i].start..<end { covered[position] = true }
                i += count
                advanced = true
                break
            }
            if !advanced { i += 1 }
        }
    }

    /// 查词键；查不到时把最后一个词末尾的 es 或 s 去掉再查一次（去掉后至少剩 3 个字母）。返回术语与命中的键。
    private func lookup(_ lowerWords: [String]) -> (Entry, String)? {
        let key = lowerWords.joined(separator: " ")
        if let entry = wordKeys[key] { return (entry, key) }
        guard let last = lowerWords.last else { return nil }
        let head = lowerWords.dropLast().map { $0 + " " }.joined()
        for suffix in ["es", "s"] where last.hasSuffix(suffix) && last.count - suffix.count >= 3 {
            let stem = head + String(last.dropLast(suffix.count))
            if let entry = wordKeys[stem] { return (entry, stem) }
        }
        return nil
    }

    /// 字符键前后的字符是否满足边界要求。start..<end 是键在 characters 里的范围（不含后面的 `*`）。
    static func passesBoundary(_ boundary: CharacterBoundary, _ characters: [Character], start: Int, end: Int) -> Bool {
        let before: Character? = start > 0 ? characters[start - 1] : nil
        let after: Character? = end < characters.count ? characters[end] : nil
        let cjkBefore = before.map(IntelLexicon.isCJK) ?? false
        let cjkAfter = after.map(IntelLexicon.isCJK) ?? false
        switch boundary {
        case .none:
            return true
        case .intelWord:
            // 「非常」（很）不是否定：「非常安全」仍算「安全」。
            let lookBack = String(characters[max(0, start - IntelLexicon.cjkNegationLookBack)..<start])
                .replacingOccurrences(of: "非常", with: "")
            if lookBack.contains(where: IntelLexicon.cjkNegations.contains) { return false }
            return !cjkAfter
        case .commonWord:
            return after == "*" || (!cjkBefore && !cjkAfter)
        }
    }

    /// 只有一个词的匹配的两条限制（6.3 节扫描第 4、5 条）。情报用语不受这两条限制；舰船缩写不受第 5 条限制；
    /// 舰船与舰船分组除 caseSensitiveShipNames 与 ambiguousShortNames 里的键外也不受第 5 条限制。
    private func passesSingleWordRules(_ word: Word, key: String, entry: Entry, characters: [Character]) -> Bool {
        if case .intelWord = entry.kind { return true }
        // 第 4 条：虚词、1～2 个字符的词、全是数字的词不算匹配。
        if IntelLexicon.stopWords.contains(word.lower) || word.lower.count <= 2
            || word.lower.allSatisfy({ $0.isNumber }) {
            return false
        }
        if entry.isAlias { return true }
        let followedByStar = word.end < characters.count && characters[word.end] == "*"
        let capitalizedOrStarred = word.first.isUppercase || followedByStar
        if entry.isShipKind {
            // 按命中的键判断：`sins` 经复数回退命中 `sin`，也要大写或带 `*`。
            if IntelLexicon.caseSensitiveShipNames.contains(key) { return capitalizedOrStarred }
            if !IntelLexicon.ambiguousShortNames.contains(key) { return true }
        }
        // 第 5 条：3 个以内的 ASCII 字母，或也是普通英文词的名称，要首字母大写或后面紧跟 `*`。
        let isShortASCII = word.lower.count <= 3 && word.lower.allSatisfy { $0.isASCII && $0.isLetter }
        guard isShortASCII || IntelLexicon.ambiguousShortNames.contains(key)
            || IntelLexicon.ambiguousShortNames.contains(word.lower) else { return true }
        return capitalizedOrStarred
    }

    /// 取词：连续的字母或数字，中间可以夹 `'`、`’`、`-`。被字符键盖住的位置不算。
    private static func words(in characters: [Character], covered: [Bool]) -> [Word] {
        var words: [Word] = []
        var index = 0
        let count = characters.count
        func usable(_ position: Int) -> Bool {
            !covered[position] && IntelLexicon.isWordCharacter(characters[position])
        }
        while index < count {
            guard usable(index) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < count {
                if usable(end) {
                    end += 1
                } else if !covered[end], IntelLexicon.isWordJoiner(characters[end]), end + 1 < count, usable(end + 1) {
                    end += 2
                } else {
                    break
                }
            }
            words.append(Word(start: index, end: end, lower: String(characters[index..<end]).lowercased(),
                              first: characters[index]))
            index = end
        }
        return words
    }

    /// 匹配后面紧跟的一个或多个 `*` 并入范围（中文客户端在翻译过的名称后加 `*`）。
    private static func extendOverStars(_ characters: [Character], from end: Int, covered: [Bool]) -> Int {
        var result = end
        while result < characters.count, characters[result] == "*", !covered[result] { result += 1 }
        return result
    }

    // MARK: - 建索引

    /// 舰船缩写：按右边的英文名找舰船或舰船分组（舰船优先），用左边的词建词键；找不到时不收。
    private static func addAliases(to builder: inout IndexBuilder, ships: [ShipName]) {
        var byName: [String: ShipName] = [:]
        // 舰船在前：同名时舰船优先。
        for ship in ships.sorted(by: { ($0.groupID == nil ? 1 : 0, $0.id) < ($1.groupID == nil ? 1 : 0, $1.id) }) {
            let key = ship.name.lowercased()
            if byName[key] == nil { byName[key] = ship }
        }
        for (alias, target) in IntelLexicon.shipAliases.sorted(by: { $0.key < $1.key }) {
            guard let ship = byName[target.lowercased()] else { continue }
            let kind: TermKind = ship.groupID == nil ? .shipGroup(groupID: ship.id) : .ship(typeID: ship.id)
            let entry = Entry(kind: kind, english: ship.name, localized: ship.localized,
                              rank: ship.groupID == nil ? 1 : 0, isKnownSpace: false, id: ship.id, isAlias: true)
            builder.add(names: [alias], entry: entry)
        }
    }

    /// 情报用语：每个词各建一个键，种类是 intelWord。中文的词作为字符键匹配时看边界（intelWord）。
    private static func addIntelWords(to builder: inout IndexBuilder) {
        for (words, word, english) in [(IntelLexicon.clearWords, IntelWord.clear, "clear"),
                                       (IntelLexicon.noVisualWords, IntelWord.noVisual, "no visual")] {
            let entry = Entry(kind: .intelWord(word), english: english, localized: [:], rank: 4,
                              isKnownSpace: false, id: 0, isAlias: false, boundary: .intelWord)
            builder.add(names: words.sorted(), entry: entry)
        }
    }

    /// 建索引时的可变状态。
    private struct IndexBuilder {
        var characterKeys: [String: Entry] = [:]
        var wordKeys: [String: Entry] = [:]

        /// 为一个术语的各个名称建键：含汉字、假名或谚文的建字符键（2 个字符以上），其余建词键。
        /// 字符键在 commonWordLocalizedNames 里、而这一项本来不看边界时，这个键按 commonWord 匹配。
        mutating func add(names: [String], entry: Entry) {
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if name.contains(where: IntelLexicon.isCJK) {
                    guard name.count >= 2 else { continue }
                    var keyed = entry
                    if keyed.boundary == .none, IntelLexicon.commonWordLocalizedNames.contains(name) {
                        keyed.boundary = .commonWord
                    }
                    insert(keyed, key: name.lowercased(), into: &characterKeys)
                } else if let key = IntelLexicon.wordKey(name) {
                    insert(entry, key: key, into: &wordKeys)
                }
            }
        }

        /// 放进索引；键已有时按先后规则决定留哪一个。
        private func insert(_ entry: Entry, key: String, into table: inout [String: Entry]) {
            if let current = table[key], !TermMatcher.prefers(entry, over: current) { return }
            table[key] = entry
        }
    }

    /// 同一个键上 candidate 是否比 current 更该留下：种类按先后；同为星系时已知空间优先，再取 ID 小的；
    /// 其余同种类重名时取 ID 小的；同一个术语的另一个名称不替换。
    static func prefers(_ candidate: Entry, over current: Entry) -> Bool {
        if candidate.rank != current.rank { return candidate.rank < current.rank }
        if candidate.isKnownSpace != current.isKnownSpace { return candidate.isKnownSpace }
        if candidate.id != current.id { return candidate.id < current.id }
        // 同一个术语：真名优先于缩写（缩写不替换已有的真名键）。
        return current.isAlias && !candidate.isAlias
    }
}
