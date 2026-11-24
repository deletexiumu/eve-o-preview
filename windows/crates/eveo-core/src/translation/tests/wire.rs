// SPDX-License-Identifier: GPL-3.0-or-later
//
// 请求与答复：两种接口的地址（含地址以 /v1 结尾）、请求头与请求体的键；请求体里没有 temperature；Key 为空时没有
// Authorization；两种接口的正常答复；content 是数组的 OpenAI 答复；含思考块的 Anthropic 答复只取文字；
// refusal、max_tokens、finish_reason: length；每个状态码的归类与 retry-after 的夹取；parse 对前后带说明文字的答复、
// 编号不认识的项、不是 JSON 的答复。用的 Key 是编造的。

use std::collections::BTreeMap;

use serde_json::Value;

use crate::model::{TranslationEndpointSettings, TranslationProviderId};
use crate::translation::prompt::PromptContent;
use crate::translation::providers::resolve;
use crate::translation::wire::{answer, failure_for, parse, request};
use crate::translation::{
    ApiKind, Endpoint, Failure, HttpRequest, HttpResponse, TranslatedText, TransportError,
};

/// 编造的 Key。
const KEY: &str = "sk-test-0000";

/// 一份固定的提示词。
fn content() -> PromptContent {
    PromptContent {
        system: "SYS".to_owned(),
        user: "USER".to_owned(),
        ids: BTreeMap::from([(1, 9)]),
    }
}

/// 某个预设的接口，模型名是 m-1；base 非空时覆盖地址。
fn endpoint(provider: TranslationProviderId, base: &str) -> Endpoint {
    resolve(&TranslationEndpointSettings {
        provider,
        base_url: base.to_owned(),
        model: "m-1".to_owned(),
    })
    .expect("测试用的接口应能解析")
}

/// 请求体解成 JSON。
fn body(request: &HttpRequest) -> Value {
    serde_json::from_slice(&request.body).expect("请求体是 JSON")
}

/// 请求头里的名字。
fn header_names(request: &HttpRequest) -> Vec<&str> {
    request.headers.keys().map(String::as_str).collect()
}

/// 答复。
fn response(status: u16, json: &str) -> HttpResponse {
    HttpResponse {
        status,
        headers: BTreeMap::new(),
        body: json.as_bytes().to_vec(),
    }
}

/// answer 给出的失败；成功时为 None。
fn failure(response: &HttpResponse, kind: ApiKind) -> Option<Failure> {
    answer(response, kind).err()
}

/// OpenAI 兼容：地址、请求头、请求体的键与键的顺序；没有 temperature 与 max_tokens。
#[test]
fn openai_request() {
    let request = request(
        &endpoint(TranslationProviderId::OpenAi, ""),
        Some(KEY),
        &content(),
    );
    // 预设地址已带 /v1，只补 /chat/completions。
    assert_eq!(request.url, "https://api.openai.com/v1/chat/completions");
    // 请求头按名字排序，只有这两项，不带任何用户标识。
    assert_eq!(header_names(&request), vec!["Authorization", "Content-Type"]);
    assert_eq!(request.headers["Authorization"], "Bearer sk-test-0000");
    assert_eq!(request.timeout_seconds, 60.0);
    assert_eq!(
        // 整个请求体逐字节比较：键按字母顺序，与 macOS 的 sortedKeys 相同，斜杠与中文都不转义。
        String::from_utf8(request.body.clone()).unwrap(),
        r#"{"messages":[{"content":"SYS","role":"system"},{"content":"USER","role":"user"}],"model":"m-1","stream":false}"#
    );
    // 不带 temperature：部分推理模型拒绝这个字段。
    assert!(body(&request).get("temperature").is_none());
}

/// Key 为空或 None 时没有 Authorization。
#[test]
fn openai_request_without_key() {
    // Ollama 不要 Key；本机的 http 地址可用。
    let ollama = endpoint(TranslationProviderId::Ollama, "");
    assert!(
        !request(&ollama, None, &content())
            .headers
            .contains_key("Authorization")
    );
    assert!(
        !request(&ollama, Some(""), &content())
            .headers
            .contains_key("Authorization")
    );
    assert_eq!(
        request(&ollama, None, &content()).url,
        "http://127.0.0.1:11434/v1/chat/completions"
    );
}

