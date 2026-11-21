// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天日志的模型（docs/design-intel-translate.md 5.2 节）：文件头、消息行、上报的事件、跟踪服务的状态与请求。
// 另含位置记录的两个类型 CharacterLocation、LocationSource：它们被 state.json 的 ChatState 引用，所以由 WP-0
// 建在这里；位置的规则（LocationTracker）归 WP-B（6.2 节）。
// 时间都是 UTC，1970 年以来的秒数；聊天日志里的时间就是 UTC（EVE 时间）。

import Foundation

/// 聊天频道的种类，由文件头的 Channel ID 决定（`ChatLogParser.channelKind`）。
public enum ChatChannelKind: String, Sendable, Equatable {
    /// 本地频道，ID 是 `local`。
    case local
    /// 军团频道，ID 是 `corp`。
    case corp
    /// 联盟频道，ID 是 `alliance`。
    case alliance
    /// 舰队频道，ID 以 `fleet_` 开头。
    case fleet
    /// 玩家建的频道，ID 以 `player_` 开头。
    case player
    /// 私聊，ID 以 `private_` 开头。不跟踪，也不列出。
    case privateChat
    /// 其他 ID，或没有 ID。
    case other
}

/// 聊天日志文件头的解析结果（`ChatLogParser.parseHeader`）。
public struct ChatLogHeader: Sendable, Equatable {
    /// 文件头的 Channel ID；没有这一行时为 nil。
    public var channelID: String?
    /// 文件头的 Channel Name。
    public var channelName: String?
    /// 文件头的收听者（角色名）。
    public var listener: String?
    /// 是否已读完文件头；false 表示还没读到第二条分隔线（文件刚建出来）。
    public var isComplete: Bool

    /// 用各字段建一个结果。
    public init(channelID: String?, channelName: String?, listener: String?, isComplete: Bool) {
        self.channelID = channelID
        self.channelName = channelName
        self.listener = listener
        self.isComplete = isComplete
    }

    /// 按 Channel ID 判断的频道种类。
    public var kind: ChatChannelKind { ChatLogParser.channelKind(id: channelID) }
}

/// 解析出的一行消息（`ChatLogParser.parseLine`）。
public struct ChatLine: Sendable, Equatable {
    /// 日志里的时间，UTC，1970 年以来的秒数。
    public var time: Double
    /// 说话人，已去掉首尾空白。
    public var speaker: String
    /// 正文，已经过 `ChatLogParser.plainText` 清理。
    public var text: String
    /// 说话人是 EVE 系统（在 `ChatLogParser.systemSpeakers` 里）。
    public var isSystem: Bool

    /// 用各字段建一行。
    public init(time: Double, speaker: String, text: String, isSystem: Bool) {
        self.time = time
        self.speaker = speaker
        self.text = text
        self.isSystem = isSystem
    }
}

/// 跟踪服务上报的一条消息：一行消息加上它所在文件的收听者与频道。
public struct ChatMessage: Sendable, Equatable {
    /// 文件头的收听者。浮窗只显示活动角色的消息。
    public var listener: String
    /// 文件头的 Channel ID。
    public var channelID: String
    /// 文件头的 Channel Name。
    public var channelName: String
    /// 日志里的时间，UTC。
    public var time: Double
    /// 说话人。
    public var speaker: String
    /// 正文。
    public var text: String
    /// 是否为启动时从已有内容里补读的消息。
    public var isBackfill: Bool

    /// 用各字段建一条消息。
    public init(listener: String, channelID: String, channelName: String, time: Double,
                speaker: String, text: String, isBackfill: Bool) {
        self.listener = listener
        self.channelID = channelID
        self.channelName = channelName
        self.time = time
        self.speaker = speaker
        self.text = text
        self.isBackfill = isBackfill
    }
}

/// 位置线索的来源（5.6 节）。
public enum LocationHintSource: String, Sendable, Equatable, Codable {
    /// `Local` 聊天日志的系统消息。
    case localChannel
    /// 游戏日志里类别是 None 的行（跳跃与离站）。
    case gameLog
}

/// 一条位置线索：日志里能说明角色所在星系的一行，只带原文，不查星图数据。
public struct LocationHint: Sendable, Equatable {
    /// 角色名（文件头的收听者）。
    public var character: String
    /// 日志里的时间，UTC。
    public var time: Double
    /// 来源。
    public var source: LocationHintSource
    /// `Local` 的系统消息正文，或游戏日志 (None) 行的正文（已去掉标记）。
    public var text: String
    /// 是否为启动时回读到的线索。
    public var isBackfill: Bool

    /// 用各字段建一条线索。
    public init(character: String, time: Double, source: LocationHintSource, text: String, isBackfill: Bool) {
        self.character = character
        self.time = time
        self.source = source
        self.text = text
        self.isBackfill = isBackfill
    }
}

