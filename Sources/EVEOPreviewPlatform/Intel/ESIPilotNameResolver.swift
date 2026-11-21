// SPDX-License-Identifier: GPL-3.0-or-later
//
// 向 CCP 的 ESI 核对人名（docs/design-intel-translate.md 6.10 节）：`POST https://esi.evetech.net/universe/ids`，
// 用 .ephemeral 的 URLSession，不用 cookie、不留缓存、不跟随重定向。请求的写法与答复的解析都在 Core 的 ESINameWire。
// 一次 resolve 发一个请求，不重试；应用版本取本进程 Info.plist 的版本号，没有时是 0.0.0。
// 发出的名字是消息正文的一部分，不写进任何日志，日志只写个数、状态码、耗时与错误额度。
// WP-0 的空实现：不发请求，返回「未实现」的网络失败。实现归 WP-B。

import Foundation
import EVEOPreviewCore

/// 经 ESI 核对人名。
public final class ESIPilotNameResolver: PilotNameResolver {
    /// 建核对服务。
    public init() {}

    /// 发一次请求。WP-0 的空实现返回 `network("not implemented")`。
    public func resolve(_ names: [String]) async -> Result<PilotLookupAnswer, PilotLookupFailure> {
        .failure(.network("not implemented"))
    }
}
