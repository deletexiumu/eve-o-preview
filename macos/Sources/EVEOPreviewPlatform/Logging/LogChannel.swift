// SPDX-License-Identifier: GPL-3.0-or-later
//
// 日志入口（v1.1 设计 5.1 节）。`LogChannel` 的方法名与 `os.Logger` 相同，调用处的插值写法不变，
// 只是消息类型换成 Core 的 `LogMessage`，这样应用能拿到拼好的文字，交给文件日志等输出目标。
//
// 每次写日志做三件事：
// 1. 渲染一次不含私有值的文字（`rendered(includingPrivate: false)`）。
// 2. 交给 `os.Logger`，写成 `"\(text, privacy: .public)"`，级别一一对应（notice 对应 `.default`）。
//    环境变量 `EVEO_LOG_PRIVATE=1` 时系统日志改用含私有值的文字，供开发时在「控制台」里看。
// 3. 级别不低于 `setMinimumLevel` 设的级别时，把记录交给每个已安装的输出目标。输出目标始终拿不到私有值。
//
// debug 级别在没有输出目标要、系统日志也没打开 debug 时不求值，所以参数是 `@autoclosure`。

import Foundation
import EVEOPreviewCore
import os

/// 一个模块的日志入口。方法名与 os.Logger 相同，调用处的写法不变。
public struct LogChannel: Sendable {
    /// 模块名，与 `os.Logger` 的 category 相同。
    public let category: String
    /// 写系统日志的对象。
    private let logger: Logger
    /// 用来查询系统日志是否打开了 debug 级别。
    private let osLog: OSLog

    /// 按 subsystem 与模块名建入口。只由 `PlatformLog.logger(_:)` 调用。
    init(subsystem: String, category: String) {
        self.category = category
        osLog = OSLog(subsystem: subsystem, category: category)
        logger = Logger(osLog)
    }

    /// 排查问题时才看的细节。
    public func debug(_ message: @autoclosure () -> LogMessage) {
        emit(.debug, message)
    }

    /// 启动、退出、状态变化等常规信息。
    public func info(_ message: @autoclosure () -> LogMessage) {
        emit(.info, message)
    }

    /// 不常见但不是错误的情况。系统日志里是 `default` 级别。
    public func notice(_ message: @autoclosure () -> LogMessage) {
        emit(.notice, message)
    }

    /// 操作失败，功能受影响。
    public func error(_ message: @autoclosure () -> LogMessage) {
        emit(.error, message)
    }

    /// 程序自身的错误。
    public func fault(_ message: @autoclosure () -> LogMessage) {
        emit(.fault, message)
    }

    /// 渲染一次，写系统日志，再按级别交给输出目标。
    private func emit(_ level: LogLevel, _ message: () -> LogMessage) {
        let sinks = PlatformLog.sinks(accepting: level)
        // debug 在两边都不要时直接返回，不求值插值（有的插值要拼数组或调 String(describing:)）。
        if level == .debug, sinks.isEmpty, !osLog.isEnabled(type: .debug) { return }
        let rendered = message()
        let text = rendered.rendered(includingPrivate: false)
        let systemText = PlatformLog.includePrivateInSystemLog ? rendered.rendered(includingPrivate: true) : text
        logger.log(level: LogChannel.systemType(for: level), "\(systemText, privacy: .public)")
        guard !sinks.isEmpty else { return }
        let record = LogRecord(date: Date(), level: level, category: category, text: text)
        for sink in sinks {
            sink.write(record)
        }
    }

    /// 日志级别对应的系统日志类型。
    private static func systemType(for level: LogLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}

/// 平台层的日志常量与输出目标的登记处。全部方法可以在任何线程调用。
public enum PlatformLog {
    /// 日志的 subsystem，与应用的 bundle id 相同。
    public static let subsystem = "io.github.deletexiumu.eveopreview-macos"

    /// 环境变量 `EVEO_LOG_PRIVATE=1` 时，系统日志里写出私有值（只用于开发）。进程内不变，启动时读一次。
    static let includePrivateInSystemLog = ProcessInfo.processInfo.environment["EVEO_LOG_PRIVATE"] == "1"

    /// 锁内的状态：已安装的输出目标与交给它们的最低级别。
    private struct State: Sendable {
        var sinks: [any LogSink] = []
        var minimumLevel: LogLevel = .info
    }

    /// 输出目标与级别。日志可能从任何线程写，所以用锁保护。
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// 按模块名建一个日志入口。
    ///
    /// - Parameter category: 模块名，如 `Capture`、`Hotkeys`。
    public static func logger(_ category: String) -> LogChannel {
        LogChannel(subsystem: subsystem, category: category)
    }

    /// 加一个输出目标。启动时由 App 调一次；不调时只写系统日志。
    public static func install(_ sink: any LogSink) {
        state.withLock { $0.sinks.append(sink) }
    }

    /// 低于这个级别的记录不交给 install 进来的输出目标；系统日志不受影响。
    public static func setMinimumLevel(_ level: LogLevel) {
        state.withLock { $0.minimumLevel = level }
    }

    /// 让每个输出目标把已写的记录交给内核。退出前与未捕获的异常处理里调用。
    public static func flush() {
        for sink in state.withLock({ $0.sinks }) {
            sink.flush()
        }
    }

    /// 应当收到这一级别记录的输出目标；级别低于下限或没有输出目标时返回空数组。
    /// 在锁外调用输出目标，避免输出目标自己写日志时重入这把锁。
    static func sinks(accepting level: LogLevel) -> [any LogSink] {
        state.withLock { state in
            level >= state.minimumLevel ? state.sinks : []
        }
    }
}
