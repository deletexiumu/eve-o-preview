// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天翻译的模型（docs/macos/design-intel-translate.md 7.2 节）：服务预设与解析后的接口、失败的分类、消息的阶段、
// HTTP 请求与答复、缓存条目、队列的状态。这些类型由 WP-0 冻结；翻译的规则（预设表、判断、提示词、请求与答复、
// 缓存、队列、显示）在 WP-C 的各个文件里。
// TranslationHTTPRequest、TranslationHTTPResponse、TranslationTransportError、TranslationCacheEntry、
// TranslationStatus 被 WP-0 的平台协议与应用代码引用，所以放在这里（第 12 节）。

import Foundation

/// 模型服务的接口种类。
public enum TranslationAPIKind: String, Sendable, Equatable {
    /// OpenAI 兼容的 `/chat/completions`。
    case openAICompatible
    /// Anthropic 的 Messages API。
    case anthropic
}

/// 一个服务预设：内置的接口地址、默认模型与接口种类（7.3 节）。
public struct TranslationProviderPreset: Sendable, Equatable {
    /// 预设编号。
    public var id: TranslationProviderID
    /// 不翻译的服务名；「自定义」一项由界面文字提供。
    public var displayName: String
    /// 接口种类。
    public var kind: TranslationAPIKind
    /// 预设地址；`custom` 为空。
    public var baseURL: String
    /// 预设模型；`custom` 为空。
    public var model: String
    /// 是否要 API Key。
    public var requiresKey: Bool

    /// 用各字段建一个预设。
    public init(id: TranslationProviderID, displayName: String, kind: TranslationAPIKind, baseURL: String,
                model: String, requiresKey: Bool) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.requiresKey = requiresKey
    }
}

/// 解析好的接口：设置与预设合并后的结果（`TranslationProviders.resolve`）。
public struct TranslationEndpoint: Sendable, Equatable {
    /// 预设编号。
    public var provider: TranslationProviderID
    /// 接口种类。
    public var kind: TranslationAPIKind
    /// 接口地址，末尾没有 `/`。
    public var baseURL: URL
    /// 模型名。
    public var model: String
    /// 是否要 API Key。
    public var requiresKey: Bool

    /// 用各字段建一个接口。
    public init(provider: TranslationProviderID, kind: TranslationAPIKind, baseURL: URL, model: String,
                requiresKey: Bool) {
        self.provider = provider
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.requiresKey = requiresKey
    }
}

/// 接口设置不能用的原因（7.3 节）。
public enum TranslationEndpointIssue: Error, Sendable, Equatable {
    /// 没有地址（设置与预设都为空）。
    case missingBaseURL
    /// 没有模型名。
    case missingModel
    /// 解不开，或带用户名、查询串、片段，或协议不是 http、https。
    case invalidURL
    /// http 只允许本机与局域网地址。
    case insecureRemoteHTTP
}

/// 一次翻译失败的原因（7.5 节）。
public enum TranslationFailure: Error, Sendable, Equatable {
    /// 接口设置不能用。
    case notConfigured(TranslationEndpointIssue)
    /// 预设要 Key，但没有 Key。
    case missingKey
    /// 读钥匙串要用户确认，或被拒绝。
    case keychainUnavailable
    /// 401、403：Key 无效或没有权限。
    case unauthorized(status: Int)
    /// 404：地址或模型名不对。
    case notFound
    /// 402：余额不足。
    case insufficientBalance
    /// 3xx 与其他 4xx：请求不被接受。message 只显示在界面上，不写进日志。
    case rejected(status: Int, message: String)
    /// 429：限流，retryAfter 是答复给的等待秒数；答复没给或解析不了时为 nil，由队列按连续次数加倍等待。
    case rateLimited(retryAfter: Double?)
    /// 408、409、5xx：服务出错。
    case server(status: Int)
    /// 连不上、超时、答复过大。
    case network(String)
    /// 答复不是要求的格式。
    case malformedAnswer
    /// 模型拒绝了这批消息。
    case refused
    /// 答复被截断。
    case truncated

    /// 设置有问题：改设置或手动重试前不再请求（7.5 节表里「是否致命」一栏）。
    public var isFatal: Bool {
        switch self {
        case .notConfigured, .missingKey, .keychainUnavailable, .unauthorized, .notFound, .insufficientBalance,
             .rejected:
            return true
        case .rateLimited, .server, .network, .malformedAnswer, .refused, .truncated:
            return false
        }
    }

