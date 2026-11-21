// SPDX-License-Identifier: GPL-3.0-or-later
//
// 角色名的比较（docs/design-intel-translate.md 6.2 节、6.5 节，做法同反馈文档 7.5 节）：
// 先按原样比较，没有相等的再不区分大小写比较。日志文件头里的收听者与窗口标题里的角色名大小写可能不同；
// 原样相等的优先，是为了两个只差大小写的角色名仍能分开。

import Foundation

/// 角色名的比较规则。
public enum CharacterNameMatch {
    /// 在 candidates 里找与 name 对应的那个：先原样相等，再不区分大小写相等；都没有时返回 nil。
    /// 不区分大小写的命中有多个时取 candidates 里靠前的。
    public static func match<S: Sequence>(_ name: String, in candidates: S) -> String? where S.Element == String {
        var folded: String?
        for candidate in candidates {
            if candidate == name { return candidate }
            if folded == nil, candidate.caseInsensitiveCompare(name) == .orderedSame { folded = candidate }
        }
        return folded
    }

    /// 以角色名为键的字典里取 name 的值：键先原样比较，再不区分大小写比较（按键排序后取第一个，结果稳定）。
    public static func value<V>(for name: String, in table: [String: V]) -> V? {
        if let exact = table[name] { return exact }
        return key(for: name, in: table).flatMap { table[$0] }
    }

    /// 以角色名为键的字典里与 name 对应的键：先原样，再不区分大小写（按键排序后取第一个）。
    public static func key<V>(for name: String, in table: [String: V]) -> String? {
        if table[name] != nil { return name }
        return table.keys.sorted().first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
