// SPDX-License-Identifier: GPL-3.0-or-later
//
// 译文缓存文件（docs/design-intel-translate.md 7.8 节）：`~/Library/Application Support/EVE-O Preview/translation-cache.json`，
// 内容是 `{"format": 1, "entries": [...]}`，权限 0600，原子写入；读不了或格式不对时从空缓存开始。
// 文件里有聊天原文与译文，不进问题报告。
// WP-0 的空实现：读返回空数组，写抛「未实现」。实现归 WP-C。

import Foundation
import EVEOPreviewCore

/// 存在文件里的译文缓存。
public final class FileTranslationCacheStore: TranslationCacheStore {
    /// 「未实现」的失败。
    public struct NotImplemented: Error, Sendable {}

    /// 建存储。
    public init() {}

    /// 读全部条目。WP-0 的空实现返回空数组。
    public func load() -> [TranslationCacheEntry] {
        []
    }

    /// 写全部条目。WP-0 的空实现抛「未实现」。
    public func save(_ entries: [TranslationCacheEntry]) throws {
        throw NotImplemented()
    }
}
