// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息的分段、人数与人名（docs/design-intel-translate.md 6.4 节）。
// - parse 的规则归 WP-B。WP-0 的空实现返回「全文是一段 plain」的结果（IntelReport.plain）。
// - remainder(of:) 由 WP-0 写完整，WP-B 不改它：翻译用它判断「只有术语」的消息（7.6 节）。

import Foundation

/// 预警消息的解析器。
public enum IntelParser {
    /// 一个人名至多几个词；人名的总词数超过它时，remainder 把人名也算进剩下的文字。
    public static let maxPilotWords = 3

    /// 用算好的术语匹配解析一条消息。WP-0 的空实现：全文是一段 plain。
    public static func parse(_ text: String, matches: [TermMatch]) -> IntelReport {
        IntelReport.plain(text)
    }

    /// 用星图数据的匹配器解析一条消息。
    public static func parse(_ text: String, data: EVEStaticData) -> IntelReport {
        parse(text, matches: data.matcher.matches(in: text))
    }

    /// 去掉认出的术语、人数与推断的人名后，剩下的文字（给「不用模型」的判断用）。
    ///
    /// 做法：按顺序取全部 plain 段，各段去掉首尾空白，空段丢掉，其余用一个空格连起来。
    /// 人名的总词数（各 pilot 段按空白切词后相加）超过 `maxPilotWords` 时，pilot 段也按原来的位置算进去：
    /// 这时消息多半是一句话，应交给模型翻译。只看 segments，不看 `pilots` 数组，手工构造的结果不会两处不一致。
    public static func remainder(of report: IntelReport) -> String {
        let pilotWords = report.segments.reduce(0) { total, segment in
            guard segment.kind == .pilot else { return total }
            return total + segment.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        let includesPilots = pilotWords > maxPilotWords
        var parts: [String] = []
        for segment in report.segments {
            switch segment.kind {
            case .plain:
                break
            case .pilot where includesPilots:
                break
            default:
                continue
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }
}
