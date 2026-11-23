// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志单行的解析与归类（反馈文档 7.6 节）。
// 行的形式是「[ yyyy.MM.dd HH:mm:ss ] (类别) 正文」。只有 combat 类别再细分：
// 1. 正文开头（跳过空白与 <…> 标记后）是数字时，按最后一个 <color=…> 的值判断方向：
//    ffcc0000 为受到伤害，ff00ffff 为造成伤害，8 种语言相同（L7、L14）。
// 2. 有数字但没有颜色标记时，改用方向词（CombatLogCatalog）；方向词判断不了时，转按第 3 条判断。
//    武器名以数字开头的未命中行（如「125mm … misses you completely」）因此仍能识别为未命中。
// 3. 没有开头的数字时，按未命中的句尾与通用短语判断；判断不了的归为 otherCombat。
// 判断不了的行一律不触发提醒：宁可漏报，不误报。解析不用正则表达式，只做前缀、后缀与子串比较。

import Foundation

/// 游戏日志单行的解析器。
public enum CombatLogParser {
    /// 时间部分的字符数：`yyyy.MM.dd HH:mm:ss`。
    static let timestampLength = 19

    /// 解析一行。不是「[ 时间 ] (类别) 正文」形式的行返回 nil。
    public static func parse(_ line: String) -> CombatLogLine? {
        guard let parts = split(line) else { return nil }
        guard parts.category == "combat" else {
            return CombatLogLine(category: parts.category, kind: .other)
        }
        return CombatLogLine(category: parts.category, kind: classifyCombat(parts.body))
    }

