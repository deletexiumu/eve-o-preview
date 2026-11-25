// SPDX-License-Identifier: GPL-3.0-or-later
//
// 取更新清单（docs/update-manifest.md 第 4 节；v1.1 设计 10.1 节的请求清单）。
//
// - 依次请求 `feed.manifestURLs`（正式地址下是 R2 的 CDN，然后是 GitHub），不带凭据。第一个成功的源就用它；
//   每个源的失败（网络错误、状态码不是 200、超过 1 MiB、验签或解析失败、序号比接受过的小）都只记一条日志，换下一个源。
//   都失败时返回最后一个源的错误。
// - 请求头：`Cache-Control: no-cache`（让 CDN 回源核对，不拿过期的缓存）；`User-Agent: EVE-O-Preview-macOS/<版本号>`
//   与 `Accept-Language: en` 写在会话配置的 `httpAdditionalHeaders` 里：不写时 `URLSession` 会自己填，前者带系统与
//   CFNetwork 的版本，后者是系统的语言列表。
// - 会话用 `.ephemeral`，不用 cookie、不留缓存；请求超时 15 秒。重定向只跟到 https（GitHub 的地址会重定向到文件存储），
//   测试地址下也允许与它同源的 http。
// - 公钥：正式地址用内置的公钥；测试地址用环境变量 `EVEO_UPDATE_TEST_PUBLIC_KEY`（`UpdateSigning.publicKey(for:environment:)`）。
// - 防回退：正式地址下调用方传入接受过的最大序号，更小的清单不收；返回的结果带上这次的序号，调用方记下。
//   测试地址不比较也不返回序号。

import CryptoKit
import Foundation
import EVEOPreviewCore

/// 更新清单的请求。
public enum ReleaseFeedClient {
    /// 每个源的请求超时秒数。
    static let requestTimeout: TimeInterval = 15
    /// 取清单的日志（检查本身的结果由 App 记）。与 BundleInstaller 一样每次取用，不存成静态属性。
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

    /// 依次请求各个源，返回第一个验签、解析都通过且序号不回退的清单；都失败时返回最后一个错误。
    /// environment 是进程的环境变量，只用来取测试公钥。
    public static func fetchManifest(feed: UpdateFeed, minimumSequence: UInt64?, appVersion: String,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) async
        -> Result<UpdateManifest, UpdateError> {
        guard let key = UpdateSigning.publicKey(for: feed, environment: environment) else {
            log.error("测试地址没有设 \(UpdateSigning.testPublicKeyVariable, privacy: .public)，无法验签")
            return .failure(.malformedFeed("no public key for test feed"))
        }
        let delegate = RedirectPolicy(feed: feed)
        let session = URLSession(configuration: sessionConfiguration(appVersion: appVersion,
                                                                     requestTimeout: requestTimeout),
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var lastError = UpdateError.network("no manifest source")
        for (index, url) in feed.manifestURLs.enumerated() {
            switch await fetchOne(url, session: session, key: key, feed: feed) {
            case .success(let manifest):
                // 序号只在正式地址下比较：测试地址的清单由脚本随时生成，序号与正式的无关。
                if !feed.isTestFeed, let minimum = minimumSequence, manifest.sequence < minimum {
                    log.notice("清单源 \(index, privacy: .public) 的序号 \(manifest.sequence, privacy: .public) 小于接受过的 \(minimum, privacy: .public)，换下一个源")
                    lastError = .malformedFeed("manifest sequence went backwards")
                    continue
                }
                return .success(manifest)
            case .failure(let error):
                log.notice("清单源 \(index, privacy: .public) 失败：\(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
        return .failure(lastError)
    }

    /// 取清单并转成检查结果：有本平台的版本时 `.release`，没有时 `.noRelease`；序号只在正式地址下给出。
    public static func fetch(feed: UpdateFeed, minimumSequence: UInt64?, appVersion: String) async
        -> (result: ReleaseFetchResult, manifest: UpdateManifest?) {
        switch await fetchManifest(feed: feed, minimumSequence: minimumSequence, appVersion: appVersion) {
        case .success(let manifest):
            let sequence = feed.isTestFeed ? nil : manifest.sequence
            if let latest = manifest.latest { return (.release(latest, sequence: sequence), manifest) }
            return (.noRelease(sequence: sequence), manifest)
        case .failure(let error):
            return (.failed(error), nil)
        }
    }

    /// 请求一个源：状态码要是 200，正文不超过 1 MiB，再验签、解析。
    static func fetchOne(_ url: URL, session: URLSession, key: Curve25519.Signing.PublicKey,
                         feed: UpdateFeed) async -> Result<UpdateManifest, UpdateError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let body: Data
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let http = rawResponse as? HTTPURLResponse else { return .failure(.network("not an HTTP response")) }
            guard http.statusCode == 200 else { return .failure(.httpStatus(http.statusCode)) }
            body = try await readLimited(bytes, limit: UpdateManifest.maxBytes)
        } catch {
            return .failure(.network(describe(error)))
        }
        do {
            return .success(try UpdateManifest.open(body, publicKey: key, feed: feed))
        } catch {
            return .failure(error)
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

    /// 答复头，键转成小写。情报名字解析与翻译传输也用它。
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

/// 取清单时的重定向规则：只跟到 https；测试地址下也允许与它同源的 http。不跟随时 3xx 成为最终答复，按状态码报错。
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    /// 检查地址。
    let feed: UpdateFeed

    init(feed: UpdateFeed) {
        self.feed = feed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let target = request.url, let scheme = target.scheme?.lowercased() else { return nil }
        let allowed = scheme == "https" || (feed.isTestFeed && feed.accepts(target.absoluteString))
        return allowed ? request : nil
    }
}
