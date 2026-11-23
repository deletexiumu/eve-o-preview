// SPDX-License-Identifier: GPL-3.0-or-later
//
// 模型服务的请求与答复（docs/design-intel-translate.md 7.4 节、7.5 节）。
// - request：拼出 HTTP 请求。请求体只带各模型都接受的字段，不带 temperature、top_p、思考与强度的设置（A1）。
//   OpenAI 兼容接口不带 max_tokens；Anthropic 接口的 max_tokens 取 16,000（默认模型先思考，思考也计入上限；
//   一批 20 条、6,000 个字符的译文加上思考，8,192 会被截断，审查 m8）。
// - answer：按状态码归类失败，从 2xx 答复里取出模型写的文字。
// - parse：从模型的文字里取出 JSON 数组，按编号对回消息。
// - failure(for:)：传输层的失败换成翻译的失败。
// 请求头里有 Key，任何一处都不应把 headers 写进日志。

import Foundation

/// 请求与答复的拼法与解析。
public enum TranslationWire {
    /// Anthropic Messages API 的版本头（A1）。
    public static let anthropicVersion = "2026-10-21"
    /// Anthropic 请求的 max_tokens。
    public static let anthropicMaxTokens = 16_000
    /// 请求的超时，单位是秒。
    public static let timeoutSeconds = 60.0
    /// 答复正文的上限，超过时按网络失败处理。
    public static let maxResponseBytes = 1_048_576
    /// 429 的 retry-after 秒数的夹取范围。没有 retry-after 或解析不了时不给秒数，由队列从 30 秒起加倍。
    public static let retryAfterRange: ClosedRange<Double> = 5...600
    /// rejected 的说明至多保留几个字符。
    public static let maxErrorMessageCharacters = 200

    // MARK: - 请求

    /// 拼出一次请求。apiKey 为 nil 或空串时不带 Key 的请求头。
    public static func request(endpoint: TranslationEndpoint, apiKey: String?,
                               content: TranslationPromptContent) -> TranslationHTTPRequest {
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        let base = endpoint.baseURL.absoluteString
        var headers = ["Content-Type": "application/json"]
        let url: URL
        let body: Data
        switch endpoint.kind {
        case .openAICompatible:
            url = URL(string: base + "/chat/completions") ?? endpoint.baseURL
            if let key { headers["Authorization"] = "Bearer " + key }
            body = encode(OpenAIRequest(model: endpoint.model,
                                        messages: [.init(role: "system", content: content.system),
                                                   .init(role: "user", content: content.user)],
                                        stream: false))
        case .anthropic:
            let path = endpoint.baseURL.path.hasSuffix("/v1") ? "/messages" : "/v1/messages"
            url = URL(string: base + path) ?? endpoint.baseURL
            if let key { headers["x-api-key"] = key }
            headers["anthropic-version"] = anthropicVersion
            body = encode(AnthropicRequest(model: endpoint.model, max_tokens: anthropicMaxTokens,
                                           system: content.system,
                                           messages: [.init(role: "user", content: content.user)]))
        }
        return TranslationHTTPRequest(url: url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    }

    /// OpenAI 兼容接口的请求体。
    private struct OpenAIRequest: Encodable {
        var model: String
        var messages: [ChatTurn]
        var stream: Bool
    }

    /// Anthropic 接口的请求体。字段名就是 JSON 的键。
    private struct AnthropicRequest: Encodable {
        var model: String
        var max_tokens: Int
        var system: String
        var messages: [ChatTurn]
    }

    /// 一条对话消息。
    private struct ChatTurn: Encodable {
        var role: String
        var content: String
    }

    /// 编码请求体；键排序，便于测试与比对。字段都是字符串与整数，编码不会失败。
    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    // MARK: - 答复

    /// 传输层的失败换成翻译的失败：答复过大按网络失败处理（7.4 节）。
    public static func failure(for error: TranslationTransportError) -> TranslationFailure {
        switch error {
        case .network(let reason): return .network(reason)
        case .tooLarge: return .network("response too large")
        }
    }

    /// 从答复里取出模型写的文字；状态码不是 2xx、被拒绝或被截断时抛出对应的失败（7.5 节的表）。
    public static func answer(from response: TranslationHTTPResponse,
                              kind: TranslationAPIKind) throws(TranslationFailure) -> String {
        if let failure = statusFailure(response) { throw failure }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw .malformedAnswer
        }
        switch kind {
        case .openAICompatible: return try openAIText(object)
        case .anthropic: return try anthropicText(object)
        }
    }