/// 跟踪服务上报的事件。
public enum ChatLogEvent: Sendable, Equatable {
    /// 一条非系统消息。
    case message(ChatMessage)
    /// 一条位置线索。
    case locationHint(LocationHint)
}

/// 聊天日志跟踪服务的状态。
public enum ChatLogStatus: Sendable, Equatable {
    /// 没有在跟踪（两个功能都关着）。
    case stopped
    /// 正在跟踪：目录与跟踪的文件数。
    case watching(directory: String, followedFiles: Int)
    /// 候选目录都不存在，关联值是第一个候选目录。
    case directoryNotFound(path: String)
    /// 没有读取权限。
    case accessDenied(path: String)
}

/// 交给跟踪服务的请求（`ChatLogMonitor.start`）。请求相同时跟踪服务不做任何事。
public struct ChatLogRequest: Sendable, Equatable {
    /// 配置的日志目录（`general.eveLogDirectory`）；nil 表示自动查找。
    public var logDirectory: String?
    /// 要跟踪的频道：预警频道与翻译频道的并集。
    public var channels: [ChannelRef]
    /// 预警开启时为真：另外读 `Local` 与游戏日志里的位置线索。
    public var followsLocation: Bool
    /// 补读多少秒以内的消息。
    public var backfillSeconds: Double
    /// 已打开的功能（预警、翻译）。跟踪服务不读它，只用来判断请求变没变（9.2 节：功能的开关变了算请求变了）。
    public var enabledFeatures: Set<OverlayKind>

    /// 用各字段建一个请求。enabledFeatures 不给时为空（探针等只跟踪、不分功能的调用方）。
    public init(logDirectory: String?, channels: [ChannelRef], followsLocation: Bool, backfillSeconds: Double,
                enabledFeatures: Set<OverlayKind> = []) {
        self.logDirectory = logDirectory
        self.channels = channels
        self.followsLocation = followsLocation
        self.backfillSeconds = backfillSeconds
        self.enabledFeatures = enabledFeatures
    }

    /// 从 old 换成 new 时要不要重建跟踪服务（并清空两个功能的缓冲）：一边是 nil 另一边不是，
    /// 或日志目录、频道、是否跟踪位置、已打开的功能有一项不同时要。只有 backfillSeconds 不同时不要（审查 m6）：
    /// 补读只在启动时用一次，「保留最近」变短时预警缓冲在刷新时按新的时长修剪，变长时不补读更早的消息。
    /// 已打开的功能要比（复审 R3）：翻译的频道全在预警的频道里时，打开翻译只改变 backfillSeconds，
    /// 不比的话不会重建、不会补读，翻译浮窗从空白开始。
    public static func requiresRestart(from old: ChatLogRequest?, to new: ChatLogRequest?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        return old.logDirectory != new.logDirectory || old.channels != new.channels
            || old.followsLocation != new.followsLocation || old.enabledFeatures != new.enabledFeatures
    }
}

/// 日志目录里发现的一个频道，给设置界面的「从日志添加」用（5.3 节）。
public struct DiscoveredChannel: Sendable, Equatable, Identifiable {
    /// Channel ID。
    public var id: String
    /// Channel Name。
    public var name: String
    /// 频道种类。
    public var kind: ChatChannelKind
    /// 有几个角色的日志里出现过。
    public var listeners: Int
    /// 最近一个文件的修改时间，1970 年以来的秒数。
    public var lastModified: Double

    /// 用各字段建一项。
    public init(id: String, name: String, kind: ChatChannelKind, listeners: Int, lastModified: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.listeners = listeners
        self.lastModified = lastModified
    }

    /// 写进配置用的频道：名字与 ID 都存。
    public var ref: ChannelRef { ChannelRef(name: name, id: id) }
}

// MARK: - 位置记录（类型由 WP-0 建，规则归 WP-B 的 LocationTracker）

/// 位置记录的来源：两个自动来源加手动设置（6.2 节）。
public enum LocationSource: String, Sendable, Equatable, Codable {
    /// `Local` 聊天日志的系统消息。
    case localChannel
    /// 游戏日志的跳跃与离站记录。
    case gameLog
    /// 用户在「预警」页手动设置。
    case manual
}

/// 一个角色所在的星系，以及这条记录的时间与来源。手动设置的记录存进 state.json。
public struct CharacterLocation: Sendable, Equatable, Codable {
    /// 星系 ID。
    public var systemID: Int
    /// 记录的时间，UTC，1970 年以来的秒数。
    public var time: Double
    /// 来源。
    public var source: LocationSource

    /// 用各字段建一条记录。
    public init(systemID: Int, time: Double, source: LocationSource) {
        self.systemID = systemID
        self.time = time
        self.source = source
    }
}
