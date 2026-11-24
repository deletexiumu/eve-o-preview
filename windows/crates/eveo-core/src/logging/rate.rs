// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志的限速，对应 macOS 的 LogRateLimiter.swift（docs/macos/design-v1.1.md 5.2 节）：令牌桶，
// 容量 200 条，每秒补 50 条。桶空时丢弃记录并计数；恢复后第一条放行的记录带上丢弃的条数，
// 由调用方先写一行 `… dropped N lines`。它只防止某处循环写日志把 5 个文件冲掉，不是为了省 I/O。
// 时间用调用方给的单调时钟秒数，所以能用固定的数字测试。

//! 文件日志的限速。

/// 一条记录的放行结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Admission {
    /// 写入。
    Write,
    /// 写入；在它之前已丢弃了这么多条，应先写一行说明。
    WriteAfterDropping(u64),
    /// 丢弃。
    Drop,
}

/// 令牌桶。不是线程安全的，由调用方在锁内使用。
#[derive(Debug, Clone)]
pub struct LogRateLimiter {
    /// 桶的容量，也是开始时的令牌数。
    capacity: f64,
    /// 每秒补充的令牌数。
    refill_per_second: f64,
    /// 现有的令牌数。
    tokens: f64,
    /// 上一次补充的时刻；第一次调用前是 None。
    last_refill: Option<f64>,
    /// 上一次放行以来丢弃的条数。
    dropped: u64,
}

impl Default for LogRateLimiter {
    /// 设计的取值：容量 200 条，每秒补 50 条。
    fn default() -> Self {
        Self::new(200, 50.0)
    }
}

impl LogRateLimiter {
    /// 建一个满的桶。容量小于 1 时按 1；补充速度为负时按 0。
    pub fn new(capacity: u32, refill_per_second: f64) -> Self {
        let capacity = f64::from(capacity.max(1));
        Self {
            capacity,
            refill_per_second: refill_per_second.max(0.0),
            tokens: capacity,
            last_refill: None,
            dropped: 0,
        }
    }

    /// 判断时刻 uptime（单调时钟的秒数）到来的一条记录能否写入。时间不前进（或倒退）时不补充令牌。
    pub fn admit(&mut self, uptime: f64) -> Admission {
        self.refill(uptime);
        if self.tokens < 1.0 {
            self.dropped += 1;
            return Admission::Drop;
        }
        self.tokens -= 1.0;
        match std::mem::take(&mut self.dropped) {
            0 => Admission::Write,
            count => Admission::WriteAfterDropping(count),
        }
    }

    /// 按距上一次补充的时间补充令牌，不超过容量。
    fn refill(&mut self, uptime: f64) {
        let Some(last) = self.last_refill else {
            self.last_refill = Some(uptime);
            return;
        };
        let elapsed = uptime - last;
        if elapsed > 0.0 {
            self.tokens = (self.tokens + elapsed * self.refill_per_second).min(self.capacity);
            self.last_refill = Some(uptime);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 连续放行到容量为止，之后丢弃并计数；补充后第一条带上丢弃的条数。
    #[test]
    fn drops_and_reports() {
        let mut limiter = LogRateLimiter::new(3, 1.0);
        for _ in 0..3 {
            assert_eq!(limiter.admit(0.0), Admission::Write);
        }
        assert_eq!(limiter.admit(0.0), Admission::Drop);
        assert_eq!(limiter.admit(0.5), Admission::Drop);
        // 过了 1 秒（从 0 算起补 1 个令牌，0.5 秒时已补 0.5）。
        assert_eq!(limiter.admit(1.0), Admission::WriteAfterDropping(2));
        assert_eq!(limiter.admit(1.0), Admission::Drop);
        // 时间倒退不补充。
        assert_eq!(limiter.admit(0.0), Admission::Drop);
        // 补满也不超过容量。
        limiter.admit(100.0);
        for _ in 0..2 {
            assert_eq!(limiter.admit(100.0), Admission::Write);
        }
        assert_eq!(limiter.admit(100.0), Admission::Drop);
    }
}
