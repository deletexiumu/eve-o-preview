// SPDX-License-Identifier: GPL-3.0-or-later
//
// 向 CCP 的 ESI 核对人名，对应 macOS 的 ESIPilotNameResolver.swift（设计文档 6.10 节）。
// 请求的写法与答复的解析都在 eveo-core::intel::pilots::wire，这里只用 http::send 发出去：
// 一次 resolve 发一个请求，不重试（重试与退避由队列决定）；只有 200 读正文，上限 1 MiB。
// 在人名核对服务的后台线程里调用。发出的名字是消息正文的一部分，这里不写日志。

//! ESI 人名核对的发送。

use std::time::Instant;

use eveo_core::intel::pilots::wire::{MAX_RESPONSE_BYTES, answer, request};
use eveo_core::intel::pilots::{PilotLookupAnswer, PilotLookupFailure};

use crate::http::{self, HttpError, HttpRequest};

/// 一次核对的结果与耗时（毫秒），耗时给日志用。
pub struct EsiResult {
    /// 结果。
    pub result: Result<PilotLookupAnswer, PilotLookupFailure>,
    /// HTTP 状态码；没收到答复时为 None。
    pub status: Option<u16>,
    /// 从发出到收完的毫秒数。
    pub elapsed_ms: u128,
}

/// 发一次核对请求。names 应已去重，1～500 个（wire::batches 的一组）；空时按 Rejected(400) 处理，不发请求。
pub fn resolve(names: &[String], app_version: &str) -> EsiResult {
    let started = Instant::now();
    if names.is_empty() {
        return EsiResult {
            result: Err(PilotLookupFailure::Rejected { status: 400 }),
            status: None,
            elapsed_ms: 0,
        };
    }
    let wire = request(names, app_version);
    let outcome = http::send(&HttpRequest {
        method: "POST",
        url: wire.url,
        headers: &wire.headers,
        body: wire.body.as_bytes(),
        timeout_seconds: wire.timeout_seconds,
        max_response_bytes: MAX_RESPONSE_BYTES,
        reads_body: |status| status == 200,
    });
    let elapsed_ms = started.elapsed().as_millis();
    match outcome {
        Ok(response) => EsiResult {
            result: answer(response.status, &response.headers, &response.body, names),
            status: Some(response.status),
            elapsed_ms,
        },
        // 正文过大与网络错误都归为 Network：队列按「稍后重试」处理。
        Err(error @ (HttpError::Network(_) | HttpError::TooLarge | HttpError::InvalidUrl)) => EsiResult {
            result: Err(PilotLookupFailure::Network(error.describe())),
            status: None,
            elapsed_ms,
        },
    }
}
