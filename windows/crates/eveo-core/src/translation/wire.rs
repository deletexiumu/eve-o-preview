// SPDX-License-Identifier: GPL-3.0-or-later
//
// 模型服务的请求与答复，对应 macOS 的 TranslationWire.swift（设计文档 7.4 节、7.5 节）。
// - request：拼出 HTTP 请求。请求体只带各模型都接受的字段，不带 temperature、top_p、思考与强度的设置。
//   OpenAI 兼容接口不带 max_tokens；Anthropic 接口的 max_tokens 取 16,000（默认模型先思考，思考也计入上限；
//   一批 20 条、6,000 个字符的译文加上思考，8,192 会被截断）。
// - answer：按状态码归类失败，从 2xx 答复里取出模型写的文字。
// - parse：从模型的文字里取出 JSON 数组，按编号对回消息。
// - failure_for：传输层的失败换成翻译的失败。
// 请求头里有 Key，任何一处都不应把 headers 写进日志。
// 请求体的键按字母顺序输出（结构体字段按字母顺序声明），与 macOS 的 sortedKeys 结果逐字节相同。

//! 请求的拼法与答复的解析。

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{Map, Value};

use super::prompt::PromptContent;
use super::{ApiKind, Endpoint, Failure, HttpRequest, HttpResponse, TranslatedText, TransportError};

/// Anthropic Messages API 的版本头。
pub const ANTHROPIC_VERSION: &str = "2026-10-21";
/// Anthropic 请求的 max_tokens。
pub const ANTHROPIC_MAX_TOKENS: u32 = 16_000;
/// 请求的超时，单位是秒。
pub const TIMEOUT_SECONDS: f64 = 60.0;
/// 答复正文的上限，超过时按网络失败处理。
pub const MAX_RESPONSE_BYTES: usize = 1_048_576;
/// 429 的 retry-after 秒数的夹取范围。没有 retry-after 或解析不了时不给秒数，由队列从 30 秒起加倍。
pub const RETRY_AFTER_RANGE: (f64, f64) = (5.0, 600.0);
/// Rejected 的说明至多保留几个字符。
pub const MAX_ERROR_MESSAGE_CHARACTERS: usize = 200;
/// 原文语言代码至多保留几个字符。
const MAX_LANGUAGE_CODE_LENGTH: usize = 8;

/// 拼出一次请求。api_key 为 None 或空串时不带 Key 的请求头。
pub fn request(endpoint: &Endpoint, api_key: Option<&str>, content: &PromptContent) -> HttpRequest {
    // 凭据管理器里存的是空串时与没有 Key 相同：不发空的 Authorization。
    let key = api_key.filter(|k| !k.is_empty());
    // 请求头用有序表，测试与日志比较时顺序固定；值里有 Key，调用方不应打印。
    let mut headers = BTreeMap::from([("Content-Type".to_owned(), "application/json".to_owned())]);
    let (url, body) = match endpoint.kind {
        ApiKind::OpenAiCompatible => {
            if let Some(key) = key {
                headers.insert("Authorization".to_owned(), format!("Bearer {key}"));
            }
            let body = OpenAiRequest {
                messages: vec![
                    ChatTurn {
                        content: &content.system,
                        role: "system",
                    },
                    ChatTurn {
                        content: &content.user,
                        role: "user",
                    },
                ],
                model: &endpoint.model,
                stream: false,
            };
            // OpenAI 兼容接口的预设地址都已带版本路径（如 /v1），只补最后一段。
            (format!("{}/chat/completions", endpoint.base_url), encode(&body))
        }
        ApiKind::Anthropic => {
            if let Some(key) = key {
                headers.insert("x-api-key".to_owned(), key.to_owned());
            }
            // Anthropic 要求每个请求都带版本头，否则答 400。
            headers.insert("anthropic-version".to_owned(), ANTHROPIC_VERSION.to_owned());
            // 地址已经写到 /v1 时只补 /messages（代理常这样写），否则补 /v1/messages。
            let path = if endpoint.path.ends_with("/v1") {
                "/messages"
            } else {
                "/v1/messages"
            };
            let body = AnthropicRequest {
                max_tokens: ANTHROPIC_MAX_TOKENS,
                messages: vec![ChatTurn {
                    content: &content.user,
                    role: "user",
                }],
                model: &endpoint.model,
                system: &content.system,
            };
            (format!("{}{path}", endpoint.base_url), encode(&body))
        }
    };
    HttpRequest {
        url,
        headers,
        body,
        timeout_seconds: TIMEOUT_SECONDS,
    }
}

