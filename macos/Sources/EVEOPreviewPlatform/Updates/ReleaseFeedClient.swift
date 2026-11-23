// SPDX-License-Identifier: GPL-3.0-or-later
//
// 请求最新的正式版（v1.1 设计 8.4 节，10.1 节的请求清单）。
//
// - `GET <feed>`，不带凭据。请求头：`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2022-11-28`；
//   有 ETag 时加 `If-None-Match`（调用方只在有缓存的发布信息时传 ETag）。
// - `User-Agent: EVE-O-Preview-macOS/<版本号>` 与 `Accept-Language: en` 写在会话配置的 `httpAdditionalHeaders` 里：
//   不写时 `URLSession` 会自己填，前者带系统与 CFNetwork 的版本，后者是系统的语言列表。
// - 会话用 `.ephemeral`，不用 cookie、不留缓存；请求超时 15 秒；答复正文超过 1 MiB 按 `malformedFeed` 处理。
// - 答复的处理见 8.4 节的表：200 解析，304 `.notModified`，404 `.noRelease`，限流 `.rateLimited`，
//   其他状态码 `.failed(.httpStatus)`，网络错误 `.failed(.network)`。
//
// 列表回退（1.3.0 起）：200 答复的 `tag_name` 解析不了（最新 Release 是 Windows 版 `win-v*`）时，改取 Release 列表
// （`feed.historyURL`），用 `ReleaseFeedParser.parseLatestFromList` 找 macOS 的最新正式版。这时不返回 ETag：
// 下次检查若拿 ETag 得到 304，就会一直停在这次挑出的版本，看不到之后发布的 macOS 新版本。
//
// 另有 `fetchHistory`：有新版本要提示时取 Release 列表（8.8 节），只用来显示中间版本的说明。请求头与会话配置
// 同上，不带 ETag；任何失败都只返回 nil。

import Foundation
import EVEOPreviewCore

/// 发布信息的请求。
public enum ReleaseFeedClient {
    /// 检查请求的超时秒数。
    static let requestTimeout: TimeInterval = 15
    /// 取 Release 列表的日志（检查本身的结果由 App 记）。与 BundleInstaller 一样每次取用，不存成静态属性。
    private static var log: LogChannel { PlatformLog.logger("Updates") }

