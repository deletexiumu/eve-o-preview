// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志文件头的解析（反馈文档 7.5 节）。文件头是 5 行：分隔线、标题、收听者、进程开始时间、分隔线（L5）。
// 登录界面阶段建的文件没有收听者一行（L3），这类文件不跟踪。
// 文件与角色只按收听者对应；文件名里的数字后缀不用来识别角色。

import Foundation

/// 文件头的解析结果。
public struct CombatLogHeader: Sendable, Equatable {
    /// 收听者（角色名）；nil 表示文件头里没有收听者，或文件头还不完整。
    public var listener: String?
    /// 是否已读完文件头。false 表示还没读到第二条分隔线（文件刚建出来）。
    public var isComplete: Bool

    /// 用收听者与完整与否建一个结果。
    public init(listener: String?, isComplete: Bool) {
        self.listener = listener
        self.isComplete = isComplete
    }
}

/// 文件头的解析器。
public enum CombatLogHeaderParser {
    /// 至多看文件开头的这么多行。读满仍没有第二条分隔线时，视为没有收听者的完整文件头。
    public static let maxHeaderLines = 12

    /// 解析文件开头的各行（不含换行符）。规则：
    /// 1. 第一条全是 `-` 的行是文件头的开始，第二条是结束。
    /// 2. 两条分隔线之间的行以 `listenerLabels` 里的某个标签开头、后接半角或全角冒号时，冒号后的部分是收听者。
    /// 3. 没有匹配的标签，但两条分隔线之间正好有 3 行时，取第 2 行冒号后的部分（应对标签表以外的语言）。
    /// 4. 读了 `maxHeaderLines` 行还没有第二条分隔线时，`isComplete` 为真，`listener` 为 nil。
    public static func parse(_ lines: [String]) -> CombatLogHeader {
        var inside: [String]?
        for raw in lines.prefix(maxHeaderLines) {
            let line = raw.trimmingCharacters(in: whitespace)
            if isSeparator(line) {
                if let between = inside {
                    return CombatLogHeader(listener: listener(in: between), isComplete: true)
                }
                inside = []
                continue
            }
            inside?.append(line)
        }
        // 没读到第二条分隔线：行数已满说明文件头不是预期的形式，否则是文件还没写完。
        return CombatLogHeader(listener: nil, isComplete: lines.count >= maxHeaderLines)
    }

    // MARK: - 内部

    /// 去首尾空白时用的字符集，含行首可能残留的 BOM。
    static let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// 是否为分隔线：非空且全是 `-`。
    static func isSeparator(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == "-" }
    }

    /// 从两条分隔线之间的行里取收听者。
    static func listener(in lines: [String]) -> String? {
        for line in lines {
            for label in CombatLogCatalog.listenerLabels {
                guard line.hasPrefix(label) else { continue }
                // 标签后接冒号；法文排版习惯在冒号前加空格，这里允许冒号前有空白。
                let rest = line.dropFirst(label.count).drop { $0 == " " || $0 == "\u{00A0}" }
                guard let first = rest.first, first == ":" || first == "：" else { continue }
                return nonEmpty(rest.dropFirst())
            }
        }
        // 标签表以外的语言：文件头正好 3 行（标题、收听者、开始时间）时，第 2 行就是收听者。
        guard lines.count == 3 else { return nil }
        let second = lines[1]
        guard let colon = second.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        return nonEmpty(second[second.index(after: colon)...])
    }

    /// 去掉首尾空白，空串返回 nil。
    static func nonEmpty(_ text: Substring) -> String? {
        let value = text.trimmingCharacters(in: whitespace)
        return value.isEmpty ? nil : value
    }
}
