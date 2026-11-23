// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跳数（docs/macos/design-intel-translate.md 6.6 节）：只按星门连接算，不考虑跳桥、虫洞与安全等级的路线偏好。
// distances 从出发星系做一次广度优先，得到 maxJumps 跳以内每个星系的跳数；IntelFeedController 按
// 「出发星系与 maxJumps」缓存这张表，出发星系变了才重算。表至多遍历已知空间的 5,485 个星系（S5）。

import Foundation

/// 到一个星系的跳数。
public enum JumpDistance: Sendable, Equatable {
    /// 跳数；0 表示就在出发星系。
    case jumps(Int)
    /// 超过上限，或与出发星系不在同一片星门网里。
    case beyond(limit: Int)
    /// 目标星系没有任何星门（虫洞星系等）。
    case unreachable
    /// 不知道从哪里算。
    case unknownOrigin
}

/// 星门图上的跳数。
public enum JumpGraph {
    /// 广度优先，返回 maxJumps 跳以内每个星系的跳数，含出发星系（0）。maxJumps 小于 0 时按 0 算。
    public static func distances(from origin: Int, maxJumps: Int, in data: EVEStaticData) -> [Int: Int] {
        var table = [origin: 0]
        var frontier = [origin]
        var depth = 0
        while depth < maxJumps, !frontier.isEmpty {
            depth += 1
            var next: [Int] = []
            for system in frontier {
                for neighbor in data.neighbors(of: system) where table[neighbor] == nil {
                    table[neighbor] = depth
                    next.append(neighbor)
                }
            }
            frontier = next
        }
        return table
    }

    /// 到目标星系的跳数。table 为 nil 时是 unknownOrigin；表里有目标时是 jumps；目标没有任何星门时是
    /// unreachable；其余是 beyond(limit: maxJumps)。
    public static func distance(to target: Int, table: [Int: Int]?, maxJumps: Int,
                                in data: EVEStaticData) -> JumpDistance {
        guard let table else { return .unknownOrigin }
        if let jumps = table[target] { return .jumps(jumps) }
        if data.neighbors(of: target).isEmpty { return .unreachable }
        return .beyond(limit: maxJumps)
    }
}
