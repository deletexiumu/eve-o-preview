// SPDX-License-Identifier: GPL-3.0-or-later
//
// 演示模式的模型传输（docs/design-intel-translate.md 9.5 节）：不发真实请求，不联网。
// 0.6 秒后返回答复，每条译文是原文前面加〔译〕，原文语言写成 und。答复是 OpenAI 兼容格式；
// 请求的地址以 /messages 结尾（Anthropic 预设）时改用 Anthropic 的格式，演示模式选哪个预设都能看到译文。
// 从请求体的用户消息里取「消息：」后面的 JSON 数组；取不到时返回空数组，这一批按格式不对处理。

import Foundation
import EVEOPreviewCore

/// 演示模式的模型传输。
final class FakeTranslationTransport: TranslationTransport {
    /// 模拟的往返耗时，单位是秒。
    static let delaySeconds = 0.6
    /// 译文的前缀。
    static let prefix = "〔译〕"

    /// 等 0.6 秒后给出答复；等待中被取消时返回 `network("cancelled")`。
    func send(_ request: TranslationHTTPRequest) async -> Result<TranslationHTTPResponse, TranslationTransportError> {
        try? await Task.sleep(for: .seconds(FakeTranslationTransport.delaySeconds))
        if Task.isCancelled { return .failure(.network("cancelled")) }
        let answer = FakeTranslationTransport.answer(for: FakeTranslationTransport.messages(in: request.body))
        let isAnthropic = request.url.path.hasSuffix("/messages")
        let body: [String: Any] = isAnthropic
            ? ["stop_reason": "end_turn", "content": [["type": "text", "text": answer]]]
            : ["choices": [["message": ["role": "assistant", "content": answer], "finish_reason": "stop"]]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return .success(TranslationHTTPResponse(status: 200, headers: ["content-type": "application/json"], body: data))
    }

    /// 请求体里用户消息中的各条（编号与正文）。
    static func messages(in body: Data) -> [(id: Int, text: String)] {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let turns = object["messages"] as? [[String: Any]],
              let user = turns.last(where: { $0["role"] as? String == "user" })?["content"] as? String,
              let marker = user.range(of: "消息：\n") else { return [] }
        let json = Data(user[marker.upperBound...].utf8)
        guard let array = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let id = item["id"] as? Int, let text = item["text"] as? String else { return nil }
            return (id, text)
        }
    }

    /// 模型的文字：每条一个对象，译文是原文加前缀。
    static func answer(for messages: [(id: Int, text: String)]) -> String {
        let items = messages.map { ["id": $0.id, "lang": "und", "text": prefix + $0.text] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