    /// 非致命错误下次请求前至少等多久（秒）。
    ///
    /// 限流取答复给的秒数，没给时取 30 秒；服务出错与网络失败取 30 秒（连续失败时的加倍由队列负责）；
    /// 只影响这一批的失败（格式不对、被拒绝、被截断）与致命的失败是 0。
    public var retryDelay: Double {
        switch self {
        case .rateLimited(let seconds): return seconds ?? 30
        case .server, .network: return 30
        default: return 0
        }
    }
}

/// 消息不用交给模型的原因（7.6 节）。
public enum TranslationSkipReason: Sendable, Equatable {
    /// 说话人是 EVE 系统。
    case systemSpeaker
    /// 正文为空。
    case empty
    /// 已经是目标语言。
    case sameLanguage
    /// 只有星系、舰船与情报用语，按术语替换即可。
    case termsOnly
}

/// 一条消息在翻译流程里的阶段。
public enum TranslationPhase: Sendable, Equatable {
    /// 不用模型。rendered 是只做术语替换后的文字，与原文相同时为 nil。
    case skipped(TranslationSkipReason, rendered: String?)
    /// 不排队（补读的旧消息、非活动角色的消息）。
    case off
    /// 排队等待发送。
    case pending
    /// 在途的一批里。
    case inFlight
    /// 已翻译。sourceLanguage 是模型判断的原文语言代码。
    case done(text: String, sourceLanguage: String?)
    /// 这一条翻译失败，不再自动重试（用户点重试时重新排队）。
    case failed
}

/// 翻译缓冲里的一条消息。
public struct TranslationItem: Sendable, Equatable, Identifiable {
    /// 在整个缓冲里递增的编号。
    public var id: UInt64
    /// 原消息。
    public var message: ChatMessage
    /// 当前阶段。
    public var phase: TranslationPhase

    /// 用各字段建一条。
    public init(id: UInt64, message: ChatMessage, phase: TranslationPhase) {
        self.id = id
        self.message = message
        self.phase = phase
    }
}

/// 一条译文。
public struct TranslatedText: Sendable, Equatable {
    /// 译文。
    public var text: String
    /// 模型判断的原文语言代码（小写，至多 8 个字符）；模型没给时为 nil。
    public var sourceLanguage: String?

    /// 用译文与原文语言建一条。
    public init(text: String, sourceLanguage: String?) {
        self.text = text
        self.sourceLanguage = sourceLanguage
    }
}

// MARK: - HTTP 请求与答复（7.4 节）

/// 交给传输层的 HTTP 请求，方法总是 POST。
public struct TranslationHTTPRequest: Sendable, Equatable {
    /// 完整的地址。
    public var url: URL
    /// 请求头。含 Key 的请求头不应写进任何日志。
    public var headers: [String: String]
    /// JSON 请求体。
    public var body: Data
    /// 超时，单位是秒。
    public var timeoutSeconds: Double

    /// 用各字段建一个请求。
    public init(url: URL, headers: [String: String], body: Data, timeoutSeconds: Double) {
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

/// 传输层交回的答复。
public struct TranslationHTTPResponse: Sendable, Equatable {
    /// HTTP 状态码。
    public var status: Int
    /// 答复头，键是小写。
    public var headers: [String: String]
    /// 答复正文。
    public var body: Data

    /// 用各字段建一个答复。
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// 传输层的失败。
public enum TranslationTransportError: Error, Sendable, Equatable {
    /// 连不上、超时或其他发送失败，关联值是系统给的说明。
    case network(String)
    /// 答复正文超过 1 MiB。
    case tooLarge
}

// MARK: - 缓存与队列

/// 译文缓存里的一条（7.8 节），存进 translation-cache.json。没有说话人与频道名。
public struct TranslationCacheEntry: Sendable, Equatable, Codable {
    /// 目标语言代码。
    public var target: String
    /// 原文的缓存键（`TranslationRules.cacheKey`）。
    public var key: String
    /// 译文。
    public var text: String
    /// 模型判断的原文语言代码。
    public var sourceLanguage: String?

    /// 用各字段建一条。
    public init(target: String, key: String, text: String, sourceLanguage: String?) {
        self.target = target
        self.key = key
        self.text = text
        self.sourceLanguage = sourceLanguage
    }
}

/// 翻译队列的状态（7.6 节），显示在翻译浮窗与「翻译」页的状态行。
public enum TranslationStatus: Sendable, Equatable {
    /// 功能没开。
    case off
    /// 没有在途的请求。
    case idle
    /// 有一批在途。
    case translating
    /// 限流或临时故障，到 until（墙上时钟的秒数）时自动重试。
    case waiting(until: Double, reason: TranslationFailure)
    /// 设置有问题，等用户处理。
    case blocked(TranslationFailure)
}