    /// 检查与下载共用的会话配置：不带 cookie 与缓存，只加 `User-Agent` 与 `Accept-Language: en` 两个头。
    static func sessionConfiguration(appVersion: String, requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": "EVE-O-Preview-macOS/\(appVersion)",
                                               "Accept-Language": "en"]
        return configuration
    }

    /// 请求最新的正式版。etag 是上次答复的 ETag，没有缓存的发布信息时应传 nil。
    public static func fetch(feed: UpdateFeed, etag: String?, appVersion: String, now: Date = Date()) async
        -> ReleaseFetchResult {
        let session = URLSession(configuration: sessionConfiguration(appVersion: appVersion,
                                                                     requestTimeout: requestTimeout))
        defer { session.finishTasksAndInvalidate() }
        var request = apiRequest(url: feed.feedURL)
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let body: Data
        let response: HTTPURLResponse
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let http = rawResponse as? HTTPURLResponse else { return .failed(.network("not an HTTP response")) }
            response = http
            // 只有 200 要读正文；读到上限加 1 字节就停，超大的答复不进内存。
            body = http.statusCode == 200 ? try await readLimited(bytes, limit: ReleaseFeedParser.maxFeedBytes) : Data()
        } catch {
            return .failed(.network(describe(error)))
        }
        let outcome = result(status: response.statusCode, headers: lowercasedHeaders(response), body: body, feed: feed,
                             now: now)
        // 最新 Release 不是 macOS 版时改取列表；列表也失败时保留原来的解析错误，便于在日志里看出原因。
        if case .failed(let error) = outcome, ReleaseFeedParser.needsListFallback(error),
           let fallback = await fetchLatestFromList(feed: feed, session: session) {
            return fallback
        }
        return outcome
    }

    /// 列表回退：取 Release 列表，挑出 macOS 的最新正式版，不带 ETag。任何失败都返回 nil 并记一条日志。
    static func fetchLatestFromList(feed: UpdateFeed, session: URLSession) async -> ReleaseFetchResult? {
        guard let url = feed.historyURL else { return nil }
        do {
            let (bytes, rawResponse) = try await session.bytes(for: apiRequest(url: url))
            guard let http = rawResponse as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (rawResponse as? HTTPURLResponse)?.statusCode ?? 0
                log.notice("最新 Release 不是 macOS 版，取列表：状态码 \(status, privacy: .public)")
                return nil
            }
            let body = try await readLimited(bytes, limit: ReleaseHistory.maxListBytes)
            let info = try ReleaseFeedParser.parseLatestFromList(body, feed: feed)
            log.notice("最新 Release 不是 macOS 版，改用列表里的 \(info.tagName, privacy: .public)")
            return .release(info, etag: nil)
        } catch {
            log.notice("最新 Release 不是 macOS 版，取列表失败：\(describeHistoryError(error), privacy: .public)")
            return nil
        }
    }

    /// 请求 Release 列表（8.8 节），返回各正式版的说明。尽力而为：任何失败都返回 nil 并记一条日志，
    /// 不写限流时刻（列表与检查共用 GitHub 的限额，被限流时下一次检查自己会遇到并记下）。不带 ETag。
    public static func fetchHistory(feed: UpdateFeed, appVersion: String) async -> ReleaseHistoryPage? {
        guard let url = feed.historyURL else { return nil }
        let session = URLSession(configuration: sessionConfiguration(appVersion: appVersion,
                                                                     requestTimeout: requestTimeout))
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, rawResponse) = try await session.bytes(for: apiRequest(url: url))
            guard let http = rawResponse as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (rawResponse as? HTTPURLResponse)?.statusCode ?? 0
                log.notice("取 Release 列表：状态码 \(status, privacy: .public)")
                return nil
            }
            let body = try await readLimited(bytes, limit: ReleaseHistory.maxListBytes)
            return try ReleaseHistory.parse(body)
        } catch {
            log.notice("取 Release 列表失败：\(describeHistoryError(error), privacy: .public)")
            return nil
        }
    }

    /// GitHub API 的 GET 请求：`Accept` 与 `X-GitHub-Api-Version` 两个头。检查与取列表共用。
    static func apiRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// 取列表失败的简短说明：解析错误给出原因，其余同 `describe(_:)`。
    private static func describeHistoryError(_ error: any Error) -> String {
        if let updateError = error as? UpdateError { return String(describing: updateError) }
        return describe(error)
    }

    /// 按 8.4 节的表把状态码与正文换成结果。
    static func result(status: Int, headers: [String: String], body: Data, feed: UpdateFeed, now: Date)
        -> ReleaseFetchResult {
        if let limited = ReleaseFeedParser.rateLimit(status: status, headers: headers, now: now) { return limited }
        switch status {
        case 200:
            do {
                let info = try ReleaseFeedParser.parse(body, feed: feed)
                return .release(info, etag: headers["etag"])
            } catch {
                return .failed(error)
            }
        case 304: return .notModified
        case 404: return .noRelease
        default: return .failed(.httpStatus(status))
        }
    }

    /// 读正文，最多 limit + 1 字节（多读的 1 字节让解析器判断超限）。
    static func readLimited(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 65_536))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { break }
        }
        return data
    }

    /// 答复头，键转成小写。
    static func lowercasedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = value as? String ?? String(describing: value)
        }
        return headers
    }

    /// 网络错误的简短说明：URLError 取代码，其他取类型名，不带地址（地址可能是测试地址里的路径）。
    static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }
}
