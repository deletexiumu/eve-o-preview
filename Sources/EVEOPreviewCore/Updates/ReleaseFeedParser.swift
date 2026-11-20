// SPDX-License-Identifier: GPL-3.0-or-later
//
// GitHub「最新 Release」答复的解析与限流判断（v1.1 设计 8.4 节）。
//
// 解析规则：
// - 顶层是 JSON 对象，超过 1 MiB 时按 `malformedFeed` 处理。
// - `tag_name` 应能解析成 `SemanticVersion`，`ReleaseInfo.version` 取它的规范写法（不带 `v`）。
// - `html_url` 应通过 `feed.accepts`；附件地址不通过时只丢掉这个附件。附件多于 100 个时只看前 100 个。
// - `body` 超过 65,536 个字符时截短，缺失或为 null 时取空串。
//
// 限流：403 或 429，且 `x-ratelimit-remaining` 是 0 或有 `retry-after` 时是限流。
// 可以再试的时刻先看 `retry-after`（GitHub 文档：有它时按它等待），再看 `x-ratelimit-reset`，都没有时取现在加 1 小时。
// 两个头的值都应是有限的非负数，否则当作没有（`Double` 能解析 `inf`、`nan`）。得到的时刻不早于现在、不晚于现在加 24 小时：
// 过大的值会让检查停很久，也可能写出 state.json 读不回来的日期。

import Foundation

/// 发布信息的解析。
public enum ReleaseFeedParser {
    /// 答复正文的上限：1 MiB。
    public static let maxFeedBytes = 1_048_576
    /// 发布说明保留的最多字符数。
    public static let maxNotesCharacters = 65_536
    /// 最多看前多少个附件。
    public static let maxAssets = 100
    /// 限流答复里两个时刻头都没有时，推后的秒数。
    public static let defaultRateLimitDelay: TimeInterval = 3_600
    /// 可以再试的时刻最多推后多少秒：24 小时。
    public static let maxRateLimitDelay: TimeInterval = 86_400

    /// 解析 200 答复的正文。内容不符合规则时抛 `malformedFeed`，关联值是原因（英文，不含正文内容）。
    public static func parse(_ data: Data, feed: UpdateFeed) throws(UpdateError) -> ReleaseInfo {
        guard data.count <= maxFeedBytes else { throw .malformedFeed("response larger than 1 MiB") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .malformedFeed("not JSON")
        }
        guard let root = object as? [String: Any] else { throw .malformedFeed("top level is not an object") }
        guard let tag = root["tag_name"] as? String else { throw .malformedFeed("missing tag_name") }
        guard let version = SemanticVersion(tag) else { throw .malformedFeed("tag_name is not a version") }
        guard let page = root["html_url"] as? String, feed.accepts(page) else {
            throw .malformedFeed("html_url not accepted")
        }
        let notes = (root["body"] as? String).map { String($0.prefix(maxNotesCharacters)) } ?? ""
        let title = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag
        let assets = (root["assets"] as? [Any] ?? []).prefix(maxAssets).compactMap { asset(from: $0, feed: feed) }
        return ReleaseInfo(version: version.description, tagName: tag, title: title, notes: notes, pageURL: page,
                           publishedAt: (root["published_at"] as? String).flatMap(date(from:)),
                           isPrerelease: root["prerelease"] as? Bool ?? false,
                           isDraft: root["draft"] as? Bool ?? false,
                           assets: Array(assets))
    }

    /// 判断一次答复是不是限流，并给出可以再试的时刻。headers 的键已转成小写。不是限流时返回 nil。
    public static func rateLimit(status: Int, headers: [String: String], now: Date) -> ReleaseFetchResult? {
        guard status == 403 || status == 429 else { return nil }
        let remaining = headers["x-ratelimit-remaining"]?.trimmingCharacters(in: .whitespaces)
        let retryAfter = headers["retry-after"]
        guard remaining == "0" || retryAfter != nil else { return nil }
        let latest = now.addingTimeInterval(maxRateLimitDelay)
        if let seconds = nonNegativeNumber(retryAfter) {
            return .rateLimited(until: min(now.addingTimeInterval(min(seconds, maxRateLimitDelay)), latest))
        }
        if let reset = nonNegativeNumber(headers["x-ratelimit-reset"]) {
            // 先在秒数上截到上限，再建 Date：极大的值不经过 Date 的运算。
            let bounded = min(reset, latest.timeIntervalSince1970)
            return .rateLimited(until: max(Date(timeIntervalSince1970: bounded), now))
        }
        return .rateLimited(until: now.addingTimeInterval(defaultRateLimitDelay))
    }

    /// 头的值是有限的非负数时返回它；缺失、解析不了、`inf`、`nan` 或负数时返回 nil。
    static func nonNegativeNumber(_ text: String?) -> Double? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// 一个附件；缺字段或地址不通过 `feed.accepts` 时返回 nil。
    private static func asset(from value: Any, feed: UpdateFeed) -> ReleaseAsset? {
        guard let object = value as? [String: Any], let name = object["name"] as? String,
              let url = object["browser_download_url"] as? String, feed.accepts(url) else { return nil }
        return ReleaseAsset(name: name, downloadURL: url, size: (object["size"] as? NSNumber)?.intValue)
    }

    /// 解析 `published_at`（ISO 8601，可能带小数秒）；解析不了时返回 nil。
    private static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
