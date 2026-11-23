// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志的输出目标（v1.1 设计 5.2 节）。
//
// - 一把 `OSAllocatedUnfairLock` 保护 `RotatingLogFile` 与 `LogRateLimiter`，在调用线程上同步 `write(2)`，
//   不经过队列：崩溃前最后一条日志已经交给了内核。一次写入约几微秒，鼠标事件监听的线程上也可以写。不调 `fsync`。
// - 限速：桶空时丢弃并计数，恢复后先写一行 `… dropped N lines`。
// - 连续 3 次写入失败后停止写文件，并向系统日志记一条 error。这条 error 在放开锁、标记停止之后才写：
//   它经 `PlatformLog` 又会回到本对象，那时已停止，直接返回，不会在锁内重入。
// - 行的格式化（时间、转义、截短）在锁外做，锁内只有限速判断与写入。

import Foundation
import EVEOPreviewCore
import os

/// 把日志记录写进带轮转的文件。方法可以在任何线程调用。
public final class FileLogSink: LogSink {
    /// 连续失败多少次后停止写文件。
    static let maxConsecutiveFailures = 3

    /// 锁内的状态。`RotatingLogFile` 不是线程安全的类，只在锁内使用。
    private struct State {
        let file: RotatingLogFile
        var limiter = LogRateLimiter()
        var consecutiveFailures = 0
        var stopped = false
    }

    /// 文件、限速与失败计数。状态里有非 Sendable 的 `RotatingLogFile`，所以用 `uncheckedState` 建锁，
    /// 并且只经 `withLockUnchecked` 访问：锁保证同一时刻只有一个线程碰它，它的引用也不会离开锁。
    private let state: OSAllocatedUnfairLock<State>
    /// 日志所在的目录，只用于停止时的那条 error。
    private let directoryPath: String

    /// 建输出目标。不碰磁盘，第一条记录到来时才建目录、打开文件。
    public init(layout: LogFileLayout, policy: LogRotationPolicy) {
        state = OSAllocatedUnfairLock(uncheckedState: State(file: RotatingLogFile(layout: layout, policy: policy)))
        directoryPath = layout.directory.path
    }

    /// 写一条记录。被限速丢弃或已停止时什么也不做。
    public func write(_ record: LogRecord) {
        let line = LogLineFormatter.line(for: record)
        let uptime = ProcessInfo.processInfo.systemUptime
        let failure: String? = state.withLockUnchecked { state in
            guard !state.stopped else { return nil }
            var lines: [String]
            switch state.limiter.admit(at: uptime) {
            case .drop:
                return nil
            case .write:
                lines = [line]
            case .writeAfterDropping(let count):
                let notice = LogRecord(date: record.date, level: .notice, category: "Log", text: "… dropped \(count) lines")
                lines = [LogLineFormatter.line(for: notice), line]
            }
            do {
                for item in lines {
                    try state.file.append(item)
                }
                state.consecutiveFailures = 0
                return nil
            } catch {
                state.consecutiveFailures += 1
                guard state.consecutiveFailures >= FileLogSink.maxConsecutiveFailures else { return nil }
                state.stopped = true
                state.file.close()
                return String(describing: error)
            }
        }
        // 锁外记录停止：这条 error 会经 PlatformLog 回到本对象，那时 stopped 已为真，直接返回。
        if let failure {
            PlatformLog.logger("FileLog").error("连续 \(FileLogSink.maxConsecutiveFailures) 次写日志文件失败，停止写文件：\(directoryPath, privacy: .public)，\(failure, privacy: .public)")
        }
    }

    /// 写入是不经缓冲的 `write(2)`，返回时已交给内核，所以这里没有要冲刷的数据。
    /// 取一次锁，保证正在别的线程上进行的写入已经完成。
    public func flush() {
        state.withLockUnchecked { _ in }
    }
}
