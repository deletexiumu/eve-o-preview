// SPDX-License-Identifier: GPL-3.0-or-later
//
// 会话标记与崩溃报告候选的值类型（v1.1 设计 6.1 节）。
// 每次运行在 `session.json` 里留一个会话标记；正常退出时标为已结束。
// 规则（解码、归类）在 `SessionMarkerRules`（WP-1），匹配在 `CrashReportMatcher`。

import Foundation

/// 一次运行的会话标记，存在 `~/Library/Application Support/EVE-O Preview/session.json`。
public struct SessionMarker: Sendable, Equatable, Codable {
    /// 标记格式的版本，当前是 1。
    public var markerVersion: Int
    /// 本次运行的编号（UUID 字符串）。
    public var sessionID: String
    /// 本次运行的进程 PID。
    public var pid: Int32
    /// 应用版本（`CFBundleShortVersionString`）。
    public var appVersion: String
    /// 构建标签（`EVEOBuildLabel`）。
    public var buildLabel: String
    /// 开始运行的时刻。
    public var startedAt: Date
    /// 是否经过了正常的退出流程。
    public var endedCleanly: Bool

    /// 用各字段建会话标记。
    public init(markerVersion: Int = 1, sessionID: String, pid: Int32, appVersion: String, buildLabel: String,
                startedAt: Date, endedCleanly: Bool) {
        self.markerVersion = markerVersion
        self.sessionID = sessionID
        self.pid = pid
        self.appVersion = appVersion
        self.buildLabel = buildLabel
        self.startedAt = startedAt
        self.endedCleanly = endedCleanly
    }
}

/// 上一次运行的归类（6.1 节的规则表）。
public enum PreviousRunOutcome: Sendable, Equatable {
    /// 没有标记，或标记读不懂。
    case noRecord
    /// 上一次正常结束。
    case clean
    /// 上一个实例还在（重新启动的交接超时），不算异常。
    case stillRunning(SessionMarker)
    /// 上一次没有正常结束。是否崩溃要看能否找到崩溃报告（6.2 节）。
    case abnormal(SessionMarker)
}

/// 崩溃报告目录里的一个候选文件。
public struct CrashReportCandidate: Sendable, Equatable {
    /// 文件名（不含目录）。
    public var fileName: String
    /// 文件的修改时间。
    public var modifiedAt: Date
    /// 文件大小，单位是字节。
    public var byteCount: Int
    /// 文件的第一行，最多 4,096 字节；读不到时是 nil。
    public var firstLine: String?

    /// 用各字段建候选文件。
    public init(fileName: String, modifiedAt: Date, byteCount: Int, firstLine: String?) {
        self.fileName = fileName
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
        self.firstLine = firstLine
    }
}
