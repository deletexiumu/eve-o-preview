// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名缓存文件（docs/design-intel-translate.md 6.10 节）：`~/Library/Application Support/EVE-O Preview/pilot-names.json`，
// 内容是 `{"format": 1, "entries": [...]}`，每项有 key、characterID、name、time，只存查到的角色。
// 权限 0600，原子写入；读不了或格式不对时从空缓存开始。文件里有其他玩家的角色名，不进问题报告。
// WP-0 的空实现：读返回空数组，写不做事。实现归 WP-B。

import Foundation
import EVEOPreviewCore

/// 存在文件里的人名缓存。
public final class FilePilotNameCacheStore: PilotNameCacheStore {
    /// 建存储。
    public init() {}

    /// 读全部条目。WP-0 的空实现返回空数组。
    public func load() -> [PilotNameCacheEntry] {
        []
    }

    /// 写全部条目。WP-0 的空实现不做事。
    public func save(_ entries: [PilotNameCacheEntry]) throws {}
}
