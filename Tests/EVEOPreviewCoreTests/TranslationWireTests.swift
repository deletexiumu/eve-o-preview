// SPDX-License-Identifier: GPL-3.0-or-later
//
// 请求与答复（docs/design-intel-translate.md 7.4 节、7.5 节，14.1 节 TranslationWireTests）：
// 两种接口的地址（含 baseURL 以 /v1 结尾）、请求头与请求体的键；请求体里没有 temperature；Key 为空时没有
// Authorization；两种接口的正常答复；content 是数组的 OpenAI 答复；含思考块的 Anthropic 答复只取文字；
// refusal、max_tokens、finish_reason: length；7.5 节表里每个状态码的归类与 retry-after 的夹取；
// parse 对前后带说明文字的答复、编号不认识的项、不是 JSON 的答复。用的 Key 是编造的。

import Testing
import Foundation
import EVEOPreviewCore

/// 请求与答复。
struct TranslationWireTests {
    /// 编造的 Key。
    let key = "sk-test-0000"
    /// 一份固定的提示词。
    let content = TranslationPromptContent(system: "SYS", user: "USER", ids: [1: 9])

    /// 某个预设的接口；baseURL 可覆盖。
    func endpoint(_ provider: TranslationProviderID, base: String? = nil) throws -> TranslationEndpoint {
        try TranslationProviders.resolve(TranslationEndpointSettings(provider: provider, baseURL: base ?? "",
                                                                     model: "m-1")).get()
    }

