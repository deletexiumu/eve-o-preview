// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的中文文字（docs/design-intel-translate.md 第 11 节）。用词按第 11 节的词表与第 17 节的术语：
// 翻译频道、浮窗、模型服务、译文缓存；macOS 的官方名称「钥匙串」。

import Foundation

/// 翻译域的中文文字。
struct TranslationStringsZH: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "把指定频道里其他语言的消息翻译成目标语言。" }
    var enableToggle: String { "显示翻译浮窗" }
    var statusLabel: String { "状态" }
    var statusOff: String { "未启用" }
    var statusIdle: String { "就绪" }
    var statusTranslating: String { "翻译中" }
    func statusWaiting(seconds: Int, reason: String) -> String { "\(seconds) 秒后重试：\(reason)" }
    func statusBlocked(_ reason: String) -> String { "已暂停：\(reason)" }
    var retryNow: String { "立即重试" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "还没有填写接口地址" }
    var failureMissingModel: String { "还没有填写模型名" }
    var failureInvalidURL: String { "接口地址的格式不对" }
    var failureInsecureHTTP: String { "http 地址只能用于本机或局域网" }
    var failureMissingKey: String { "还没有填写 API Key" }
    var failureKeychain: String { "读不到钥匙串里的 Key，请在「翻译」页重新保存" }
    func failureUnauthorized(status: Int) -> String { "Key 无效（HTTP \(status)）" }
    var failureNotFound: String { "接口地址或模型名不对（HTTP 404）" }
    var failureBalance: String { "账户余额不足（HTTP 402）" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "请求被拒绝（HTTP \(status)）" : "请求被拒绝（HTTP \(status)）：\(message)"
    }
    var failureRateLimited: String { "请求太频繁或额度用完（HTTP 429）" }
    func failureServer(status: Int) -> String { "模型服务出错（HTTP \(status)）" }
    var failureNetwork: String { "连不上模型服务" }
    var failureMalformed: String { "模型没有按要求的格式回答" }
    var failureRefused: String { "模型拒绝了这批消息" }
    var failureTruncated: String { "模型的回答被截断" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "选择要翻译的频道。" }
    var targetHeader: String { "目标语言" }
    var targetLanguage: String { "翻译成" }
    var targetFollowUI: String { "跟随界面语言" }
    var showOriginal: String { "同时显示原文" }
    var foreignOnly: String { "只显示翻译过的消息" }

    // MARK: 模型服务
    var modelHeader: String { "模型" }
    var provider: String { "服务" }
    var providerCustom: String { "其他（OpenAI 兼容接口）" }
    var baseURL: String { "接口地址" }
    var model: String { "模型名" }
    var apiKey: String { "API Key" }
    var apiKeyStored: String { "已保存在钥匙串" }
    var apiKeyPlaceholder: String { "粘贴 Key 后点「保存」" }
    var saveKey: String { "保存" }
    var deleteKey: String { "删除 Key" }
    var keyNotRequired: String { "这个服务不用 Key" }
    var keyOptional: String { "接口要 Key 时填写，不要时留空。" }
    func keychainError(status: Int32) -> String { "钥匙串操作失败（\(status)）" }
    var test: String { "测试" }
    var testing: String { "测试中…" }
    func testSucceeded(_ text: String) -> String { "成功：\(text)" }
    func testFailed(_ reason: String) -> String { "失败：\(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "译文缓存" }
    func cacheCount(_ count: Int) -> String { "\(count) 条" }
    var clearCache: String { "清空缓存" }
    var privacyNote: String {
        "翻译时，频道里的消息正文会发给你选择的模型服务。Key 只保存在本机的钥匙串里，只发给这个服务。"
    }
    var costNote: String { "只翻译活动客户端的角色收到的消息。相同的句子只翻译一次。" }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "翻译 · \(character)" }
    var statusNoChannels: String { "还没有设置翻译频道" }
    func statusNoLogFiles(_ channels: [String]) -> String {
        "近 48 小时 EVE 没有写入这个角色在\(channels.map { "「\($0)」" }.joined(separator: "、"))的聊天日志"
    }
    func statusNoLogFilesBuiltIn(_ channels: [String]) -> String {
        "EVE 没有写\(channels.map { "「\($0)」" }.joined(separator: "、"))的日志：非英文客户端可能不写系统频道，可把 EVE 语言改为 English"
    }
    var pending: String { "翻译中…" }
    var failed: String { "未翻译" }
}
