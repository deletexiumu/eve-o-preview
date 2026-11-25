// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布信息解析共用的上限（v1.1 设计 8.4 节）。
//
// 1.4.x 及更早的版本在这里解析 GitHub「最新 Release」接口的答复、判断限流；1.5.0 起检查改读签名的更新清单
// （UpdateManifest.swift，docs/update-manifest.md），GitHub 接口的解析与限流判断随之去掉，只留清单也要用的上限。

import Foundation

/// 发布信息解析共用的上限。
public enum ReleaseFeedParser {
    /// 发布说明保留的最多字符数：清单的 `releases[].notes` 超过时截短。
    public static let maxNotesCharacters = 65_536
}