    /// 请求体解成字典。
    func body(_ request: TranslationHTTPRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    /// 答复。
    func response(_ status: Int, _ json: String, headers: [String: String] = [:]) -> TranslationHTTPResponse {
        TranslationHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    /// 取 answer 抛出的失败；没有抛出时为 nil。
    func failure(_ response: TranslationHTTPResponse, _ kind: TranslationAPIKind = .openAICompatible) -> TranslationFailure? {
        do {
            _ = try TranslationWire.answer(from: response, kind: kind)
            return nil
        } catch {
            return error
        }
    }

    // MARK: 请求

    /// OpenAI 兼容：地址、请求头、请求体的键；没有 temperature 与 max_tokens。
    @Test func openAIRequest() throws {
        let request = TranslationWire.request(endpoint: try endpoint(.openai), apiKey: key, content: content)
        #expect(request.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.headers == ["Content-Type": "application/json", "Authorization": "Bearer sk-test-0000"])
        #expect(request.timeoutSeconds == 60)
        let json = try body(request)
        #expect(Set(json.keys) == ["model", "messages", "stream"])
        #expect(json["model"] as? String == "m-1")
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "SYS"], ["role": "user", "content": "USER"]])
        #expect(json["temperature"] == nil)
    }

    /// Key 为空或 nil 时没有 Authorization。
    @Test func openAIRequestWithoutKey() throws {
        let ollama = try endpoint(.ollama)
        #expect(TranslationWire.request(endpoint: ollama, apiKey: nil, content: content).headers["Authorization"] == nil)
        #expect(TranslationWire.request(endpoint: ollama, apiKey: "", content: content).headers["Authorization"] == nil)
        #expect(TranslationWire.request(endpoint: ollama, apiKey: nil, content: content).url.absoluteString
            == "http://127.0.0.1:11434/v1/chat/completions")
    }

    /// Anthropic：地址补 /v1/messages，baseURL 以 /v1 结尾时只补 /messages；三个请求头；请求体的键。
    @Test func anthropicRequest() throws {
        let request = TranslationWire.request(endpoint: try endpoint(.anthropic), apiKey: key, content: content)
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.headers == ["Content-Type": "application/json", "x-api-key": "sk-test-0000",
                                    "anthropic-version": "2026-10-21"])
        let json = try body(request)
        #expect(Set(json.keys) == ["model", "max_tokens", "system", "messages"])
        #expect(json["max_tokens"] as? Int == 16_000)
        #expect(json["system"] as? String == "SYS")
        #expect(json["temperature"] == nil && json["thinking"] == nil)
        let proxied = TranslationWire.request(endpoint: try endpoint(.anthropic, base: "https://gw.example.com/v1"),
                                              apiKey: key, content: content)
        #expect(proxied.url.absoluteString == "https://gw.example.com/v1/messages")
    }

    // MARK: 正常答复

    /// OpenAI 兼容：content 是字符串，或是分段的数组。
    @Test func openAIAnswers() throws {
        let simple = response(200, #"{"choices":[{"message":{"content":"[1]"},"finish_reason":"stop"}]}"#)
        #expect(try TranslationWire.answer(from: simple, kind: .openAICompatible) == "[1]")
        let parts = response(200, #"{"choices":[{"message":{"content":[{"type":"text","text":"[{"},{"text":"}]"}]}}]}"#)
        #expect(try TranslationWire.answer(from: parts, kind: .openAICompatible) == "[{}]")
    }

    /// Anthropic：只取 text 块，思考块忽略。
    @Test func anthropicAnswerSkipsThinking() throws {
        let json = #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},"#
            + #"{"type":"text","text":"[{\"id\":1,"},{"type":"text","text":"\"text\":\"x\"}]"}]}"#
        #expect(try TranslationWire.answer(from: response(200, json), kind: .anthropic) == #"[{"id":1,"text":"x"}]"#)
    }

    /// refusal、max_tokens、finish_reason: length；空的 choices、没有文字、不是 JSON 都是格式不对。
    @Test func refusalTruncationAndMalformed() {
        #expect(failure(response(200, #"{"stop_reason":"refusal","content":[]}"#), .anthropic) == .refused)
        #expect(failure(response(200, #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"[{"}]}"#),
                        .anthropic) == .truncated)
        #expect(failure(response(200, #"{"choices":[{"message":{"content":"[{"},"finish_reason":"length"}]}"#)) == .truncated)
        #expect(failure(response(200, #"{"choices":[]}"#)) == .malformedAnswer)
        #expect(failure(response(200, #"{"choices":[{"message":{"content":"  "}}]}"#)) == .malformedAnswer)
        #expect(failure(response(200, "<html>oops</html>")) == .malformedAnswer)
        #expect(failure(response(200, #"{"stop_reason":"end_turn","content":[{"type":"thinking"}]}"#), .anthropic)
            == .malformedAnswer)
    }

    // MARK: 状态码

    /// 7.5 节表里每个状态码的归类。
    @Test func statusClassification() {
        #expect(failure(response(401, "{}")) == .unauthorized(status: 401))
        #expect(failure(response(403, "{}")) == .unauthorized(status: 403))
        #expect(failure(response(404, "{}")) == .notFound)
        #expect(failure(response(402, "{}")) == .insufficientBalance)
        #expect(failure(response(408, "{}")) == .server(status: 408))
        #expect(failure(response(409, "{}")) == .server(status: 409))
        #expect(failure(response(500, "{}")) == .server(status: 500))
        #expect(failure(response(529, "{}")) == .server(status: 529))
        #expect(failure(response(302, "")) == .rejected(status: 302, message: ""))
        #expect(failure(response(400, #"{"error":{"message":"bad field"}}"#)) == .rejected(status: 400, message: "bad field"))
        #expect(failure(response(422, #"{"message":"nope"}"#)) == .rejected(status: 422, message: "nope"))
        let long = String(repeating: "m", count: 300)
        #expect(failure(response(400, #"{"error":{"message":""# + long + #""}}"#))
            == .rejected(status: 400, message: String(repeating: "m", count: 200)))
    }

    /// 429 的 retry-after：取秒数并夹到 5～600；没有或不是数字时不给秒数（队列从 30 秒起加倍等待）。
    @Test func retryAfterClamping() {
        func wait(_ header: String?) -> TranslationFailure? {
            failure(response(429, "{}", headers: header.map { ["retry-after": $0] } ?? [:]))
        }
        #expect(wait("12") == .rateLimited(retryAfter: 12))
        #expect(wait("1") == .rateLimited(retryAfter: 5))
        #expect(wait("9999") == .rateLimited(retryAfter: 600))
        #expect(wait(nil) == .rateLimited(retryAfter: nil))
        #expect(wait("Wed, 21 Oct 2026 07:28:00 GMT") == .rateLimited(retryAfter: nil))
        #expect(TranslationFailure.rateLimited(retryAfter: nil).retryDelay == 30)
    }

    /// 传输层的失败：答复过大按网络失败处理。
    @Test func transportFailures() {
        #expect(TranslationWire.failure(for: .tooLarge) == .network("response too large"))
        #expect(TranslationWire.failure(for: .network("URLError -1001")) == .network("URLError -1001"))
    }

    // MARK: parse

    /// 前后带说明文字的答复；lang 转小写并截到 8 个字符；text 去首尾空白，空的忽略；不认识的编号忽略。
    @Test func parseTolerantAnswer() throws {
        let answer = """
        Here you go:
        [{"id": 1, "lang": "EN", "text": "  你好  "},
         {"id": 2, "lang": "zh-Hans-CN-extra", "text": "嗨"},
         {"id": 3, "text": "   "},
         {"id": 99, "text": "stray"},
         {"id": true, "text": "bool id"},
         {"id": 1.5, "text": "float id"},
         "junk"]
        Hope this helps.
        """
        let ids: [Int: UInt64] = [1: 100, 2: 200, 3: 300]
        let parsed = try TranslationWire.parse(answer, ids: ids)
        #expect(parsed == [100: TranslatedText(text: "你好", sourceLanguage: "en"),
                           200: TranslatedText(text: "嗨", sourceLanguage: "zh-hans-")])
    }

    /// 不是 JSON、没有方括号、不是数组时抛 malformedAnswer。
    @Test func parseRejectsNonJSON() {
        for answer in ["no brackets here", "[not json]", "] backwards [", "{\"id\": 1}"] {
            #expect(throws: TranslationFailure.malformedAnswer) { try TranslationWire.parse(answer, ids: [1: 1]) }
        }
    }
}
