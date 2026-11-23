// SPDX-License-Identifier: GPL-3.0-or-later
//
// 模型服务的 HTTP 传输（docs/macos/design-intel-translate.md 7.4 节）：
// - 每次请求建一个 .ephemeral 的 URLSession：不用 cookie、不留缓存、不存凭据，用完即作废。
// - `User-Agent: EVE-O-Preview/<版本>`，版本取本进程 Info.plist 的版本号，没有时是 0.0.0。
// - 不跟随重定向：收到 3xx 时原样交回，Core 把它归为 rejected，Key 不会被带到别的主机。
// - 超时取请求给的秒数（60 秒），同时作为空闲超时与整次请求的上限。
// - 答复正文至多 1 MiB，读到上限加 1 字节就停，返回 tooLarge。
// 请求头里有 Key，地址与模型名也属于用户的设置：本文件不记日志，失败说明只含 URLError 的代码。

import Foundation
import EVEOPreviewCore

/// 基于 URLSession 的传输。
public final class URLSessionTranslationTransport: TranslationTransport {
    /// 应用版本，写进 User-Agent。
    private let appVersion: String

    /// 建传输；appVersion 默认取本进程 Info.plist 的版本号。
    public init(appVersion: String? = nil) {
        self.appVersion = appVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// 发一个请求。连不上、超时、被取消与答复过大是失败；任何状态码（含 3xx）都原样作为答复交回。
    public func send(_ request: TranslationHTTPRequest) async -> Result<TranslationHTTPResponse, TranslationTransportError> {
        let session = URLSession(configuration: configuration(timeout: request.timeoutSeconds))
        defer { session.finishTasksAndInvalidate() }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutSeconds
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (bytes, rawResponse) = try await session.bytes(for: urlRequest, delegate: NoRedirectDelegate())
            guard let http = rawResponse as? HTTPURLResponse else { return .failure(.network("not an HTTP response")) }
            let body = try await ReleaseFeedClient.readLimited(bytes, limit: TranslationWire.maxResponseBytes)
            if body.count > TranslationWire.maxResponseBytes { return .failure(.tooLarge) }
            return .success(TranslationHTTPResponse(status: http.statusCode,
                                                    headers: ReleaseFeedClient.lowercasedHeaders(http), body: body))
        } catch is CancellationError {
            return .failure(.network("cancelled"))
        } catch {
            return .failure(.network(ReleaseFeedClient.describe(error)))
        }
    }

    /// 会话配置：不带 cookie、缓存与凭据存储，只加 User-Agent；空闲与整次请求的超时都是 timeout 秒。
    private func configuration(timeout: Double) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "EVE-O-Preview/\(appVersion)"]
        return configuration
    }
}

/// 拒绝跟随重定向的任务委托：把 3xx 答复原样交回调用方。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
