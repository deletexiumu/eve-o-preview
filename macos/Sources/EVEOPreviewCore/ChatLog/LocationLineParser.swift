// SPDX-License-Identifier: GPL-3.0-or-later
//
// 位置线索的句式（docs/macos/design-intel-translate.md 5.6 节）：从一行日志里取出星系名的原文，不查星图数据。
// - Local 聊天日志的系统消息：取最后一个半角或全角冒号后面的部分。英文形式是 `Channel changed to Local : <星系>`（C7），
//   中文形式参考实现记为 `频道更换为本地：<星系>*`（V39）。规则只看冒号，不依赖措辞。
// - 游戏日志的 (None) 行：按下表的句式取目的星系。中文两种句式有本机样例（C15），英文两种没有（V32）。
//   | 中文跳跃 | 从<甲>跳到<乙>                               | `跳到` 之后到行尾             |
//   | 中文离站 | 正在从 <空间站> 离站进入 <星系> 恒星系。      | `离站进入` 与 `恒星系` 之间   |
//   | 英文跳跃 | Jumping from <甲> to <乙>                    | 最后一个 ` to ` 之后到行尾     |
//   | 英文离站 | Undocking from <空间站> to <星系> solar system. | 最后一个 ` to ` 与 ` solar system` 之间 |
//   句式不认识时返回 nil，由 LocationTracker 按正文里星系的个数兜底（规则见 LocationTracker.swift 文件头）。
// 取出的名称都去掉首尾空白、末尾的句号与 `*`（中文客户端在译名后加 `*`）。

import Foundation

/// 位置线索的句式解析。
public enum LocationLineParser {
    /// Local 的系统消息里的星系名：最后一个冒号后面的部分，去掉 `*` 与句号。没有冒号或名称为空时返回 nil。
    public static func systemName(fromLocalSystemLine text: String) -> String? {
        guard let colon = text.lastIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        return cleaned(text[text.index(after: colon)...])
    }

    /// 游戏日志 (None) 行里按已知句式取出的目的星系名；句式不认识或名称为空时返回 nil。
    /// text 是 `gameNote` 取出的正文（已去掉标记）。英文句式的比较不区分大小写。
    public static func systemName(fromGameNote text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 中文离站：「离站进入」与「恒星系」之间。先判断离站，因为离站句里没有「跳到」。
        if let start = body.range(of: "离站进入") {
            let tail = body[start.upperBound...]
            let end = tail.range(of: "恒星系")?.lowerBound ?? tail.endIndex
            return cleaned(tail[..<end])
        }
        // 中文跳跃：「跳到」之后到行尾。
        if let jump = body.range(of: "跳到", options: .backwards) {
            return cleaned(body[jump.upperBound...])
        }
        let lower = body.lowercased()
        // 英文离站：最后一个 " to " 与 " solar system" 之间。
        if lower.hasPrefix("undocking from "), let end = body.range(of: " solar system", options: [.caseInsensitive, .backwards]) {
            let head = body[..<end.lowerBound]
            guard let to = head.range(of: " to ", options: [.caseInsensitive, .backwards]) else { return nil }
            return cleaned(head[to.upperBound...])
        }
        // 英文跳跃：最后一个 " to " 之后到行尾。
        if lower.hasPrefix("jumping from "), let to = body.range(of: " to ", options: [.caseInsensitive, .backwards]) {
            return cleaned(body[to.upperBound...])
        }
        return nil
    }

    /// 取游戏日志一行的时间与正文：行的形式是 `[ 时间 ] (None) 正文`，类别不区分大小写。
    /// 正文用 `CombatLogParser.plainText` 去掉标记。类别不是 None 或不是日志行时返回 nil。
    public static func gameNote(_ line: String) -> (time: Double, text: String)? {
        guard let parts = CombatLogParser.split(line), parts.category == "none",
              let time = ChatLogParser.utcSeconds(parts.timestamp) else { return nil }
        return (time, CombatLogParser.plainText(parts.body))
    }

    /// 去掉首尾空白、末尾的句号（半角与全角）与 `*`，空串返回 nil。
    static func cleaned(_ text: Substring) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, last == "*" || last == "." || last == "。" {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while value.first == "*" { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