/// OpenAI 兼容接口的请求体。
#[derive(Serialize)]
struct OpenAiRequest<'a> {
    /// 系统提示与用户消息两条。
    messages: Vec<ChatTurn<'a>>,
    /// 模型名。
    model: &'a str,
    /// 总是 false：一次取回整个答复。
    stream: bool,
}

/// Anthropic 接口的请求体。字段名就是 JSON 的键。
#[derive(Serialize)]
struct AnthropicRequest<'a> {
    /// 输出（含思考）的上限。
    max_tokens: u32,
    /// 只有用户消息一条。
    messages: Vec<ChatTurn<'a>>,
    /// 模型名。
    model: &'a str,
    /// 系统提示。
    system: &'a str,
}

/// 一条对话消息。
#[derive(Serialize)]
struct ChatTurn<'a> {
    /// 文字。
    content: &'a str,
    /// system 或 user。
    role: &'a str,
}

/// 编码请求体。字段都是字符串、整数与布尔值，编码不会失败；万一失败退回 `{}`，服务会答 4xx。
fn encode<T: Serialize>(value: &T) -> Vec<u8> {
    serde_json::to_vec(value).unwrap_or_else(|_| b"{}".to_vec())
}

/// 传输层的失败换成翻译的失败：答复过大按网络失败处理（7.4 节）。
pub fn failure_for(error: &TransportError) -> Failure {
    match error {
        TransportError::Network(reason) => Failure::Network(reason.clone()),
        TransportError::TooLarge => Failure::Network("response too large".to_owned()),
    }
}

/// 从答复里取出模型写的文字；状态码不是 2xx、被拒绝或被截断时给出对应的失败（7.5 节的表）。
pub fn answer(response: &HttpResponse, kind: ApiKind) -> Result<String, Failure> {
    if let Some(failure) = status_failure(response) {
        return Err(failure);
    }
    // 2xx 但正文不是 JSON 对象（如网关的 HTML 页）：按格式不对处理，可以重试。
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&response.body) else {
        return Err(Failure::MalformedAnswer);
    };
    match kind {
        ApiKind::OpenAiCompatible => openai_text(&object),
        ApiKind::Anthropic => anthropic_text(&object),
    }
}

/// 状态码的归类；2xx 返回 None。
pub fn status_failure(response: &HttpResponse) -> Option<Failure> {
    let status = response.status;
    Some(match status {
        200..=299 => return None,
        401 | 403 => Failure::Unauthorized(status),
        402 => Failure::InsufficientBalance,
        404 => Failure::NotFound,
        // 只认秒数写法的 retry-after，键在传输层已转成小写。
        429 => Failure::RateLimited(retry_after(
            response.headers.get("retry-after").map(String::as_str),
        )),
        408 | 409 | 500..=599 => Failure::Server(status),
        _ => Failure::Rejected {
            status,
            message: error_message(&response.body),
        },
    })
}

/// retry-after 头里的秒数，夹到 5～600；没有或不是数字（如 HTTP 日期）时为 None。
pub fn retry_after(header: Option<&str>) -> Option<f64> {
    // 「12」「12.5」都认；NaN 与无穷大不认。
    let seconds: f64 = header?.trim().parse().ok()?;
    seconds
        .is_finite()
        .then(|| seconds.clamp(RETRY_AFTER_RANGE.0, RETRY_AFTER_RANGE.1))
}

/// 答复里的说明：`error.message`，没有时取顶层的 `message`，再没有时取字符串形式的 `error`，至多 200 个字符。
pub fn error_message(body: &[u8]) -> String {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(body) else {
        return String::new();
    };
    let message = object
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .or_else(|| object.get("message").and_then(Value::as_str))
        .or_else(|| object.get("error").and_then(Value::as_str))
        .unwrap_or("");
    message
        .trim()
        .chars()
        .take(MAX_ERROR_MESSAGE_CHARACTERS)
        .collect()
}

