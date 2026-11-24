// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译请求的发送，对应 macOS 的 URLSessionTranslationTransport.swift（设计文档 7.4 节）。
// 请求的写法与答复的解析都在 eveo-core::translation::wire，这里只用 http::send 发出去：
// - 每次一个请求，不重试（重试与等待由翻译队列决定）。
// - 所有状态码都读正文（4xx 的说明要显示给用户），上限 1 MiB，超过时按「答复过大」交回。
// - 允许明文 http：eveo-core::translation::providers::resolve 已经只放行本机与局域网的 http 地址。
// - User-Agent 是 `EVE-O-Preview-Windows/<版本>`，不带用户的任何信息。
// 在翻译总控的后台线程里调用。请求头里有 API Key，请求体与答复里有聊天内容，这里一概不写日志。

//! 翻译请求的 HTTP 发送。

use std::collections::BTreeMap;

use eveo_core::translation::wire::MAX_RESPONSE_BYTES;
use eveo_core::translation::{HttpRequest as WireRequest, HttpResponse as WireResponse, TransportError};

use crate::http::{self, HttpError, HttpRequest};

/// 发一次翻译请求并等答复。阻塞，只在后台线程里调用。
pub fn send(request: &WireRequest, app_version: &str) -> Result<WireResponse, TransportError> {
    // 请求头：core 给的几项（Content-Type、Key、版本头）加上 User-Agent。
    let mut headers: Vec<(&str, String)> = request
        .headers
        .iter()
        .map(|(name, value)| (name.as_str(), value.clone()))
        .collect();
    headers.push(("User-Agent", format!("EVE-O-Preview-Windows/{app_version}")));
    let outcome = http::send(&HttpRequest {
        method: "POST",
        url: &request.url,
        headers: &headers,
        body: &request.body,
        timeout_seconds: request.timeout_seconds,
        max_response_bytes: MAX_RESPONSE_BYTES,
        reads_body: |_| true,
        allows_http: true,
    });
    // 请求头里的 Key 用完就抹掉，不留在这一份副本里。
    for (_, value) in &mut headers {
        value.clear();
    }
    match outcome {
        Ok(response) => Ok(WireResponse {
            status: response.status,
            headers: response.headers.into_iter().collect::<BTreeMap<_, _>>(),
            body: response.body,
        }),
        Err(HttpError::TooLarge) => Err(TransportError::TooLarge),
        Err(error @ (HttpError::Network(_) | HttpError::InvalidUrl | HttpError::Cancelled)) => {
            Err(TransportError::Network(error.describe()))
        }
    }
}
