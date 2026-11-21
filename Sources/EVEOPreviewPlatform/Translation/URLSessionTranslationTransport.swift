// SPDX-License-Identifier: GPL-3.0-or-later
//
// 模型服务的 HTTP 传输（docs/design-intel-translate.md 7.4 节）：用 .ephemeral 的 URLSession 发 POST，
// 不用 cookie、不留缓存、不跟随重定向，答复正文至多 1 MiB，User-Agent 是 `EVE-O-Preview/<版本>`。
// WP-0 的空实现：不发请求，返回「未实现」的网络失败。实现归 WP-C。请求头里有 Key，不应写进任何日志。

import Foundation
import EVEOPreviewCore

/// 基于 URLSession 的传输。
public final class URLSessionTranslationTransport: TranslationTransport {
    /// 建传输。
    public init() {}

    /// 发一个请求。WP-0 的空实现返回 `network("not implemented")`。
    public func send(_ request: TranslationHTTPRequest) async -> Result<TranslationHTTPResponse, TranslationTransportError> {
        .failure(.network("not implemented"))
    }
}