/// Anthropic：地址补 /v1/messages，地址以 /v1 结尾时只补 /messages；三个请求头；请求体的键。
#[test]
fn anthropic_request() {
    let request_one = request(
        &endpoint(TranslationProviderId::Anthropic, ""),
        Some(KEY),
        &content(),
    );
    assert_eq!(request_one.url, "https://api.anthropic.com/v1/messages");
    assert_eq!(
        header_names(&request_one),
        vec!["Content-Type", "anthropic-version", "x-api-key"]
    );
    // 版本头与 macOS 相同，两端用同一版接口。
    assert_eq!(request_one.headers["anthropic-version"], "2026-10-21");
    let json = body(&request_one);
    let keys: Vec<&String> = json.as_object().unwrap().keys().collect();
    assert_eq!(keys, vec!["max_tokens", "messages", "model", "system"]);
    assert_eq!(json["max_tokens"], 16_000);
    assert_eq!(json["system"], "SYS");
    // 代理地址已经写到 /v1：只补 /messages，不出现 /v1/v1。
    let proxied = request(
        &endpoint(TranslationProviderId::Anthropic, "https://gw.example.com/v1"),
        Some(KEY),
        &content(),
    );
    assert_eq!(proxied.url, "https://gw.example.com/v1/messages");
}

/// OpenAI 兼容：content 是字符串，或是分段的数组。Anthropic：只取 text 块，思考块忽略。
#[test]
fn normal_answers() {
    let simple = response(
        200,
        r#"{"choices":[{"message":{"content":"[1]"},"finish_reason":"stop"}]}"#,
    );
    assert_eq!(answer(&simple, ApiKind::OpenAiCompatible).unwrap(), "[1]");
    // 部分兼容接口把 content 写成分段的数组：各段的 text 连起来，没有 type 的段也算。
    let parts = response(
        200,
        r#"{"choices":[{"message":{"content":[{"type":"text","text":"[{"},{"text":"}]"}]}}]}"#,
    );
    assert_eq!(answer(&parts, ApiKind::OpenAiCompatible).unwrap(), "[{}]");
    // 思考块在前、文字分成两块：只取 text 块并连起来。
    let thinking = response(
        200,
        r#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"[{\"id\":1,"},{"type":"text","text":"\"text\":\"x\"}]"}]}"#,
    );
    assert_eq!(
        answer(&thinking, ApiKind::Anthropic).unwrap(),
        r#"[{"id":1,"text":"x"}]"#
    );
}

