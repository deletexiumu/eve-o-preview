// SPDX-License-Identifier: GPL-3.0-or-later
//
// 向 CCP 的 ESI 核对人名（docs/macos/design-intel-translate.md 6.10 节）：`POST https://esi.evetech.net/universe/ids`，
// 用 .ephemeral 的 URLSession，不用 cookie、不留缓存、不跟随重定向。请求的写法与答复的解析都在 Core 的 ESINameWire。
// 一次 resolve 发一个请求，不重试；应用版本取本进程 Info.plist 的版本号，没有时是 0.0.0。
// 发出的名字是消息正文的一部分，不写进任何日志（.private 也不用），日志只写个数、状态码、耗时与错误额度。
// 线程：resolve 是 async 方法，在 URLSession 的线程上收发；调用方（IntelFeedController）在主 actor 上等结果。

import Foundation
import EVEOPreviewCore

/// 经 ESI 核对人名。
public final class ESIPilotNameResolver: PilotNameResolver {
    /// 应用版本，写进 User-Agent。
    private let appVersion: String
    private static var log: LogChannel { PlatformLog.logger("Intel") }

    /// 建核对服务。appVersion 为 nil 时取本进程 Info.plist 的版本号，没有时是 0.0.0。
    public init(appVersion: String? = nil) {
        self.appVersion = appVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0.0"
    }

    /// 发一次请求。names 应已去重，1～500 个（ESINameWire.batches 的一组）。不重试。
    public func resolve(_ names: [String]) async -> Result<PilotLookupAnswer, PilotLookupFailure> {
        guard !names.isEmpty else { return .failure(.rejected(status: 400)) }
        let wire = ESINameWire.request(names: names, appVersion: appVersion)
        var request = URLRequest(url: wire.url, timeoutInterval: wire.timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = wire.body
        request.httpShouldHandleCookies = false
        for (name, value) in wire.headers { request.setValue(value, forHTTPHeaderField: name) }

        let session = URLSession(configuration: ESIPilotNameResolver.configuration(timeout: wire.timeoutSeconds))
        defer { session.finishTasksAndInvalidate() }
        let started = ContinuousClock.now
        let status: Int
        let headers: [String: String]
        let body: Data
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
            guard let http = response as? HTTPURLResponse else { return .failure(.network("not an HTTP response")) }
            status = http.statusCode
            headers = ReleaseFeedClient.lowercasedHeaders(http)
            // 只有 200 要读正文；读到上限加 1 字节就停，超大的答复不进内存。
            body = status == 200 ? try await ReleaseFeedClient.readLimited(bytes, limit: ESINameWire.maxResponseBytes)
                : Data()
        } catch {
            let reason = ReleaseFeedClient.describe(error)
            ESIPilotNameResolver.log.notice("人名核对请求失败：\(names.count) 个名字，\(reason, privacy: .public)")
            return .failure(.network(reason))
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let remain = headers["x-esi-error-limit-remain"] ?? "-"
        ESIPilotNameResolver.log.info(
            "人名核对：\(names.count) 个名字，状态码 \(status)，耗时 \(milliseconds) 毫秒，错误额度 \(remain, privacy: .public)")
        return ESINameWire.answer(status: status, headers: headers, body: body, names: names)
    }

    /// 会话配置：不用 cookie、不留缓存、不存凭据。
    static func configuration(timeout: Double) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        return configuration
    }
}

/// 拒绝重定向：3xx 的答复原样交回，由 ESINameWire 归为 rejected。
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
