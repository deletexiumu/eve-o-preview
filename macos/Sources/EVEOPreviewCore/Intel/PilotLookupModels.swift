// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的值类型（docs/macos/design-intel-translate.md 6.9 节、6.10 节）。
// - PilotLookupOutcome：一个名字在 ESI 的结果：查到角色、与游戏对象重名、没查到。
// - PilotLookupAnswer：一次请求的结果，按比较键 key(for:) 存各名字的结果，另带 ESI 的错误额度。
// - PilotLookupFailure：一次请求失败的原因，决定排队时等多久、要不要重发。
// - PilotNameCacheEntry：人名缓存文件里的一项，只存查到的角色。
// - PilotLookupStatus：核对的状态，给「预警」页与问题报告。
// 名字是消息正文的一部分，这些类型都不写进日志。

import Foundation

/// 一个名字在 ESI 的结果。
public enum PilotLookupOutcome: Sendable, Equatable {
    /// ESI 有同名的角色；name 是 ESI 返回的写法。
    case matched(characterID: Int, name: String)
    /// 有同名的角色，但同名的还有物品、星系等游戏对象，消息里指的多半是后者。
    case ambiguous
    /// 没有同名的角色。
    case notFound
}

/// 一次请求的结果。
public struct PilotLookupAnswer: Sendable, Equatable {
    /// 各名字的结果。键是 `key(for:)` 的结果；请求里的每个名字各有一项。
    public var outcomes: [String: PilotLookupOutcome]
    /// 答复头 `X-Esi-Error-Limit-Remain`：本时段还能出错的次数。没有这个头时为 nil。
    public var errorLimitRemain: Int?
    /// 答复头 `X-Esi-Error-Limit-Reset`：错误额度多少秒后重置。没有这个头时为 nil。
    public var errorLimitReset: Int?

    /// 用各字段建结果。
    public init(outcomes: [String: PilotLookupOutcome], errorLimitRemain: Int? = nil, errorLimitReset: Int? = nil) {
        self.outcomes = outcomes
        self.errorLimitRemain = errorLimitRemain
        self.errorLimitReset = errorLimitReset
    }

    /// 名字的比较键：去掉首尾空白，连续的空白并成一个空格，转成小写。
    /// ESI 按整个名字匹配、不区分大小写，缓存、去重与答复的对照都用这个键。
    public static func key(for name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}

/// 一次请求失败的原因。失败的请求不产生任何结果，缓存不变。
public enum PilotLookupFailure: Error, Sendable, Equatable {
    /// 连不上、超时、答复过大。关联值是给日志的简短说明，不含名字。
    case network(String)
    /// 420、429：ESI 要求等这么多秒再发。
    case rateLimited(retryAfter: Double)
    /// 408、5xx：服务端的问题，稍后重发。
    case server(status: Int)
    /// 3xx 与其他 4xx：请求本身有问题，不重发。
    case rejected(status: Int)
    /// 200，但正文不是预期的 JSON。
    case malformedAnswer
}

/// 人名缓存文件里的一项（`pilot-names.json` 的 `entries`）。
public struct PilotNameCacheEntry: Sendable, Equatable, Codable {
    /// 比较键，`PilotLookupAnswer.key(for:)` 的结果。
    public var key: String
    /// 角色 ID。
    public var characterID: Int
    /// ESI 返回的写法。
    public var name: String
    /// 查到的时刻，UTC，1970 年以来的秒数。
    public var time: Double

    /// 用各字段建一项。
    public init(key: String, characterID: Int, name: String, time: Double) {
        self.key = key
        self.characterID = characterID
        self.name = name
        self.time = time
    }
}

/// 人名核对的状态。
public enum PilotLookupStatus: Sendable, Equatable {
    /// 预警或「联网核对人名」关着。
    case off
    /// 没有在途的请求，也不在等待。
    case idle
    /// 有一批名字在途。
    case resolving
    /// 被限流或连续失败，等到这个时刻（墙上时钟，1970 年以来的秒数）再发。
    case waiting(until: Double)

    /// 写进问题报告的代号：off、idle、resolving、waiting。不含等待的时刻。
    public var code: String {
        switch self {
        case .off: "off"
        case .idle: "idle"
        case .resolving: "resolving"
        case .waiting: "waiting"
        }
    }
}