/// OpenAI 兼容答复的文字：`choices[0].message.content`，字符串直接用，数组把各项的 text 连起来。
/// `finish_reason` 是 length 时是被截断；choices 为空或文字为空时格式不对。
fn openai_text(object: &Map<String, Value>) -> Result<String, Failure> {
    let first = object
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(Value::as_object)
        .ok_or(Failure::MalformedAnswer)?;
    // 被截断的答复可能是半个 JSON 数组，不尝试解析，交给队列拆小重试。
    if first.get("finish_reason").and_then(Value::as_str) == Some("length") {
        return Err(Failure::Truncated);
    }
    let text = match first.get("message").and_then(|m| m.get("content")) {
        Some(Value::String(content)) => content.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .collect(),
        _ => String::new(),
    };
    non_blank(text)
}

/// Anthropic 答复的文字：`stop_reason` 是 refusal 时被拒绝，是 max_tokens 时被截断；
/// 其余情况把 content 里 type 是 text 的各块连起来，思考等别的块忽略。没有文字时格式不对。
fn anthropic_text(object: &Map<String, Value>) -> Result<String, Failure> {
    match object.get("stop_reason").and_then(Value::as_str) {
        Some("refusal") => return Err(Failure::Refused),
        Some("max_tokens") => return Err(Failure::Truncated),
        _ => {}
    }
    let text = object
        .get("content")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .collect()
        })
        .unwrap_or_default();
    non_blank(text)
}

/// 去掉空白后不为空的文字原样返回，否则是格式不对。
fn non_blank(text: String) -> Result<String, Failure> {
    if text.trim().is_empty() {
        Err(Failure::MalformedAnswer)
    } else {
        Ok(text)
    }
}

/// 从模型的文字里取出译文（7.4 节）：取第一个 `[` 到最后一个 `]` 之间的内容按 JSON 数组解析，
/// 解析失败或不是数组时是 MalformedAnswer。每个对象取 id（整数，应在 ids 里）、text（去首尾空白，空的忽略）、
/// lang（小写，至多 8 个字符，可缺）。
pub fn parse(answer: &str, ids: &BTreeMap<i64, u64>) -> Result<BTreeMap<u64, TranslatedText>, Failure> {
    // 模型常在数组前后加说明或代码块标记，只取最外层的方括号之间。
    let (Some(start), Some(end)) = (answer.find('['), answer.rfind(']')) else {
        return Err(Failure::MalformedAnswer);
    };
    if start >= end {
        return Err(Failure::MalformedAnswer);
    }
    let Ok(Value::Array(array)) = serde_json::from_str::<Value>(&answer[start..=end]) else {
        return Err(Failure::MalformedAnswer);
    };
    let mut results = BTreeMap::new();
    for element in &array {
        let Some(object) = element.as_object() else {
            continue;
        };
        // 模型编造的编号对不上任何消息，忽略这一项。
        let Some(message_id) = object.get("id").and_then(integer).and_then(|n| ids.get(&n)) else {
            continue;
        };
        let Some(text) = object.get("text").and_then(Value::as_str).map(str::trim) else {
            continue;
        };
        if text.is_empty() {
            continue;
        }
        // 语言代码只用于判断与显示，过长的截短，空串当作没给。
        let language = object
            .get("lang")
            .and_then(Value::as_str)
            .map(|code| code.trim().to_lowercase())
            .filter(|code| !code.is_empty())
            .map(|code| code.chars().take(MAX_LANGUAGE_CODE_LENGTH).collect());
        results.insert(
            *message_id,
            TranslatedText {
                text: text.to_owned(),
                source_language: language,
            },
        );
    }
    Ok(results)
}

/// JSON 里的整数：布尔值不算；带小数部分的数不算，`1.0` 这样的整值算；绝对值至少 10^9 的不算。
fn integer(value: &Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return (number.abs() < 1_000_000_000).then_some(number);
    }
    let double = value.as_f64()?;
    // 上面已排除超出范围的数，转换不会截断。
    (double.fract() == 0.0 && double.abs() < 1e9).then_some(double as i64)
}
