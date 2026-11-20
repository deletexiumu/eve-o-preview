// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志一行的格式（v1.1 设计 5.2 节）：`<UTC 时间，毫秒> <级别大写> [<category>] <文字>`，
// 如 `2026-11-21T04:05:06.789Z ERROR [Capture] 打开流失败`。
//
// - 文字里的换行与回车写成两个字符 `\n`、`\r`，一条记录只占一行。按 Unicode 标量处理，
//   因为 Swift 把 "\r\n" 当成一个 Character，按 Character 替换会漏掉它。
// - 整行最多 4,096 个字符（Character），超出时截短，末尾换成 `…[truncated]`，截短后的整行仍不超过上限。
// - 时间用纯算术从 Unix 时间换算成公历日期，不用 DateFormatter：任何线程都能调用，也不受时区与区域设置影响。

import Foundation

/// 把日志记录排成文件里的一行。
public enum LogLineFormatter {
    /// 一行最多的字符数（含截短标记）。
    public static let maxLineLength = 4096
    /// 截短时放在行尾的标记。
    public static let truncationMarker = "…[truncated]"

    /// 一条记录一行：`2026-11-21T04:05:06.789Z ERROR [Capture] 文字`。换行与回车写成 `\n`、`\r`。
    ///
    /// 返回的文字不带行尾的换行符，换行符由 `RotatingLogFile.append` 加。
    public static func line(for record: LogRecord) -> String {
        let prefix = "\(timestamp(record.date)) \(record.level.rawValue.uppercased()) [\(escaped(record.category))] "
        return truncated(prefix + escaped(record.text))
    }

    /// UTC 时间，精确到毫秒：`2026-11-21T04:05:06.789Z`。
    ///
    /// 毫秒按四舍五入取：`Date` 的小数部分是二进制浮点数，直接截断会把 .789 写成 .788。
    public static func timestamp(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        // 向下取整的除法，1970 年以前的时刻也能得到正确的日期与非负的毫秒。
        let (seconds, ms) = floorDivide(totalMs, 1000)
        let (days, secondOfDay) = floorDivide(seconds, 86_400)
        let (year, month, day) = civilDate(daysSinceEpoch: days)
        let hour = secondOfDay / 3600
        let minute = secondOfDay % 3600 / 60
        let second = secondOfDay % 60
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T"
            + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2) + "." + pad(ms, 3) + "Z"
    }

    /// 把换行与回车写成 `\n`、`\r` 两个字符。逐个 Unicode 标量处理，"\r\n" 写成 `\r\n` 四个字符。
    static func escaped(_ text: String) -> String {
        // 绝大多数日志没有换行，直接返回原串，省一次复制。
        guard text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": scalars.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": scalars.append(contentsOf: #"\r"#.unicodeScalars)
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// 超过 `maxLineLength` 个字符时截短，末尾放截短标记，结果正好 `maxLineLength` 个字符。
    static func truncated(_ line: String) -> String {
        // utf8 长度不超过上限时字符数也一定不超过，省掉逐个数字符。
        guard line.utf8.count > maxLineLength, line.count > maxLineLength else { return line }
        return String(line.prefix(maxLineLength - truncationMarker.count)) + truncationMarker
    }

    /// 向下取整的除法：余数总是非负。
    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }

    /// 从 1970-01-01 起的天数换算成公历的年、月、日。
    ///
    /// 算法取自 Howard Hinnant 的 `civil_from_days`（公有领域）：以 3 月 1 日为一年之始，
    /// 400 年一个周期，周期内的天数与年份一一对应。
    private static func civilDate(daysSinceEpoch: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097                                              // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365   // [0, 399]
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // [0, 365]
        let monthIndex = (5 * dayOfYear + 2) / 153                                     // [0, 11]，0 是 3 月
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /// 左侧补零到 width 位。负数不会出现在这里（年份早于公元 1 年的日志不存在）。
    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
