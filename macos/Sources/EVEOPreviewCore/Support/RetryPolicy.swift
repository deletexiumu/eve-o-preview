// SPDX-License-Identifier: GPL-3.0-or-later
//
// 捕获失败后的重试延迟（架构文档 6.3 节）：指数退避，封顶 8 秒。

import Foundation

/// 重试延迟策略。
public enum RetryPolicy {
    /// 延迟的上限，单位是秒。
    public static let maximumDelay = 8.0

    /// 第 attempt 次重试前的等待秒数：0.5、1、2、4、8，之后一直是 8 秒。
    ///
    /// attempt 从 1 起计数，与 `CaptureState.retrying(attempt:delay:)` 一致；小于 1 时按 1 处理。
    public static func delay(forAttempt attempt: Int) -> Double {
        let index = max(attempt, 1) - 1
        // 0.5 × 2^4 = 8 已到上限，指数超过 4 时直接返回上限，避免大数溢出。
        guard index < 4 else { return maximumDelay }
        return 0.5 * Double(1 << index)
    }
}
