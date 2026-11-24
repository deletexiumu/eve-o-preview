// SPDX-License-Identifier: GPL-3.0-or-later
//
// 日志的纯逻辑部分，对应 macOS 的 Logging/：级别（配置要用）、一行的写法、限速、带轮转的文件。
// 全局的日志入口（锁、最低级别、panic 时刷盘）在 eveo-app-core 的 log 模块。

//! 日志。

pub mod format;
pub mod rate;
pub mod rotating;

use std::cmp::Ordering;

use crate::support::StringEnum;

string_enum! {
    /// 日志级别，按严重程度从低到高：`debug < info < notice < error < fault`。
    pub enum LogLevel {
        /// 排查问题时才看的细节。默认不写进文件。
        Debug => "debug",
        /// 启动、退出、客户端增减、设置变化等。
        Info => "info",
        /// 不常见但不是错误的情况。
        Notice => "notice",
        /// 操作失败，功能受影响。
        Error => "error",
        /// 程序自身的错误，如未处理的 panic。
        Fault => "fault",
    }
}

impl LogLevel {
    /// 级别在 `ALL` 里的位置，越大越严重。
    fn rank(self) -> usize {
        Self::ALL.iter().position(|&level| level == self).unwrap_or(0)
    }
}

impl PartialOrd for LogLevel {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for LogLevel {
    /// 按严重程度比较。
    fn cmp(&self, other: &Self) -> Ordering {
        self.rank().cmp(&other.rank())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 严重程度的顺序。
    #[test]
    fn ordering() {
        assert!(LogLevel::Debug < LogLevel::Info);
        assert!(LogLevel::Error < LogLevel::Fault);
        assert_eq!(LogLevel::ALL.iter().max(), Some(&LogLevel::Fault));
    }
}
