// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的模型传输（docs/design-intel-translate.md 9.5 节）：不发真实请求。
// 完整的版本（0.6 秒后返回 OpenAI 兼容格式的答复，每条译文是原文前面加〔译〕）归 WP-C。
// WP-0 的骨架：返回「未实现」的网络失败。

import EVEOPreviewCore

/// 演示模式的模型传输。
final class FakeTranslationTransport: TranslationTransport {
    /// 骨架：返回 `network("not implemented")`。
    func send(_ request: TranslationHTTPRequest) async -> Result<TranslationHTTPResponse, TranslationTransportError> {
        .failure(.network("not implemented"))
    }
}
