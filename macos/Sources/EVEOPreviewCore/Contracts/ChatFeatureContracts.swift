// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译用到的平台协议（docs/design-intel-translate.md 4.3 节、7.2 节）。协议只含 Core 的值类型，
// 由 EVEOPreviewPlatform 实现；演示模式与测试用 App 里的假实现。聊天日志的 ChatLogMonitor 在 PlatformContracts.swift。
// - StaticDataProvider：读并解码星图数据文件（eve-static.json）。
// - TranslationTransport：发一个 HTTP 请求；请求的内容与答复的解析都在 Core 的 TranslationWire。
// - SecretStore：读写钥匙串里的 API Key。
// - TranslationCacheStore：读写译文缓存文件。
// - PilotNameResolver、PilotNameCacheStore：向 ESI 核对人名，读写人名缓存文件（6.9 节、6.10 节）。

import Foundation

/// 读星图数据的结果。
public enum StaticDataLoadResult: Sendable {
    /// 读到并解码成功。source 是文件的来源：`environment`、`userOverride`、`bundle`、`repository`。
    case loaded(EVEStaticData, source: String)
    /// 没有任何数据文件。
    case missing
    /// 有文件，但读不了或解不开。
    case invalid(StaticDataError)
}

/// 星图数据的提供者（4.4 节）。
public protocol StaticDataProvider: Sendable {
    /// 在后台线程读文件并解码。数据在本次运行内不变，调用方只调一次。
    func load() async -> StaticDataLoadResult
}

/// 模型服务的 HTTP 传输（7.4 节）。只负责收发，不跟随重定向，答复正文至多 1 MiB。
public protocol TranslationTransport: Sendable {
    /// 发一个请求。连不上、超时与答复过大是失败；任何状态码（含 3xx、4xx、5xx）都原样作为答复交回。
    func send(_ request: TranslationHTTPRequest) async -> Result<TranslationHTTPResponse, TranslationTransportError>
}

/// 读钥匙串的结果（7.7 节）。
public enum SecretReadResult: Sendable, Equatable {
    /// 读到的值。
    case value(String)
    /// 钥匙串里没有这一项。
    case missing
    /// 要弹出系统的确认窗口，本次没有弹（allowsInteraction 为假时）。
    case interactionRequired
    /// 其他失败，关联值是 `OSStatus`。
    case failed(status: Int32)
}

/// 写或删钥匙串失败。
public enum SecretStoreError: Error, Sendable, Equatable {
    /// 失败，关联值是 `OSStatus`。
    case failed(status: Int32)
}

/// API Key 的存储（7.7 节）。方法是同步调用，只在用户操作或开关变化时调用。Key 不写进任何日志。
public protocol SecretStore: Sendable {
    /// 读一项。allowsInteraction 为假时不弹系统窗口，要确认时返回 `interactionRequired`。
    func read(account: String, allowsInteraction: Bool) -> SecretReadResult
    /// 写一项，已有时覆盖。
    func write(_ secret: String, account: String) throws(SecretStoreError)
    /// 删一项，不存在时不算失败。
    func delete(account: String) throws(SecretStoreError)
}

/// 译文缓存的存储（7.8 节）。读写在后台任务里调用。
public protocol TranslationCacheStore: Sendable {
    /// 读全部条目。文件读不了或格式不对时返回空数组。
    func load() -> [TranslationCacheEntry]
    /// 原子写入全部条目，最近用过的在后。
    func save(_ entries: [TranslationCacheEntry]) throws
}

/// 向 ESI 核对人名（6.10 节）。实现在 URLSession 的线程上收发，调用方在主 actor 上等结果。
/// 发出的名字是消息正文的一部分，实现不应把它们写进任何日志。
public protocol PilotNameResolver: Sendable {
    /// 发一次请求。names 已去重，1～500 个。不重试。
    func resolve(_ names: [String]) async -> Result<PilotLookupAnswer, PilotLookupFailure>
}

/// 人名缓存的存储（6.10 节），只存查到的角色。读写在后台任务里调用。
public protocol PilotNameCacheStore: Sendable {
    /// 读全部条目。文件读不了或格式不对时返回空数组。
    func load() -> [PilotNameCacheEntry]
    /// 原子写入全部条目。
    func save(_ entries: [PilotNameCacheEntry]) throws
}
