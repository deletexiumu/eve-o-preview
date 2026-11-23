// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的钥匙串、译文缓存与人名核对（docs/macos/design-intel-translate.md 9.5 节、6.10 节）：只在内存里，
// 不碰系统钥匙串，不读写 translation-cache.json 与 pilot-names.json，也不联网。
// EVEO_FAKE=1 时由 FakeServices 使用。状态用锁保护，可在任何线程调用。

import EVEOPreviewCore
import os

/// 内存里的 API Key 存储。
final class InMemorySecretStore: SecretStore {
    /// 账户名 → 值。
    private let secrets = OSAllocatedUnfairLock(initialState: [String: String]())

    /// 读一项；没有时是 `missing`，从不要求用户确认。
    func read(account: String, allowsInteraction: Bool) -> SecretReadResult {
        secrets.withLock { $0[account] }.map { .value($0) } ?? .missing
    }

    /// 写一项，已有时覆盖。
    func write(_ secret: String, account: String) throws(SecretStoreError) {
        secrets.withLock { $0[account] = secret }
    }

    /// 删一项，不存在时不算失败。
    func delete(account: String) throws(SecretStoreError) {
        _ = secrets.withLock { $0.removeValue(forKey: account) }
    }
}

/// 内存里的译文缓存存储。
final class InMemoryTranslationCacheStore: TranslationCacheStore {
    /// 最近一次存下的条目。
    private let entries = OSAllocatedUnfairLock(initialState: [TranslationCacheEntry]())

    /// 读最近一次存下的条目。
    func load() -> [TranslationCacheEntry] {
        entries.withLock { $0 }
    }

    /// 存下全部条目。
    func save(_ newEntries: [TranslationCacheEntry]) throws {
        entries.withLock { $0 = newEntries }
    }
}

/// 不联网的人名核对：0.4 秒后返回结果。正好两个词的名字是 `matched(characterID: 0, name: 原样)`，其余是 `notFound`。
/// 角色 ID 是 0 时浮窗不给链接（6.9 节），演示模式因此不会打开任何网页。
final class FakePilotNameResolver: PilotNameResolver {
    /// 模拟的往返耗时，单位是秒。
    static let delaySeconds = 0.4

    /// 等 0.4 秒后按词数给结果；等待中被取消时返回 `network("cancelled")`。
    func resolve(_ names: [String]) async -> Result<PilotLookupAnswer, PilotLookupFailure> {
        try? await Task.sleep(for: .seconds(FakePilotNameResolver.delaySeconds))
        if Task.isCancelled { return .failure(.network("cancelled")) }
        var outcomes: [String: PilotLookupOutcome] = [:]
        for name in names {
            let words = name.split(whereSeparator: { $0.isWhitespace })
            outcomes[PilotLookupAnswer.key(for: name)] = words.count == 2
                ? .matched(characterID: 0, name: words.joined(separator: " "))
                : .notFound
        }
        return .success(PilotLookupAnswer(outcomes: outcomes))
    }
}

/// 内存里的人名缓存存储。
final class InMemoryPilotNameCacheStore: PilotNameCacheStore {
    /// 最近一次存下的条目。
    private let entries = OSAllocatedUnfairLock(initialState: [PilotNameCacheEntry]())

    /// 读最近一次存下的条目。
    func load() -> [PilotNameCacheEntry] {
        entries.withLock { $0 }
    }

    /// 存下全部条目。
    func save(_ newEntries: [PilotNameCacheEntry]) throws {
        entries.withLock { $0 = newEntries }
    }
}
