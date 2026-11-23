// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志的限速（v1.1 设计 5.2 节）：令牌桶，容量 200 条，每秒补 50 条。
// 桶空时丢弃记录并计数；恢复后第一条放行的记录带上丢弃的条数，由调用方先写一行 `… dropped N lines`。
// 它只防止某处循环写日志把 5 个文件冲掉，不是为了省 I/O。
//
// 时间用调用方给的单调时钟秒数（`ProcessInfo.systemUptime`），所以能用固定的数字测试。

import Foundation

/// 令牌桶。值类型，不是线程安全的；`FileLogSink` 在锁内使用。
public struct LogRateLimiter: Sendable {
    /// 一条记录的放行结果。
    public enum Admission: Sendable, Equatable {
        /// 写入。
        case write
        /// 写入；在它之前已丢弃了这么多条，应先写一行说明。
        case writeAfterDropping(Int)
        /// 丢弃。
        case drop
    }

    /// 桶的容量，也是开始时的令牌数。
    private let capacity: Double
    /// 每秒补充的令牌数。
    private let refillPerSecond: Double
    /// 现有的令牌数。
    private var tokens: Double
    /// 上一次补充的时刻；第一次调用前是 nil。
    private var lastRefill: Double?
    /// 上一次放行以来丢弃的条数。
    private var dropped = 0

    /// 建一个满的桶。
    ///
    /// - Parameters:
    ///   - capacity: 容量，即连续放行的最多条数。小于 1 时按 1。
    ///   - refillPerSecond: 每秒补充的条数。负数按 0。
    public init(capacity: Int = 200, refillPerSecond: Double = 50) {
        self.capacity = Double(max(1, capacity))
        self.refillPerSecond = max(0, refillPerSecond)
        tokens = self.capacity
    }

    /// 判断时刻 uptime（单调时钟的秒数）到来的一条记录能否写入。
    ///
    /// 时间不前进（或倒退）时不补充令牌。
    public mutating func admit(at uptime: Double) -> Admission {
        refill(at: uptime)
        guard tokens >= 1 else {
            dropped += 1
            return .drop
        }
        tokens -= 1
        guard dropped > 0 else { return .write }
        let count = dropped
        dropped = 0
        return .writeAfterDropping(count)
    }

    /// 按距上一次补充的时间补充令牌，不超过容量。
    private mutating func refill(at uptime: Double) {
        guard let last = lastRefill else {
            lastRefill = uptime
            return
        }
        let elapsed = uptime - last
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = uptime
    }
}