    /// 取日志行里的时间，换算成 1970 年以来的秒数。日志时间是 UTC 的整秒（L2、L11）。
    ///
    /// 用到它的地方：探针计算「日志时间到收到事件」的延迟（V13）；`CombatLogReplayGuard` 过滤晚跟踪文件的积压行
    /// （反馈文档 7.3 节）。正常跟踪新增内容时，提醒不看日志时间。
    /// 不是合法日志行或日期不合法时返回 nil。
    public static func logTime(_ line: String) -> Double? {
        guard let parts = split(line) else { return nil }
        let t = parts.timestamp
        // 各字段在时间串里的位置，形式已由 split 核对过，这里只取数值。
        func number(_ start: Int, _ length: Int) -> Int {
            t[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        let (year, month, day) = (number(0, 4), number(5, 2), number(8, 2))
        let (hour, minute, second) = (number(11, 2), number(14, 2), number(17, 2))
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Double(days * 86_400 + hour * 3_600 + minute * 60 + second)
    }

    /// 去掉标记，得到可见文字：删掉每一对 `<` 与 `>` 之间的内容（找不到 `>` 的 `<` 保留），
    /// 连续的空白（含 U+00A0）合成一个空格，去掉首尾空白。不解码 `&amp;` 一类的实体。
    public static func plainText(_ markup: String) -> String {
        let scalars = Array(markup.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        // 一旦某个 `<` 之后再也没有 `>`，后面的 `<` 也不会有，记下来免得重复查找。
        var noMoreClose = false
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "<", !noMoreClose {
                if let close = scalars[(i + 1)...].firstIndex(of: ">") {
                    i = close + 1
                    continue
                }
                noMoreClose = true
            }
            if c.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                i += 1
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: - 行的拆分

    /// 一行拆出的三部分。
    struct LineParts {
        /// 时间部分的 19 个 ASCII 字节。
        var timestamp: [UInt8]
        /// 类别，小写。
        var category: String
        /// 正文（可能为空）。
        var body: String
    }

    /// 核对行的形式并拆成时间、类别与正文。行首的 U+FEFF 与行尾的回车先去掉。
    static func split(_ line: String) -> LineParts? {
        var bytes = Array(line.utf8)
        // 行首可能有一个或多个 BOM（UTF-8 编码是 EF BB BF），上游记录聊天日志每行都带。
        var start = 0
        while bytes.count - start >= 3, bytes[start] == 0xEF, bytes[start + 1] == 0xBB, bytes[start + 2] == 0xBF {
            start += 3
        }
        while let last = bytes.last, last == 0x0D || last == 0x0A {
            bytes.removeLast()
        }
        let prefixLength = 2 + timestampLength + 4      // "[ " + 时间 + " ] ("
        guard bytes.count - start >= prefixLength + 1 else { return nil }
        guard bytes[start] == UInt8(ascii: "["), bytes[start + 1] == UInt8(ascii: " ") else { return nil }
        let timestamp = Array(bytes[(start + 2)..<(start + 2 + timestampLength)])
        guard isTimestamp(timestamp) else { return nil }
        let afterTime = start + 2 + timestampLength
        guard bytes[afterTime..<(afterTime + 4)].elementsEqual(" ] (".utf8) else { return nil }
        // 类别到第一个 `)` 为止；类别不长，限定在 32 字节内查找，避免把正文里的括号当成结尾。
        let categoryStart = afterTime + 4
        let searchEnd = min(bytes.count, categoryStart + 32)
        guard let close = bytes[categoryStart..<searchEnd].firstIndex(of: UInt8(ascii: ")")),
              close > categoryStart else { return nil }
        let category = String(decoding: bytes[categoryStart..<close], as: UTF8.self).lowercased()
        // `)` 之后应是一个空格再接正文；正文为空时行可能直接在 `)` 处结束。
        let bodyStart: Int
        if close + 1 == bytes.count {
            bodyStart = bytes.count
        } else if bytes[close + 1] == UInt8(ascii: " ") {
            bodyStart = close + 2
        } else {
            return nil
        }
        let body = String(decoding: bytes[bodyStart...], as: UTF8.self)
        return LineParts(timestamp: timestamp, category: category, body: body)
    }

    /// 时间部分是否为 `dddd.dd.dd dd:dd:dd` 的形式。只核对形式，不换算。
    static func isTimestamp(_ t: [UInt8]) -> Bool {
        let separators: [Int: UInt8] = [4: UInt8(ascii: "."), 7: UInt8(ascii: "."), 10: UInt8(ascii: " "),
                                        13: UInt8(ascii: ":"), 16: UInt8(ascii: ":")]
        guard t.count == timestampLength else { return false }
        for (index, byte) in t.enumerated() {
            if let expected = separators[index] {
                if byte != expected { return false }
            } else if !(0x30...0x39).contains(byte) {
                return false
            }
        }
        return true
    }

    /// 公历日期到 1970-01-01 的天数（Howard Hinnant 的 days_from_civil 算法），不依赖 Calendar 与时区。
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - combat 类别的归类

extension CombatLogParser {
    /// 伤害数字之间可以跳过的分隔符：千分位逗号、不换行空格、窄不换行空格。
    static let digitSeparators: Set<Unicode.Scalar> = [",", "\u{00A0}", "\u{202F}"]

    /// 短语表的小写形式，归类时与小写的正文比较（不区分大小写）。
    static let incomingWords = CombatLogCatalog.incomingWords.map { $0.lowercased() + " " }
    static let outgoingWords = CombatLogCatalog.outgoingWords.map { $0.lowercased() + " " }
    static let incomingPhrases = CombatLogCatalog.incomingPhrases.map { $0.lowercased() }
    static let outgoingPhrases = CombatLogCatalog.outgoingPhrases.map { $0.lowercased() }
    static let incomingMissMarkers = CombatLogCatalog.incomingMissMarkers.map { $0.lowercased() }
    static let incomingMissExclusions = CombatLogCatalog.incomingMissExclusions.map { $0.lowercased() }
    static let missMarkers = CombatLogCatalog.missMarkers.map { $0.lowercased() }

    /// 正文开头的伤害数字与它之前最后一个颜色标记。
    struct LeadingNumber: Equatable {
        /// 数字的值；超出 Int 范围时取 Int.max。
        var amount: Int
        /// 最后一个 `<color=…>` 的值，小写，去掉 `0x` 或 `#` 前缀；没有颜色标记时为 nil。
        var color: String?
    }

    /// 归类 combat 类别的正文（7.6 节第 4～7 步）。
    static func classifyCombat(_ body: String) -> CombatLineKind {
        guard let lead = leadingNumber(body) else {
            return missKind(plainText(body))
        }
        if let color = lead.color {
            if color == CombatLogCatalog.incomingDamageColor { return .incomingDamage(amount: lead.amount) }
            if color == CombatLogCatalog.outgoingDamageColor { return .outgoingDamage(amount: lead.amount) }
            // 有颜色但不是两种伤害色：是远程维修、能量传输一类的行（上游模板 519186～519190 用 0xff7fffff，
            // 句中也有「来自」）。方向词只在颜色缺失时用，这里不猜，归为 otherCombat。
            return .otherCombat
        }
        let text = plainText(body)
        // 没有颜色也没有方向词的行，可能是武器名以数字开头的未命中行，转按未命中的句尾判断；
        // 都不是时 missKind 返回 otherCombat。
        return directionByWords(text, amount: lead.amount) ?? missKind(text)
    }

    /// 取正文开头的数字：跳过空白与 `<…>` 标记直到第一个可见字符，记下跳过的最后一个颜色值。
    /// 可见文字不以 ASCII 数字开头时返回 nil。
    static func leadingNumber(_ body: String) -> LeadingNumber? {
        let scalars = Array(body.unicodeScalars)
        var color: String?
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.properties.isWhitespace {
                i += 1
                continue
            }
            // 找不到 `>` 的 `<` 是普通字符，到这里就是第一个可见字符。
            if c == "<", let close = scalars[(i + 1)...].firstIndex(of: ">") {
                if let value = colorValue(String(String.UnicodeScalarView(scalars[(i + 1)..<close]))) {
                    color = value
                }
                i = close + 1
                continue
            }
            break
        }
        guard i < scalars.count, isDigit(scalars[i]) else { return nil }
        var amount = 0
        while i < scalars.count {
            let c = scalars[i]
            if isDigit(c) {
                let digit = Int(c.value - 0x30)
                let (times, o1) = amount.multipliedReportingOverflow(by: 10)
                let (sum, o2) = times.addingReportingOverflow(digit)
                amount = (o1 || o2) ? Int.max : sum
                i += 1
            } else if digitSeparators.contains(c), i + 1 < scalars.count, isDigit(scalars[i + 1]) {
                // 单个分隔符夹在两个数字之间时跳过，如 `1,265`；其他情况数字到此结束。
                i += 1
            } else {
                break
            }
        }
        return LeadingNumber(amount: amount, color: color)
    }

    /// 标记是 `color=…` 时返回颜色值（小写，去掉引号与 `0x`、`#` 前缀），否则返回 nil。
    static func colorValue(_ tag: String) -> String? {
        let text = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("color=") else { return nil }
        var value = Substring(text.dropFirst("color=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if value.hasPrefix("0x") {
            value.removeFirst(2)
        } else if value.hasPrefix("#") {
            value.removeFirst()
        }
        return value
    }

    /// 没有颜色标记的伤害行：去掉开头的数字后按方向词判断（7.6 节第 6 步）。
    /// 方向词都不匹配时返回 nil，由调用方继续按未命中判断。
    static func directionByWords(_ text: String, amount: Int) -> CombatLineKind? {
        var rest = Substring(text.lowercased())
        // plainText 已把空白合成普通空格；数字里可能还有逗号与不换行空格。
        while let c = rest.unicodeScalars.first, isDigit(c) || digitSeparators.contains(c) || c == " " {
            rest = Substring(rest.unicodeScalars.dropFirst())
        }
        if incomingPhrases.contains(where: { rest.contains($0) }) { return .incomingDamage(amount: amount) }
        if outgoingPhrases.contains(where: { rest.contains($0) }) { return .outgoingDamage(amount: amount) }
        if incomingWords.contains(where: { rest.hasPrefix($0) }) { return .incomingDamage(amount: amount) }
        if outgoingWords.contains(where: { rest.hasPrefix($0) }) { return .outgoingDamage(amount: amount) }
        return nil
    }

    /// 没有开头数字的行：按未命中的句尾与通用短语判断（7.6 节第 7 步）。
    static func missKind(_ text: String) -> CombatLineKind {
        var t = Substring(text.lowercased())
        while t.last?.isWhitespace == true { t = t.dropLast() }
        // 去掉一个句号（法文、西班牙文的模板以句号结尾）。
        if t.last == "." || t.last == "。" { t = t.dropLast() }
        while t.last?.isWhitespace == true { t = t.dropLast() }
        let endsIncoming = incomingMissMarkers.contains { t.hasSuffix($0) }
        if endsIncoming, !incomingMissExclusions.contains(where: { t.contains($0) }) {
            return .incomingMiss
        }
        if missMarkers.contains(where: { t.contains($0) }) { return .outgoingMiss }
        return .otherCombat
    }

    /// 是否为 ASCII 数字。
    static func isDigit(_ c: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(c.value)
    }
}
