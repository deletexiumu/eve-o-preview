// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的判断与分批规则（docs/design-intel-translate.md 7.6 节、7.8 节）：
// - alreadyIn：按文字种类的占比判断消息是否已经是目标语言（参考实现 translate.py 的 already_in）。
// - skipReason：不用交给模型的原因。
// - cacheKey：缓存比对用的原文（参考实现 translator.py 的 cache_key）。
// - nextBatch：从待翻译的消息里取下一批。
// - renderTerms：只把术语换成目标语言的写法（「只有术语」的消息不用模型）。
// 全部是纯函数，术语匹配与情报分段由调用方算好传入（第 13.2 节：不直接调匹配与分段的规则）。

import Foundation

/// 翻译的判断与分批规则。
public enum TranslationRules {
    /// 某种文字占字母的比例不小于它时，认为已经是这种语言。
    public static let scriptShareThreshold = 0.5
    /// 一批至多几条消息。
    public static let maxBatchMessages = 20
    /// 一批合计至多几个字符（每条按截断后的长度计）。
    public static let maxBatchCharacters = 6_000
    /// 每条送去翻译的文字至多几个字符，超出的部分截掉。
    public static let maxMessageCharacters = 500
    /// 补读的消息只排最近这么多秒内的。
    public static let backfillQueueSeconds = 600.0
    /// 补读的消息至多排这么多条。
    public static let backfillQueueLimit = 20

    // MARK: - 语言判断

    /// 文字是否已经是目标语言（按文字种类的占比判断），或者没有字母（7.6 节）。
    ///
    /// 1. 没有字母（Unicode 的字母类别）时为真。
    /// 2. 中文：含假名时为假；否则汉字占字母的比例不小于 0.5 时为真。
    /// 3. 日文：含假名，且假名加汉字的占比不小于 0.5 时为真。
    /// 4. 韩文：谚文的占比不小于 0.5 时为真。
    /// 5. 俄文：西里尔字母的占比不小于 0.5 时为真。
    /// 6. 英、德、法、西文：为假，交给模型判断。
    public static func alreadyIn(_ text: String, target: AppLanguage) -> Bool {
        var letters = 0
        var han = 0
        var kana = 0
        var hangul = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars {
            if isLetter(scalar) { letters += 1 }
            let value = scalar.value
            // 与参考实现的正则一致：按码位区间计数，不看是不是字母。
            if (0x3400...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) { han += 1 }
            if (0x3040...0x30FF).contains(value) { kana += 1 }
            if (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) { hangul += 1 }
            if (0x0400...0x04FF).contains(value) { cyrillic += 1 }
        }
        guard letters > 0 else { return true }
        let total = Double(letters)
        switch target {
        case .zh:
            return kana == 0 && Double(han) / total >= scriptShareThreshold
        case .ja:
            return kana > 0 && Double(kana + han) / total >= scriptShareThreshold
        case .ko:
            return Double(hangul) / total >= scriptShareThreshold
        case .ru:
            return Double(cyrillic) / total >= scriptShareThreshold
        case .en, .fr, .de, .es:
            return false
        }
    }

    /// 是否属于 Unicode 的字母类别（Lu、Ll、Lt、Lm、Lo）。
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// 不用交给模型的原因；都不成立时为 nil（7.6 节）。
    ///
    /// 按顺序取第一个成立的：系统消息；正文去掉空白后为空；正文已是目标语言；
    /// 是情报样的消息，且去掉术语、人数与人名后剩下的文字已是目标语言（或为空）。
    public static func skipReason(for line: ChatLine, report: IntelReport, target: AppLanguage)
        -> TranslationSkipReason? {
        if line.isSystem { return .systemSpeaker }
        if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if alreadyIn(line.text, target: target) { return .sameLanguage }
        if report.isIntelLike && alreadyIn(IntelParser.remainder(of: report), target: target) { return .termsOnly }
        return nil
    }

    // MARK: - 缓存键

