// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的界面文字（docs/design-intel-translate.md 第 11 节）：「翻译」页、翻译浮窗的标题与状态行、失败的原因。
// 每种语言一个不含存储属性的结构体实现本协议（Localization/<语言>/TranslationStrings+<语言>.swift），
// 漏了一条时编译不过。带参数的文字写成函数。访问方式是 L10n.translation，按 L10n.language 每次访问时取。
// 第 11 节的 55 条之外另有 2 条：keyOptional（自定义接口的 Key 可不填）与 keychainError（钥匙串写入或删除失败）。
// 本文件末尾的扩展把失败、接口问题与队列状态换成文字，各语言共用。

import Foundation
import EVEOPreviewCore

/// 翻译域的文字。
protocol TranslationStrings: Sendable {
    // MARK: 页头与状态
    /// 页标题下的一句说明。
    var pageSubtitle: String { get }
    /// 总开关。
    var enableToggle: String { get }
    /// 状态行的标签。
    var statusLabel: String { get }
    /// 状态：未启用。
    var statusOff: String { get }
    /// 状态：就绪。
    var statusIdle: String { get }
    /// 状态：翻译中。
    var statusTranslating: String { get }
    /// 状态：几秒后重试，附原因。
    func statusWaiting(seconds: Int, reason: String) -> String
    /// 状态：已暂停，附原因。
    func statusBlocked(_ reason: String) -> String
    /// 「立即重试」按钮。
    var retryNow: String { get }

    // MARK: 失败的原因
    /// 没有接口地址。
    var failureMissingBaseURL: String { get }
    /// 没有模型名。
    var failureMissingModel: String { get }
    /// 接口地址的格式不对。
    var failureInvalidURL: String { get }
    /// 公网的 http 地址。
    var failureInsecureHTTP: String { get }
    /// 没有 Key。
    var failureMissingKey: String { get }
    /// 读不到钥匙串里的 Key。
    var failureKeychain: String { get }
    /// Key 无效，附状态码。
    func failureUnauthorized(status: Int) -> String
    /// 地址或模型名不对。
    var failureNotFound: String { get }
    /// 余额不足。
    var failureBalance: String { get }
    /// 请求被拒绝，附状态码与服务给的说明。
    func failureRejected(status: Int, message: String) -> String
    /// 限流或额度用完。
    var failureRateLimited: String { get }
    /// 服务出错，附状态码。
    func failureServer(status: Int) -> String
    /// 连不上。
    var failureNetwork: String { get }
    /// 答复的格式不对。
    var failureMalformed: String { get }
    /// 模型拒绝了这批消息。
    var failureRefused: String { get }
    /// 答复被截断。
    var failureTruncated: String { get }

    // MARK: 频道与目标语言
    /// 频道列表的说明。
    var channelsHelp: String { get }
    /// 目标语言一组的标题。
    var targetHeader: String { get }
    /// 「翻译成」。
    var targetLanguage: String { get }
    /// 「跟随界面语言」。
    var targetFollowUI: String { get }
    /// 「同时显示原文」。
    var showOriginal: String { get }
    /// 「只显示翻译过的消息」。
    var foreignOnly: String { get }

    // MARK: 模型服务
    /// 模型一组的标题。
    var modelHeader: String { get }
    /// 「服务」。
    var provider: String { get }
    /// 「其他（OpenAI 兼容接口）」。
    var providerCustom: String { get }
    /// 「接口地址」。
    var baseURL: String { get }
    /// 「模型名」。
    var model: String { get }
    /// 「API Key」。
    var apiKey: String { get }
    /// 「已保存在钥匙串」。
    var apiKeyStored: String { get }
    /// Key 输入框的占位文字。
    var apiKeyPlaceholder: String { get }
    /// 「保存」。
    var saveKey: String { get }
    /// 「删除 Key」。
    var deleteKey: String { get }
    /// 「这个服务不用 Key」。
    var keyNotRequired: String { get }
    /// 自定义接口：要 Key 时填写，不要时留空。
    var keyOptional: String { get }
    /// 钥匙串写入或删除失败，附 OSStatus。
    func keychainError(status: Int32) -> String
    /// 「测试」。
    var test: String { get }
    /// 「测试中…」。
    var testing: String { get }
    /// 测试成功，附译文。
    func testSucceeded(_ text: String) -> String
    /// 测试失败，附原因。
    func testFailed(_ reason: String) -> String

    // MARK: 缓存与说明
    /// 译文缓存一组的标题。
    var cacheHeader: String { get }
    /// 缓存的条数。
    func cacheCount(_ count: Int) -> String
    /// 「清空缓存」。
    var clearCache: String { get }
    /// 页尾的隐私说明。
    var privacyNote: String { get }
    /// 页尾的费用说明。
    var costNote: String { get }

    // MARK: 浮窗
    /// 浮窗标题，附角色名。
    func overlayTitle(_ character: String) -> String
    /// 状态行：没有设置翻译频道。
    var statusNoChannels: String { get }
    /// 状态行：近 48 小时里，活动角色在所选的每个翻译频道都没有日志文件（EVE 没有写入）。channels 是频道的显示名。
    func statusNoLogFiles(_ channels: [String]) -> String
    /// 等待翻译的状态词。
    var pending: String { get }
    /// 翻译失败的状态词。
    var failed: String { get }
}

extension L10n {
    /// 翻译域的文字。`switch` 不写 `default`：以后加语言时编译器会指出这里要补。
    static var translation: any TranslationStrings {
        switch L10n.language {
        case .en: return TranslationStringsEN()
        case .zh: return TranslationStringsZH()
        case .ru: return TranslationStringsRU()
        case .ja: return TranslationStringsJA()
        case .ko: return TranslationStringsKO()
        case .fr: return TranslationStringsFR()
        case .de: return TranslationStringsDE()
        case .es: return TranslationStringsES()
        }
    }
}

extension TranslationStrings {
    /// 接口设置问题的文字。
    func issueText(_ issue: TranslationEndpointIssue) -> String {
        switch issue {
        case .missingBaseURL: return failureMissingBaseURL
        case .missingModel: return failureMissingModel
        case .invalidURL: return failureInvalidURL
        case .insecureRemoteHTTP: return failureInsecureHTTP
        }
    }

    /// 失败原因的文字。rejected 的说明只在这里出现，不写进日志（7.5 节）。
    func failureText(_ failure: TranslationFailure) -> String {
        switch failure {
        case .notConfigured(let issue): return issueText(issue)
        case .missingKey: return failureMissingKey
        case .keychainUnavailable: return failureKeychain
        case .unauthorized(let status): return failureUnauthorized(status: status)
        case .notFound: return failureNotFound
        case .insufficientBalance: return failureBalance
        case .rejected(let status, let message): return failureRejected(status: status, message: message)
        case .rateLimited: return failureRateLimited
        case .server(let status): return failureServer(status: status)
        case .network: return failureNetwork
        case .malformedAnswer: return failureMalformed
        case .refused: return failureRefused
        case .truncated: return failureTruncated
        }
    }

    /// 队列状态的文字；now 是墙上时钟的秒数，用来算还要等几秒。
    func statusText(_ status: TranslationStatus, now: Double) -> String {
        switch status {
        case .off: return statusOff
        case .idle: return statusIdle
        case .translating: return statusTranslating
        case .waiting(let until, let reason):
            let seconds = Int(max(0, (until - now).rounded(.up)))
            return statusWaiting(seconds: seconds, reason: failureText(reason))
        case .blocked(let reason): return statusBlocked(failureText(reason))
        }
    }
}