/// refusal、max_tokens、finish_reason: length；空的 choices、没有文字、不是 JSON 都是格式不对。
#[test]
fn refusal_truncation_and_malformed() {
    let open = ApiKind::OpenAiCompatible;
    let anthropic = ApiKind::Anthropic;
    // 被拒绝与被截断各有专门的失败，队列据此决定是否拆小重试。
    let refusal = response(200, r#"{"stop_reason":"refusal","content":[]}"#);
    assert_eq!(failure(&refusal, anthropic), Some(Failure::Refused));
    let capped = response(
        200,
        r#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"[{"}]}"#,
    );
    assert_eq!(failure(&capped, anthropic), Some(Failure::Truncated));
    let length = response(
        200,
        r#"{"choices":[{"message":{"content":"[{"},"finish_reason":"length"}]}"#,
    );
    assert_eq!(failure(&length, open), Some(Failure::Truncated));
    // 空的 choices、全是空白的文字、HTML 错误页都按格式不对处理。
    for json in [
        r#"{"choices":[]}"#,
        r#"{"choices":[{"message":{"content":"  "}}]}"#,
        "<html>oops</html>",
    ] {
        assert_eq!(
            failure(&response(200, json), open),
            Some(Failure::MalformedAnswer),
            "{json}"
        );
    }
    // 只有思考块没有文字：也是格式不对。
    let only_thinking = response(
        200,
        r#"{"stop_reason":"end_turn","content":[{"type":"thinking"}]}"#,
    );
    assert_eq!(failure(&only_thinking, anthropic), Some(Failure::MalformedAnswer));
}

/// 每个状态码的归类与说明的截取。
#[test]
fn status_classification() {
    let classify = |status: u16, json: &str| failure(&response(status, json), ApiKind::OpenAiCompatible);
    // Key 无效与没有权限：致命，等用户改设置。
    assert_eq!(classify(401, "{}"), Some(Failure::Unauthorized(401)));
    assert_eq!(classify(403, "{}"), Some(Failure::Unauthorized(403)));
    assert_eq!(classify(404, "{}"), Some(Failure::NotFound));
    assert_eq!(classify(402, "{}"), Some(Failure::InsufficientBalance));
    // 超时、冲突与 5xx 是服务暂时出错，可以自动重试。
    for status in [408, 409, 500, 529] {
        assert_eq!(classify(status, "{}"), Some(Failure::Server(status)));
    }
    let rejected = |status: u16, message: &str| {
        Some(Failure::Rejected {
            status,
            message: message.to_owned(),
        })
    };
    // 重定向不跟随，按请求不被接受处理；空正文的说明为空串。
    assert_eq!(classify(302, ""), rejected(302, ""));
    assert_eq!(
        classify(400, r#"{"error":{"message":"bad field"}}"#),
        rejected(400, "bad field")
    );
    assert_eq!(classify(422, r#"{"message":"nope"}"#), rejected(422, "nope"));
    // error 是字符串时直接当说明。
    assert_eq!(classify(418, r#"{"error":"teapot"}"#), rejected(418, "teapot"));
    // 过长的说明截到 200 个字符，界面上不会被撑开。
    let long = "m".repeat(300);
    let json = format!(r#"{{"error":{{"message":"{long}"}}}}"#);
    assert_eq!(classify(400, &json), rejected(400, &"m".repeat(200)));
    assert!(Failure::Unauthorized(401).is_fatal());
    assert!(!Failure::Server(500).is_fatal());
}

/// 429 的 retry-after：取秒数并夹到 5～600；没有或不是数字时不给秒数（队列从 30 秒起加倍等待）。
#[test]
fn retry_after_clamping() {
    let wait = |header: Option<&str>| {
        let mut limited = response(429, "{}");
        if let Some(value) = header {
            limited.headers.insert("retry-after".to_owned(), value.to_owned());
        }
        failure(&limited, ApiKind::OpenAiCompatible)
    };
    assert_eq!(wait(Some("12")), Some(Failure::RateLimited(Some(12.0))));
    assert_eq!(wait(Some("1")), Some(Failure::RateLimited(Some(5.0))));
    assert_eq!(wait(Some("9999")), Some(Failure::RateLimited(Some(600.0))));
    assert_eq!(wait(None), Some(Failure::RateLimited(None)));
    assert_eq!(
        // HTTP 日期写法不解析，与 macOS 相同。
        wait(Some("Wed, 21 Oct 2026 07:28:00 GMT")),
        Some(Failure::RateLimited(None))
    );
    assert_eq!(Failure::RateLimited(None).retry_delay(), 30.0);
    assert_eq!(Failure::MalformedAnswer.retry_delay(), 0.0);
}

/// 传输层的失败：答复过大按网络失败处理。
#[test]
fn transport_failures() {
    assert_eq!(
        failure_for(&TransportError::TooLarge),
        Failure::Network("response too large".to_owned())
    );
    assert_eq!(
        failure_for(&TransportError::Network("timeout".to_owned())),
        Failure::Network("timeout".to_owned())
    );
}

/// 前后带说明文字的答复；lang 转小写并截到 8 个字符；text 去首尾空白，空的忽略；不认识的编号忽略。
#[test]
fn parse_tolerant_answer() {
    let text = r#"Here you go:
[{"id": 1, "lang": "EN", "text": "  你好  "},
 {"id": 2, "lang": "zh-Hans-CN-extra", "text": "嗨"},
 {"id": 3, "text": "   "},
 {"id": 99, "text": "stray"},
 {"id": true, "text": "bool id"},
 {"id": 1.5, "text": "float id"},
 {"id": 3.0, "lang": "", "text": "whole"},
 "junk"]
Hope this helps."#;
    // 编号 1～3 对应消息 100～300；99、布尔值与带小数的编号都不认，3.0 这样的整值认。
    let ids = BTreeMap::from([(1, 100), (2, 200), (3, 300)]);
    let translated = |text: &str, lang: Option<&str>| TranslatedText {
        text: text.to_owned(),
        source_language: lang.map(str::to_owned),
    };
    assert_eq!(
        parse(text, &ids).unwrap(),
        BTreeMap::from([
            (100, translated("你好", Some("en"))),
            (200, translated("嗨", Some("zh-hans-"))),
            (300, translated("whole", None)),
        ])
    );
}

/// 不是 JSON、没有方括号、不是数组时是 MalformedAnswer。
#[test]
fn parse_rejects_non_json() {
    let ids = BTreeMap::from([(1, 1)]);
    // 方括号颠倒、方括号里不是 JSON、只有对象没有数组，都不认。
    for text in ["no brackets here", "[not json]", "] backwards [", "{\"id\": 1}"] {
        assert_eq!(parse(text, &ids), Err(Failure::MalformedAnswer), "{text}");
    }
}
