// SPDX-License-Identifier: GPL-3.0-or-later
//
// 交给输出目标的日志记录与输出目标的协议（v1.1 设计 5.1 节）。
// 记录里的文字已经把私有值换成 `<private>`，输出目标不会拿到私有值。

import Foundation

/// 一条已渲染的日志记录。
public struct LogRecord: Sendable, Equatable {
    /// 记录产生的时刻。
    public var date: Date
    /// 级别。
    public var level: LogLevel
    /// 模块名，与 `os.Logger` 的 category 相同，如 `Capture`。
    public var category: String
    /// 已把私有值换成 `<private>` 的文字。
    public var text: String

    /// 用各字段建一条记录。
    public init(date: Date, level: LogLevel, category: String, text: String) {
        self.date = date
        self.level = level
        self.category = category
        self.text = text
    }
}

/// 输出目标：接收日志记录的一方，如文件日志（`FileLogSink`）。
///
/// 方法可以在任何线程调用，实现自己负责串行化。
public protocol LogSink: Sendable {
    /// 写一条记录。不应抛错，也不应长时间阻塞调用线程。
    func write(_ record: LogRecord)
    /// 把已写的记录交给内核（不要求落盘）。退出前与未捕获的异常处理里调用。
    func flush()
}
