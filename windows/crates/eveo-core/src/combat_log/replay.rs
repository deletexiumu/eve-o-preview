// SPDX-License-Identifier: GPL-3.0-or-later
//
// 历史回放的过滤（反馈文档 7.3 节），对应 macOS 的 CombatLogReplayGuard.swift。
// 文件被晚跟踪时（目录访问恢复、16 个文件的上限腾出名额）会从头读起，已有的旧行不该触发提醒。
// 判断只依赖日志行里的时间（UTC）与调用方传入的「接入时刻」，不读系统时钟，所以可以直接单元测试。
// 只用于「从头读起的首次读取」：正常跟踪新增内容时不经过这里。

//! 历史回放的过滤规则。

use super::parser::log_time;

/// 容差（秒）。大于 2 秒的保险定时器间隔加 1 秒的时间戳粒度，再留余量：接入时刻前后刚写入的行不会被误丢。
pub const TOLERANCE: f64 = 5.0;

/// 一行是否保留。
///
/// 行里的时间（UTC）不早于 `attached_at - tolerance` 时保留，早于时丢弃（边界值保留）。
/// 时间解析不出来（不是日志行，或日期不合法）时丢弃：这样的行无法证明是新写入的，按「宁可漏报，不误报」处理。
/// `attached_at` 是开始跟踪这个文件的时刻（1970 年以来的秒数）。
pub fn should_keep(line: &str, attached_at: f64, tolerance: f64) -> bool {
    log_time(line).is_some_and(|time| time >= attached_at - tolerance)
}
