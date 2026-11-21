// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的脱敏（v1.1 设计 7.3 节）：把用户名、主机名、角色名换成占位符，把崩溃报告里的设备标识换成 `[redacted]`。
// 脱敏始终开启，适用于压缩包里每个文件的内容与 Issue 的标题和正文。
//
// 匹配规则：
// 1. 一次扫描完成。每个位置试全部的词，取能匹配的最长的一个，输出占位符，再从匹配的末尾继续。
//    替换后的文字不再参与匹配，所以名叫 `user` 的角色不会破坏已输出的 `[user]`。
// 2. 不区分大小写。
// 3. 只由 ASCII 字符组成的词要求两侧是边界：前后字符都不是 ASCII 字母或数字。含非 ASCII 字符的词不要求边界。
// 4. 去掉首尾空白后不足 3 个字符的 ASCII 词，只在紧跟 `/Users/` 或 `\/Users\/` 时替换；不足 2 个字符的非 ASCII 词不替换。
// 5. 主目录路径同时匹配原样的与每个 `/` 写成 `\/` 的两种写法（JSON 转义）。
// 6. 设备标识按 `"键" : "值"` 匹配，冒号两侧的空白可有可无，只替换值。
// 7. 每个词同时按 NFC（预组合）与 NFD（分解）两种写法匹配：文件系统与部分日志用 NFD 写 `é`，
//    逐个标量比较时 `José` 的两种写法不相同。
//
// 实现：文字先转成 Unicode 标量数组，再逐个标量做小写折叠（只取一对一的映射，下标不变），
// 词按折叠后的前两个标量分桶，桶内按长度从长到短试。日志有几 MiB，这样每个位置只试开头相同的几个词。

import Foundation

/// 要替换的词。
public struct RedactionTerms: Sendable, Equatable {
    /// 短用户名与全名。
    public var userNames: [String]
    /// 主机名与电脑名称。
    public var hostNames: [String]
    /// 角色名。
    public var characterNames: [String]
    /// 主目录路径。不是 `/Users/<用户名>` 形式的主目录也能认出来。
    public var homeDirectory: String?

    /// 用各类词建词表。
    public init(userNames: [String] = [], hostNames: [String] = [], characterNames: [String] = [],
                homeDirectory: String? = nil) {
        self.userNames = userNames
        self.hostNames = hostNames
        self.characterNames = characterNames
        self.homeDirectory = homeDirectory
    }
}

/// 按类别统计的替换次数。
public struct RedactionCounts: Sendable, Equatable, Codable {
    /// 用户名与主目录路径。
    public var user: Int
    /// 主机名。
    public var host: Int
    /// 角色名。
    public var character: Int
    /// 设备标识。
    public var identifier: Int

    /// 用各类次数建统计，默认全为 0。
    public init(user: Int = 0, host: Int = 0, character: Int = 0, identifier: Int = 0) {
        self.user = user
        self.host = host
        self.character = character
        self.identifier = identifier
    }

    /// 合计次数。
    public var total: Int { user + host + character + identifier }

    /// 按类别相加。
    public static func + (lhs: RedactionCounts, rhs: RedactionCounts) -> RedactionCounts {
        RedactionCounts(user: lhs.user + rhs.user, host: lhs.host + rhs.host,
                        character: lhs.character + rhs.character, identifier: lhs.identifier + rhs.identifier)
    }
}

/// 脱敏器。建好后可在任何线程使用。
public struct Redactor: Sendable {
    /// 用户名的占位符。
    public static let userPlaceholder = "[user]"
    /// 主机名的占位符。
    public static let hostPlaceholder = "[host]"
    /// 设备标识的占位符。
    public static let identifierPlaceholder = "[redacted]"
    /// 主目录路径的替换结果。
    public static let homePlaceholder = "/Users/[user]"
    /// 要替换值的 JSON 键（崩溃报告里的设备标识）。
    public static let identifierKeys = ["crashReporterKey", "deviceIdentifierForVendor"]

    /// 词的类别，决定计入哪一项次数。
    enum Category: Sendable {
        case user, host, character
    }

