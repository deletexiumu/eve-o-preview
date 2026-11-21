// SPDX-License-Identifier: GPL-3.0-or-later
//
// 文件日志的启动接入（v1.1 设计 4.4 节第 2、3 步，5.2、5.5 节）。
// `start` 在读配置之前调用，读配置的错误才能进文件：装上 `FileLogSink`、写一行会话头、装未捕获异常的处理函数。
// `apply(level:)` 在读完配置后与「详细日志」开关变化时调用，设置写进文件的最低级别。
//
// - 目录默认是 `~/Library/Logs/EVE-O Preview/`，环境变量 `EVEO_LOG_DIR` 可覆盖（`~` 会展开）。
//   演示模式与正式运行写同一个目录。
// - 会话头含会话编号的前 8 位（与 session.json 里的编号相同，见 `SessionTracker.currentSessionID`）、
//   版本、构建标签、提交号、签名类别、macOS 版本与架构。
// - 未捕获的 Objective-C 异常：写一条 fault（名称与原因），冲刷日志，然后照常崩溃。
//   不给 SIGSEGV 等崩溃信号装处理函数：信号处理函数里不能安全地写日志，崩溃现场由系统的崩溃报告记录。
// - 重复启动后自己退出的实例在 main.swift 里就已退出，不会走到这里；EVEOProbe 与单元测试不调这里，只写系统日志。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform
import os

/// 文件日志的启动与级别设置。
enum LogBootstrap {
    /// 已经装过文件日志。`start` 只应调一次，重复调用时直接返回，不装第二个输出目标。
    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// 装上文件日志（目录可由 `EVEO_LOG_DIR` 覆盖）、写会话头、装未捕获异常的处理函数。启动时调一次。
    static func start(environment: AppEnvironment, isFakeMode: Bool) {
        let isFirstCall = started.withLock { started in
            defer { started = true }
            return !started
        }
        guard isFirstCall else { return }
        let layout = LogFileLayout(directory: logDirectory())
        PlatformLog.install(FileLogSink(layout: layout, policy: .standard))
        AppLog.logger("Session").info("\(sessionHeader(environment: environment, isFakeMode: isFakeMode), privacy: .public)")
        NSSetUncaughtExceptionHandler { exception in
            AppLog.logger("App").fault("未捕获的异常：\(exception.name.rawValue, privacy: .public)：\(exception.reason ?? "", privacy: .public)")
            PlatformLog.flush()
        }
    }

    /// 设置写进文件的最低级别（`general.logLevel`，只会是 info 或 debug）。系统日志不受影响。
    static func apply(level: LogLevel) {
        PlatformLog.setMinimumLevel(level)
        AppLog.logger("Session").info("文件日志级别：\(level.rawValue, privacy: .public)")
    }

    /// 日志目录：`EVEO_LOG_DIR` 不为空时用它，否则用默认目录。
    static func logDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["EVEO_LOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return LogFileLayout.defaultDirectory()
    }

    /// 会话头的文字。全部是公开的值：版本与签名类别不含个人信息。
    ///
    /// 例：`会话开始 6f1d3c2a：版本 1.1.0，构建 1.1.0，提交 abc1234，签名 release，macOS Version 27.0.1 (Build 26A434)，arm64，演示模式 false`
    static func sessionHeader(environment: AppEnvironment, isFakeMode: Bool) -> String {
        let session = String(SessionTracker.currentSessionID.prefix(8)).lowercased()
        let commit = environment.buildCommit ?? "-"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "会话开始 \(session)：版本 \(environment.version)，构建 \(environment.buildLabel)，提交 \(commit)，"
            + "签名 \(environment.signature.kind.rawValue)，macOS \(system)，\(processArchitecture)，演示模式 \(isFakeMode)"
    }

    /// 本进程的架构（编译时决定；在 Rosetta 下运行的 x86_64 进程写 x86_64）。
    private static var processArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