    /// 状态码的归类；2xx 返回 nil。
    static func statusFailure(_ response: TranslationHTTPResponse) -> TranslationFailure? {
        let status = response.status
        switch status {
        case 200...299: return nil
        case 401, 403: return .unauthorized(status: status)
        case 402: return .insufficientBalance
        case 404: return .notFound
        case 429: return .rateLimited(retryAfter: retryAfter(response.headers["retry-after"]))
        case 408, 409, 500...599: return .server(status: status)
        default: return .rejected(status: status, message: errorMessage(response.body))
        }
    }

    /// retry-after 头里的秒数，夹到 5～600；没有或不是数字（如 HTTP 日期）时为 nil。
    static func retryAfter(_ header: String?) -> Double? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), let seconds = Double(text),
              seconds.isFinite else { return nil }
        return min(max(seconds, retryAfterRange.lowerBound), retryAfterRange.upperBound)
    }

    /// 答复里的说明：`error.message`，没有时取顶层的 `message`，再没有时取字符串形式的 `error`，至多 200 个字符。
    static func errorMessage(_ body: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return "" }
        let message: String?
        if let error = object["error"] as? [String: Any], let text = error["message"] as? String {
            message = text
        } else if let text = object["message"] as? String {
            message = text
        } else {
            message = object["error"] as? String
        }
        return String((message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxErrorMessageCharacters))
    }

    /// OpenAI 兼容答复的文字：`choices[0].message.content`，字符串直接用，数组把各项的 text 连起来。
    /// `finish_reason` 是 length 时是被截断；choices 为空或文字为空时格式不对。
    private static func openAIText(_ object: [String: Any]) throws(TranslationFailure) -> String {
        guard let choices = object["choices"] as? [Any], let first = choices.first as? [String: Any] else {
            throw .malformedAnswer
        }
        if first["finish_reason"] as? String == "length" { throw .truncated }
        let message = first["message"] as? [String: Any]
        var text = ""
        if let content = message?["content"] as? String {
            text = content
        } else if let parts = message?["content"] as? [Any] {
            text = parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .malformedAnswer }
        return text
    }

    /// Anthropic 答复的文字：`stop_reason` 是 refusal 时被拒绝，是 max_tokens 时被截断；
    /// 其余情况把 content 里 type 是 text 的各块连起来，思考等别的块忽略。没有文字时格式不对。
    private static func anthropicText(_ object: [String: Any]) throws(TranslationFailure) -> String {
        switch object["stop_reason"] as? String {
        case "refusal": throw .refused
        case "max_tokens": throw .truncated
        default: break
        }
        let blocks = object["content"] as? [Any] ?? []
        let text = blocks.compactMap { block -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .malformedAnswer }
        return text
    }

    // MARK: - 解析译文

    /// 原文语言代码至多保留几个字符。
    static let maxLanguageCodeLength = 8

    /// 从模型的文字里取出译文（7.4 节）：取第一个 `[` 到最后一个 `]` 之间的内容按 JSON 数组解析，
    /// 解析失败或不是数组时是 malformedAnswer。每个对象取 id（整数，应在 ids 里）、text（去首尾空白，空的忽略）、
    /// lang（小写，至多 8 个字符，可缺）。
    public static func parse(_ answer: String, ids: [Int: UInt64]) throws(TranslationFailure) -> [UInt64: TranslatedText] {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end else {
            throw .malformedAnswer
        }
        let slice = Data(answer[start...end].utf8)
        guard let array = (try? JSONSerialization.jsonObject(with: slice)) as? [Any] else { throw .malformedAnswer }
        var results: [UInt64: TranslatedText] = [:]
        for element in array {
            guard let object = element as? [String: Any], let number = integer(object["id"]),
                  let messageID = ids[number], let rawText = object["text"] as? String else { continue }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var language = (object["lang"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let code = language {
                language = code.isEmpty ? nil : String(code.prefix(maxLanguageCodeLength))
            }
            results[messageID] = TranslatedText(text: text, sourceLanguage: language)
        }
        return results
    }

    /// JSON 里的整数：排除布尔值与带小数的数（JSONSerialization 把 true 也解成 NSNumber）。
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e9 else { return nil }
        return Int(double)
    }
}