    /// 一个要匹配的词。
    struct Term: Sendable {
        /// 折叠后的标量，用来比较。
        let folded: [Unicode.Scalar]
        /// 输出的占位符。
        let replacement: String
        /// 类别。
        let category: Category
        /// 是否要求两侧是边界（只由 ASCII 组成的词）。
        let requiresBoundary: Bool
        /// 是否只在紧跟 `/Users/` 或 `\/Users\/` 时替换（不足 3 个字符的 ASCII 词）。
        let pathOnly: Bool
    }

    /// 至少 2 个标量的词，按折叠后的前两个标量分桶，桶内从长到短。
    private let pairBuckets: [UInt64: [Term]]
    /// 只有 1 个标量的词（不足 3 个字符的 ASCII 用户名等），按这个标量分桶。
    private let singleBuckets: [Unicode.Scalar: [Term]]
    /// 折叠后的角色名 → 占位符。
    private let characterPlaceholders: [String: String]

    /// 用词表建脱敏器。空白的词被忽略；同一个词（不区分大小写）出现在多个类别时，按用户名、主机名、角色名的顺序取第一个。
    public init(terms: RedactionTerms) {
        // 按标量去重：Swift 的 String 按规范等价比较，NFC 与 NFD 两种写法会被当成同一个键。
        var seen = Set<[UInt32]>()
        var list: [Term] = []
        // 主目录路径：原样与 JSON 转义两种写法，替换成同样写法的占位路径，JSON 仍能解析。
        if let home = terms.homeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), home.count > 1 {
            let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
            Redactor.append(trimmed, replacement: Redactor.homePlaceholder, category: .user,
                            pathRule: false, to: &list, seen: &seen)
            Redactor.append(trimmed.replacingOccurrences(of: "/", with: "\\/"),
                            replacement: Redactor.homePlaceholder.replacingOccurrences(of: "/", with: "\\/"),
                            category: .user, pathRule: false, to: &list, seen: &seen)
        }
        for name in terms.userNames {
            Redactor.append(name, replacement: Redactor.userPlaceholder, category: .user, to: &list, seen: &seen)
        }
        for name in terms.hostNames {
            Redactor.append(name, replacement: Redactor.hostPlaceholder, category: .host, to: &list, seen: &seen)
        }
        // 角色名按折叠后的名字排序后从 1 起编号，同一份报告里序号稳定。不会被替换的名字（过短）不占序号。
        var characters: [(key: String, name: String)] = []
        var characterKeys = Set<String>()
        for raw in terms.characterNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 键取 NFC 写法：同一个名字的两种写法得到同一个序号。
            let key = Redactor.foldedString(name.precomposedStringWithCanonicalMapping)
            guard Redactor.isEligible(name), characterKeys.insert(key).inserted else { continue }
            characters.append((key, name))
        }
        characters.sort { $0.key == $1.key ? $0.name < $1.name : $0.key < $1.key }
        var placeholders: [String: String] = [:]
        for (index, entry) in characters.enumerated() {
            let placeholder = "[character-\(index + 1)]"
            placeholders[entry.key] = placeholder
            Redactor.append(entry.name, replacement: placeholder, category: .character, to: &list, seen: &seen)
        }
        characterPlaceholders = placeholders
        var pairs: [UInt64: [Term]] = [:]
        var singles: [Unicode.Scalar: [Term]] = [:]
        for term in list {
            if term.folded.count >= 2 {
                pairs[Redactor.pairKey(term.folded[0], term.folded[1]), default: []].append(term)
            } else if let only = term.folded.first {
                singles[only, default: []].append(term)
            }
        }
        pairBuckets = pairs.mapValues { $0.sorted { $0.folded.count > $1.folded.count } }
        singleBuckets = singles
    }

    /// 把一个词的原样、NFC、NFD 三种写法加进列表（相同的只加一次）。空白、过短（非 ASCII 不足 2 个字符）
    /// 或已出现过的写法不加。
    ///
    /// - Parameter pathRule: 是否对不足 3 个字符的 ASCII 词套用「只在 `/Users/` 之后替换」的规则（主目录路径不套用）。
    private static func append(_ raw: String, replacement: String, category: Category, pathRule: Bool = true,
                               to list: inout [Term], seen: inout Set<[UInt32]>) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEligible(word) else { return }
        let isASCII = word.unicodeScalars.allSatisfy(\.isASCII)
        for form in [word, word.precomposedStringWithCanonicalMapping, word.decomposedStringWithCanonicalMapping] {
            let folded = form.unicodeScalars.map(Redactor.fold)
            guard seen.insert(folded.map(\.value)).inserted else { continue }
            list.append(Term(folded: folded, replacement: replacement, category: category,
                             requiresBoundary: isASCII, pathOnly: pathRule && isASCII && word.count < 3))
        }
    }

    /// 角色名的占位符，如 `[character-2]`；序号按名字排序（不区分大小写）后从 1 起编。不在词表里时返回 nil。
    public func placeholder(forCharacter name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return characterPlaceholders[Redactor.foldedString(trimmed.precomposedStringWithCanonicalMapping)]
    }

    /// 脱敏一段文字，返回结果与按类别的替换次数。词表为空时原样返回。
    public func redact(_ text: String) -> (text: String, counts: RedactionCounts) {
        let source = Array(text.unicodeScalars)
        let folded = source.map(Redactor.fold)
        // 先拼进标量数组，最后一次转成字符串：每次往 UnicodeScalarView 追加片段都很慢（实测 2 MiB 日志要近 1 秒）。
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(source.count)
        var counts = RedactionCounts()
        var index = 0
        var copiedFrom = 0
        while index < source.count {
            if let match = match(at: index, source: source, folded: folded) {
                output.append(contentsOf: source[copiedFrom..<match.keepUntil])
                output.append(contentsOf: match.replacement.unicodeScalars)
                match.count(&counts)
                index = match.end
                copiedFrom = index
            } else {
                index += 1
            }
        }
        output.append(contentsOf: source[copiedFrom...])
        var view = String.UnicodeScalarView()
        view.append(contentsOf: output)
        return (String(view), counts)
    }

    /// 一次匹配的结果。
    private struct Match {
        /// 原文从当前位置到 keepUntil 之前的部分照抄（设备标识只替换值，键和引号照抄）。
        let keepUntil: Int
        /// 匹配结束的位置（不含）。
        let end: Int
        /// 输出的占位符。
        let replacement: String
        /// 计数的动作。
        let count: (inout RedactionCounts) -> Void
    }

    /// 在 index 处找一个匹配：先试设备标识，再试最长的词。
    private func match(at index: Int, source: [Unicode.Scalar], folded: [Unicode.Scalar]) -> Match? {
        if source[index] == "\"", let identifier = identifierMatch(at: index, source: source) {
            return identifier
        }
        // 长的词都在两个标量的桶里，先试它们，再试单个标量的词，保持「最长优先」。
        var candidates: [Term] = []
        if index + 1 < folded.count, let pair = pairBuckets[Redactor.pairKey(folded[index], folded[index + 1])] {
            candidates = pair
        }
        if let single = singleBuckets[folded[index]] { candidates += single }
        for term in candidates where matches(term, at: index, source: source, folded: folded) {
            let end = index + term.folded.count
            return Match(keepUntil: index, end: end, replacement: term.replacement) { counts in
                switch term.category {
                case .user: counts.user += 1
                case .host: counts.host += 1
                case .character: counts.character += 1
                }
            }
        }
        return nil
    }

    /// 词 term 能否在 index 处匹配：折叠后的标量相同，并满足边界与路径规则。
    private func matches(_ term: Term, at index: Int, source: [Unicode.Scalar], folded: [Unicode.Scalar]) -> Bool {
        let end = index + term.folded.count
        guard end <= folded.count else { return false }
        for offset in 0..<term.folded.count where folded[index + offset] != term.folded[offset] {
            return false
        }
        if term.requiresBoundary {
            if index > 0 && Redactor.isASCIIAlphanumeric(source[index - 1]) { return false }
            if end < source.count && Redactor.isASCIIAlphanumeric(source[end]) { return false }
        }
        if term.pathOnly {
            return Redactor.follows("/users/", before: index, in: folded)
                || Redactor.follows("\\/users\\/", before: index, in: folded)
        }
        return true
    }

    /// index 处是否是 `"crashReporterKey" : "值"` 一类的设备标识；是时返回只替换值的匹配。
    private func identifierMatch(at index: Int, source: [Unicode.Scalar]) -> Match? {
        for key in Redactor.identifierKeys {
            let quotedKey = Array("\"\(key)\"".unicodeScalars)
            guard index + quotedKey.count <= source.count,
                  Array(source[index..<(index + quotedKey.count)]) == quotedKey else { continue }
            var cursor = index + quotedKey.count
            cursor = Redactor.skipSpaces(from: cursor, in: source)
            guard cursor < source.count, source[cursor] == ":" else { return nil }
            cursor = Redactor.skipSpaces(from: cursor + 1, in: source)
            guard cursor < source.count, source[cursor] == "\"" else { return nil }
            let valueStart = cursor + 1
            // 找到没有被反斜杠转义的结束引号。
            var valueEnd = valueStart
            while valueEnd < source.count && source[valueEnd] != "\"" {
                valueEnd += source[valueEnd] == "\\" ? 2 : 1
            }
            guard valueEnd < source.count else { return nil }
            return Match(keepUntil: valueStart, end: valueEnd, replacement: Redactor.identifierPlaceholder) {
                $0.identifier += 1
            }
        }
        return nil
    }

    // MARK: - 小工具

    /// 两个标量拼成分桶的键。
    static func pairKey(_ first: Unicode.Scalar, _ second: Unicode.Scalar) -> UInt64 {
        UInt64(first.value) << 32 | UInt64(second.value)
    }

    /// 词（已去掉首尾空白）能否参与替换：不为空；含非 ASCII 字符时至少 2 个字符。
    static func isEligible(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return word.unicodeScalars.allSatisfy(\.isASCII) || word.count >= 2
    }

    /// 跳过空格、制表符与换行。
    private static func skipSpaces(from start: Int, in source: [Unicode.Scalar]) -> Int {
        var cursor = start
        while cursor < source.count, [" ", "\t", "\n", "\r"].contains(source[cursor]) {
            cursor += 1
        }
        return cursor
    }

    /// folded 里 index 之前的部分是否以 prefix（已是小写）结尾。
    private static func follows(_ prefix: String, before index: Int, in folded: [Unicode.Scalar]) -> Bool {
        let scalars = Array(prefix.unicodeScalars)
        guard index >= scalars.count else { return false }
        return Array(folded[(index - scalars.count)..<index]) == scalars
    }

    /// 是否是 ASCII 字母或数字。
    static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    /// 一个标量的小写折叠。只取一对一的映射，保证折叠前后下标对应；一对多的字符保持原样。
    static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            if (0x41...0x5A).contains(scalar.value) { return Unicode.Scalar(scalar.value + 0x20) ?? scalar }
            return scalar
        }
        guard scalar.properties.changesWhenLowercased else { return scalar }
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first ?? scalar : scalar
    }

    /// 整个字符串的折叠，用作去重与查找的键。
    static func foldedString(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map(Redactor.fold)))
    }
}

/// 收集报告里要替换的角色名。
public enum CharacterNameCollector {
    /// 全部配置方案里出现过的角色名，加上在线客户端的角色名，去重（区分大小写的去重；不区分大小写的合并由 `Redactor` 做）。
    ///
    /// 来源：每个配置方案的 `layouts`、`hiddenCharacters`、`highlightColors`、`characterHotkeys` 的键与循环组成员。
    /// 结果按名字排序，空白的名字被去掉。
    public static func names(config: AppConfig, online: [String]) -> [String] {
        var names = Set<String>()
        for profile in config.profiles {
            names.formUnion(profile.layouts.keys)
            names.formUnion(profile.hiddenCharacters)
            names.formUnion(profile.highlightColors.keys)
            names.formUnion(profile.characterHotkeys.keys)
            for group in profile.cycleGroups {
                names.formUnion(group.members)
            }
        }
        names.formUnion(online)
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
            .sorted()
    }
}
