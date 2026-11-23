// SPDX-License-Identifier: GPL-3.0-or-later
//
// 历史回放的过滤（反馈文档 7.3 节）。
// 文件被晚跟踪时（目录访问权限恢复、16 个文件的上限腾出名额）会从头读起，已有的旧行不该触发提醒。
// 判断只依赖日志行里的时间（UTC）与调用方传入的「接入时刻」，不读系统时钟，所以可以直接单元测试。
// 只用于「从头读起的首次读取」：正常跟踪新增内容时不经过这里。

import Foundation

/// 历史回放的过滤规则。
public enum CombatLogReplayGuard {
    /// 容差（秒）。大于 2 秒的保险定时器间隔加 1 秒的时间戳粒度，再留余量：
    /// 接入时刻前后刚写入的行不会被误丢。
    public static let tolerance = 5.0

    /// 一行是否保留。
    ///
    /// 规则：行里的时间（UTC）不早于 `attachedAt - tolerance` 时保留，早于时丢弃（边界值保留）。
    /// 时间解析不出来（不是日志行，或日期不合法）时丢弃：这样的行无法证明是新写入的，
    /// 按「宁可漏报，不误报」处理；真正的日志行时间形式固定，不会走到这个分支。
    ///
    /// - Parameters:
    ///   - line: 一行日志原文。
    ///   - attachedAt: 开始跟踪这个文件的时刻（1970 年以来的秒数），由调用方传入。
    ///   - tolerance: 容差（秒），默认 `CombatLogReplayGuard.tolerance`。
    public static func shouldKeep(_ line: String, attachedAt: Double, tolerance: Double = tolerance) -> Bool {
        guard let time = CombatLogParser.logTime(line) else { return false }
        return time >= attachedAt - tolerance
    }
}