    /// 缓存比对用的原文（7.8 节）：按行处理，去掉「后面是空白或行尾」的 `*`，连续空白并成一个空格，
    /// 去掉首尾空白；空行去掉；各行用换行连接。
    ///
    /// `*` 的判断看的是原文里它后面的字符（与参考实现的正则 `\*(?=\s|$)` 相同），所以 `a**` 只去掉最后一个。
    public static func cacheKey(_ text: String) -> String {
        var lines: [String] = []
        // 按码位切行：Swift 把 "\r\n" 当成一个字符，按字符切会漏掉 CRLF；切出的行里剩下的 "\r" 按空白处理。
        for rawLine in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let scalars = Array(rawLine)
            var kept = String.UnicodeScalarView()
            var pendingSpace = false
            for (index, scalar) in scalars.enumerated() {
                if scalar == "*" {
                    let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                    if next == nil || next!.properties.isWhitespace { continue }
                }
                if scalar.properties.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace && !kept.isEmpty { kept.append(" ") }
                pendingSpace = false
                kept.append(scalar)
            }
            let line = String(kept)
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 分批

    /// 一条消息送去翻译时计入的字符数：截断到 `maxMessageCharacters` 后的长度。
    public static func sentLength(_ text: String) -> Int {
        min(text.count, maxMessageCharacters)
    }

    /// 从待翻译的消息里取下一批（7.6 节）：按给出的顺序看 pending 的消息，`cacheKey` 相同的只取第一条；
    /// 一批至多 maxMessages 条（默认 20，答复被截断后队列会调小）、合计至多 6,000 个字符
    /// （每条按截断到 500 个字符后计），第一条总是能取。
    public static func nextBatch(pending: [TranslationItem],
                                 maxMessages: Int = maxBatchMessages) -> [TranslationItem] {
        let limit = max(1, min(maxMessages, maxBatchMessages))
        var batch: [TranslationItem] = []
        var keys: Set<String> = []
        var size = 0
        for item in pending where item.phase == .pending {
            let key = cacheKey(item.message.text)
            if keys.contains(key) { continue }
            let length = sentLength(item.message.text)
            if !batch.isEmpty && size + length > maxBatchCharacters { break }
            keys.insert(key)
            batch.append(item)
            size += length
            if batch.count >= limit { break }
        }
        return batch
    }

    // MARK: - 模型的结果

    /// 用拉丁字母书写的目标语言：按文字种类判断不出是否已是目标语言，要看模型的结果（审查 m7）。
    static let latinTargets: Set<AppLanguage> = [.en, .fr, .de, .es]

    /// 模型的结果（或缓存里的译文）换成这条消息的阶段：
    /// 1. 译文与原文的 `cacheKey` 相同：模型原样抄回，是 skipped(.sameLanguage)，浮窗不把同一句显示两遍。
    /// 2. 目标语言是英、德、法、西文，且模型给的原文语言（去掉 `-`、`_` 后的地区部分）就是目标语言：
    ///    是 skipped(.sameLanguage)。「只显示翻译过的消息」打开时这类消息不显示。
    /// 3. 其余是 done。结果照常进译文缓存，下次不再付费。
    public static func resultPhase(_ result: TranslatedText, original: String, target: AppLanguage)
        -> TranslationPhase {
        if cacheKey(result.text) == cacheKey(original) { return .skipped(.sameLanguage, rendered: nil) }
        if latinTargets.contains(target), let code = result.sourceLanguage,
           code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) == target.rawValue {
            return .skipped(.sameLanguage, rendered: nil)
        }
        return .done(text: result.text, sourceLanguage: result.sourceLanguage)
    }

    // MARK: - 术语替换

    /// 把术语换成目标语言的写法；写法相同（不区分大小写）的不动（7.6 节）。
    ///
    /// 星系、星域、舰船与舰船分组换成 `name(in: target)`；名称后面的 `*`（中文客户端的翻译标记）随之去掉。
    /// 情报用语只在有目标语言的译名时才换，不换成英文的规范写法（`clr` 不会变成 `clear`）。
    /// 范围不在这段文字里、或与前一处重叠的匹配忽略。
    public static func renderTerms(_ text: String, matches: [TermMatch], target: AppLanguage) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in validMatches(matches, in: text) {
            guard let replacement = replacement(for: match, in: text, target: target) else { continue }
            result += text[cursor..<match.range.lowerBound]
            result += replacement
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// 一处匹配在原文里的写法：去掉末尾的 `*` 与空白。
    public static func sourceSpelling(of match: TermMatch, in text: String) -> String {
        var spelling = String(text[match.range])
        while let last = spelling.last, last == "*" || last.isWhitespace { spelling.removeLast() }
        return spelling
    }

    /// 范围在文字里、按位置排序且互不重叠的匹配。起点相同时长的优先（`Naga Navy Issue` 胜过 `Naga`）。
    static func validMatches(_ matches: [TermMatch], in text: String) -> [TermMatch] {
        var result: [TermMatch] = []
        var lastEnd = text.startIndex
        let sorted = matches.filter { $0.range.lowerBound >= text.startIndex && $0.range.upperBound <= text.endIndex
            && !$0.range.isEmpty }
            .sorted { lhs, rhs in
                lhs.range.lowerBound != rhs.range.lowerBound ? lhs.range.lowerBound < rhs.range.lowerBound
                    : lhs.range.upperBound > rhs.range.upperBound
            }
        for match in sorted where match.range.lowerBound >= lastEnd {
            result.append(match)
            lastEnd = match.range.upperBound
        }
        return result
    }

    /// 一处匹配的替换文字；不用替换时为 nil。
    private static func replacement(for match: TermMatch, in text: String, target: AppLanguage) -> String? {
        let name: String
        if case .intelWord = match.kind {
            guard let localized = match.localized[target.rawValue] else { return nil }
            name = localized
        } else {
            name = match.name(in: target)
        }
        let source = sourceSpelling(of: match, in: text)
        if name.isEmpty || name.caseInsensitiveCompare(source) == .orderedSame { return nil }
        return name
    }
}
