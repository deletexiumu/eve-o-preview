// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一条日志记录与它在文件里的写法，对应 macOS 的 LogRecord.swift 与 LogLineFormatter.swift
// （docs/macos/design-v1.1.md 5.2 节）：
// - 一条记录一行：`2026-11-21T04:05:06.789Z ERROR [Capture] 文字`，时间是 UTC，精确到毫秒。
// - 文字里的换行与回车写成 `\n`、`\r`，一条记录只占一行；超过 4,096 个字符的部分换成 `…[truncated]`。
// - 隐私：Rust 没有 os.Logger 那样的插值隐私标记，约定由调用方不把角色名、窗口标题、消息正文等放进文字；
//   确实要标出「这里有一个值」时用 `Private`，它显示成 `<private>`。

//! 日志记录与一行的写法。

use std::fmt;

use super::LogLevel;
use crate::support::StringEnum;

/// 一行的上限（字符数，不含行尾）。
pub const MAX_LINE_LENGTH: usize = 4096;

/// 超过上限时接在截断处的标记。
const TRUNCATED: &str = "…[truncated]";

/// 一条日志记录。
#[derive(Debug, Clone, PartialEq)]
pub struct LogRecord {
    /// 时间，UTC，1970 年以来的秒数。
    pub time: f64,
    /// 级别。
    pub level: LogLevel,
    /// 模块名，如 `Capture`、`Chat`。
    pub category: String,
    /// 文字（不含私有值）。
    pub text: String,
}

/// 不写进日志的值：显示成 `<private>`，只表明这里有一个值。
pub struct Private<T>(pub T);

impl<T> fmt::Display for Private<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<private>")
    }
}

impl LogRecord {
    /// 文件里的一行（不含行尾的换行）。
    pub fn line(&self) -> String {
        let level = self.level.raw().to_uppercase();
        let mut line = format!("{} {level} [{}] ", utc_timestamp(self.time), self.category);
        // 换行与回车写成转义，一条记录只占一行；其他控制字符原样保留（制表符等不影响分行）。
        for ch in self.text.chars() {
            match ch {
                '\n' => line.push_str("\\n"),
                '\r' => line.push_str("\\r"),
                _ => line.push(ch),
            }
        }
        truncate(line)
    }
}

/// 超过上限时截断并接上标记；按字符截断，不会切开多字节字符。
fn truncate(line: String) -> String {
    let Some((cut, _)) = line.char_indices().nth(MAX_LINE_LENGTH) else {
        return line;
    };
    let mut kept = line[..cut].to_owned();
    kept.push_str(TRUNCATED);
    kept
}

/// UTC 时间：`2026-11-21T04:05:06.789Z`。早于 1970 年或不是有限数的时间按 0 写。
pub fn utc_timestamp(time: f64) -> String {
    crate::support::time::iso8601_millis(time)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 一条记录。
    fn record(text: &str) -> LogRecord {
        LogRecord {
            time: 1_763_697_906.789,
            level: LogLevel::Error,
            category: "Capture".to_owned(),
            text: text.to_owned(),
        }
    }

    /// 时间、级别与模块名的写法与 macOS 相同。
    #[test]
    fn line_layout() {
        assert_eq!(
            record("失败").line(),
            "2025-11-21T04:05:06.789Z ERROR [Capture] 失败"
        );
        assert_eq!(utc_timestamp(0.0), "1970-01-01T00:00:00.000Z");
        assert_eq!(utc_timestamp(f64::NAN), "1970-01-01T00:00:00.000Z");
        // 闰年的 2 月 29 日。
        assert_eq!(utc_timestamp(1_709_164_800.0), "2024-02-29T00:00:00.000Z");
    }

    /// 换行转义；超长截断，不切开多字节字符。
    #[test]
    fn escapes_and_truncates() {
        assert!(record("a\nb\rc").line().ends_with("a\\nb\\rc"));
        let long = record(&"字".repeat(5000)).line();
        assert_eq!(long.chars().count(), MAX_LINE_LENGTH + TRUNCATED.chars().count());
        assert!(long.ends_with(TRUNCATED));
        assert_eq!(format!("角色 {}", Private("Pilot")), "角色 <private>");
    }
}
