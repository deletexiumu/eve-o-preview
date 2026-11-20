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

import Foundation
import EVEOPreviewCore

/// 发布信息的请求。
public enum ReleaseFeedClient {
    /// 检查请求的超时秒数。
    static let requestTimeout: TimeInterval = 15

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
        var request = URLRequest(url: feed.feedURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
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
        return result(status: response.statusCode, headers: lowercasedHeaders(response), body: body, feed: feed,
                      now: now)
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
