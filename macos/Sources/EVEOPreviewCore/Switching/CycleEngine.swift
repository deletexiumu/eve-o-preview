// SPDX-License-Identifier: GPL-3.0-or-later
//
// 循环顺序（架构文档 5.4 节），语义与上游 FindNextClientInCycleGroup 相同。

import Foundation

/// 循环方向。
public enum CycleDirection: Sendable, Hashable {
    /// 按成员顺序向后。
    case forward
    /// 按成员顺序向前。
    case backward
}

/// 循环组与登录客户端的循环计算。
public enum CycleEngine {
    /// 在 members 里从 active 的位置按方向找下一个可用成员。
    ///
    /// - 可用指同时满足「在 running 里」和「不在 skipped 里」；找完一圈（绕回一次）为止。
    /// - active 不在 members 里（或为 nil）时，从该方向的第一个成员开始找（前进从头，后退从尾）。
    /// - active 自己被跳过时，仍以它的位置为起点。
    /// - 没有可用成员时返回 nil；唯一可用的成员就是 active 时返回它自己。
    /// - 重复成员由 `ConfigValidator` 在读入与修改配置时去掉（5.4 节），引擎不处理重复。
    ///   直接传入重复项时，active 以第一次出现的位置为起点，结果不保证能走遍全部成员。
    ///
    /// - Returns: 下一个成员的角色名。
    public static func next(in members: [String], direction: CycleDirection, active: String?,
                            running: Set<String>, skipped: Set<String>) -> String? {
        guard !members.isEmpty else { return nil }
        let count = members.count
        let step = direction == .forward ? 1 : -1
        let start: Int
        if let active, let index = members.firstIndex(of: active) {
            start = index
        } else {
            // 起点设在第一个成员「之前」，这样第一步正好落在该方向的第一个成员上。
            start = direction == .forward ? -1 : count
        }
        for offset in 1...count {
            let index = ((start + step * offset) % count + count) % count
            let candidate = members[index]
            if running.contains(candidate) && !skipped.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// 在登录客户端之间循环。
    ///
    /// pids 先按升序排列，从 activePID 的位置按方向取下一个并绕回；activePID 不在其中时取该方向的第一个
    /// （前进取最小，后退取最大）；空数组返回 nil；只有一个时返回它自己。
    public static func nextLoginClient(pids: [Int32], activePID: Int32?, direction: CycleDirection) -> Int32? {
        let sorted = pids.sorted()
        guard !sorted.isEmpty else { return nil }
        guard let activePID, let index = sorted.firstIndex(of: activePID) else {
            return direction == .forward ? sorted.first : sorted.last
        }
        let step = direction == .forward ? 1 : -1
        return sorted[((index + step) % sorted.count + sorted.count) % sorted.count]
    }
}
