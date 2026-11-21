// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用自己记下的状态（v1.1 设计 3.3 节），存在 `state.json`，与用户的 `config.json` 分开：
// - `config.json` 每次改动都重建热键规划并重算，每天写一次检查时刻不应触发这些事。
// - `config.json` 读取失败时整个会话不写盘，那种情况下「跳过此版本」仍应记得住。
// - `state.json` 丢了只是多检查一次更新。
//
// 全部字段用 decodeIfPresent：缺键取默认值。嵌套的记录（发布信息、待装的更新等）结构不符时整个解码失败，
// 由 `JSONStateStore.load()` 退回默认状态。

import Foundation

/// `state.json` 的顶层结构。
public struct AppState: Sendable, Equatable, Codable {
    /// 状态文件的版本，当前是 1。不是 1 时 `load()` 返回默认状态。
    public var stateVersion: Int
    /// 更新功能的记录。
    public var updates: UpdateState
    /// 诊断功能的记录。
    public var diagnostics: DiagnosticsState
    /// 已经补到配置里的一次性默认值（`OneTimeDefaults` 的 id），v1.2 新增，缺键时为空。
    public var appliedDefaults: [String]

    /// 当前的状态文件版本。
    public static let currentVersion = 1

    /// 用各字段建状态；全部取默认值时就是默认状态。
    public init(stateVersion: Int = AppState.currentVersion, updates: UpdateState = UpdateState(),
                diagnostics: DiagnosticsState = DiagnosticsState(), appliedDefaults: [String] = []) {
        self.stateVersion = stateVersion
        self.updates = updates
        self.diagnostics = diagnostics
        self.appliedDefaults = appliedDefaults
    }

    /// 缺键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stateVersion = try c.decodeIfPresent(Int.self, forKey: .stateVersion) ?? AppState.currentVersion
        updates = try c.decodeIfPresent(UpdateState.self, forKey: .updates) ?? UpdateState()
        diagnostics = try c.decodeIfPresent(DiagnosticsState.self, forKey: .diagnostics) ?? DiagnosticsState()
        appliedDefaults = try c.decodeIfPresent([String].self, forKey: .appliedDefaults) ?? []
    }
}

/// 更新功能的记录（8.4、8.5、9.3 节）。
public struct UpdateState: Sendable, Equatable, Codable {
    /// 最近一次得到服务器答复的时刻。
    public var lastCheckAt: Date?
    /// 上次答复的 ETag，有缓存的发布信息时随请求发出。
    public var etag: String?
    /// 上次解析出的发布信息，304 时用它继续判断。
    public var cachedRelease: ReleaseInfo?
    /// 被限流时可以再试的时刻。
    public var rateLimitedUntil: Date?
    /// 用户选了「跳过此版本」的版本号。
    public var skippedVersion: String?
    /// 已下载并核对过、等待安装的更新。
    public var prepared: PreparedUpdate?
    /// 最近一次安装的结果。
    public var lastInstall: InstallRecord?
    /// 上次安装换下来的旧包所在的目录，下次启动时删除。
    public var staleStagingPath: String?
    /// `cachedRelease` 与正在运行的版本之间各版本的说明（8.8 节），1.1.4 新增，缺键时为 nil。
    public var intermediateNotes: IntermediateReleaseNotes?

    /// 用各字段建记录，默认全部为空。
    public init(lastCheckAt: Date? = nil, etag: String? = nil, cachedRelease: ReleaseInfo? = nil,
                rateLimitedUntil: Date? = nil, skippedVersion: String? = nil, prepared: PreparedUpdate? = nil,
                lastInstall: InstallRecord? = nil, staleStagingPath: String? = nil,
                intermediateNotes: IntermediateReleaseNotes? = nil) {
        self.lastCheckAt = lastCheckAt
        self.etag = etag
        self.cachedRelease = cachedRelease
        self.rateLimitedUntil = rateLimitedUntil
        self.skippedVersion = skippedVersion
        self.prepared = prepared
        self.lastInstall = lastInstall
        self.staleStagingPath = staleStagingPath
        self.intermediateNotes = intermediateNotes
    }

    /// 缺键取 nil。其余字段结构不符时照旧整个解码失败（由 `load()` 退回默认状态）；只有 `intermediateNotes`
    /// 解不出来时单独丢掉：它只是显示用的缓存，不应连累「跳过此版本」、待装的更新等记录。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        cachedRelease = try c.decodeIfPresent(ReleaseInfo.self, forKey: .cachedRelease)
        rateLimitedUntil = try c.decodeIfPresent(Date.self, forKey: .rateLimitedUntil)
        skippedVersion = try c.decodeIfPresent(String.self, forKey: .skippedVersion)
        prepared = try c.decodeIfPresent(PreparedUpdate.self, forKey: .prepared)
        lastInstall = try c.decodeIfPresent(InstallRecord.self, forKey: .lastInstall)
        staleStagingPath = try c.decodeIfPresent(String.self, forKey: .staleStagingPath)
        intermediateNotes = try? c.decodeIfPresent(IntermediateReleaseNotes.self, forKey: .intermediateNotes)
    }
}

/// 一次安装的结果。
public struct InstallRecord: Sendable, Equatable, Codable {
    /// 要装的版本。
    public var version: String
    /// 安装前的版本。
    public var fromVersion: String
    /// 安装的时刻。
    public var at: Date
    /// 是否成功。
    public var succeeded: Bool
    /// 失败时 `UpdateError` 的名称，如 `checksumMismatch`。
    public var errorCode: String?

    /// 用各字段建记录。
    public init(version: String, fromVersion: String, at: Date, succeeded: Bool, errorCode: String? = nil) {
        self.version = version
        self.fromVersion = fromVersion
        self.at = at
        self.succeeded = succeeded
        self.errorCode = errorCode
    }
}

/// 诊断功能的记录（6.3 节）。
public struct DiagnosticsState: Sendable, Equatable, Codable {
    /// 检测到、用户还没有处理的崩溃。
    public var pendingCrash: PendingCrash?
    /// 用户选了「不报告」的会话编号，最多保留 20 个。
    public var dismissedSessionIDs: [String]

    /// `dismissedSessionIDs` 最多保留的个数。
    public static let maxDismissedSessions = 20

    /// 用各字段建记录，默认全部为空。
    public init(pendingCrash: PendingCrash? = nil, dismissedSessionIDs: [String] = []) {
        self.pendingCrash = pendingCrash
        self.dismissedSessionIDs = dismissedSessionIDs
    }

    /// 缺键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pendingCrash = try c.decodeIfPresent(PendingCrash.self, forKey: .pendingCrash)
        dismissedSessionIDs = try c.decodeIfPresent([String].self, forKey: .dismissedSessionIDs) ?? []
    }
}

/// 检测到的一次崩溃。
public struct PendingCrash: Sendable, Equatable, Codable {
    /// 崩溃的那次运行的会话编号。
    public var sessionID: String
    /// 那次运行的应用版本。
    public var appVersion: String
    /// 那次运行开始的时刻。
    public var startedAt: Date
    /// 检测到崩溃的时刻。
    public var detectedAt: Date
    /// 匹配到的崩溃报告的文件名，最新的在前。
    public var reportFileNames: [String]

    /// 用各字段建记录。
    public init(sessionID: String, appVersion: String, startedAt: Date, detectedAt: Date, reportFileNames: [String]) {
        self.sessionID = sessionID
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.detectedAt = detectedAt
        self.reportFileNames = reportFileNames
    }
}
