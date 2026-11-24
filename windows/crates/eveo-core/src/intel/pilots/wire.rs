// SPDX-License-Identifier: GPL-3.0-or-later
//
// ESI 人名核对的请求与答复，对应 macOS 的 ESINameWire.swift（设计文档 6.10 节，依据 E1～E6）。
// 请求：POST https://esi.evetech.net/universe/ids，不带查询串，请求体是名字的 JSON 数组。6 个请求头：
// Content-Type、Accept、Accept-Language: en、X-Compatibility-Date: 2020-01-01、X-Tenant: tranquility、User-Agent。
// User-Agent 里只有应用名、版本与项目地址，不写邮箱、角色名或任何能认出用户的内容。
// batches 保证每组不为空、各项的比较键互不相同、每项 1～100 个字符：任一条不满足，ESI 返回 400 并扣错误额度（E5）。
//
// 答复：
// | 状态码          | 结果                                                                                 |
// | 200            | 解析：角色只从 characters 取；同名的游戏对象存在时是 Ambiguous                          |
// | 420、429       | RateLimited：先取 retry-after，再取 x-esi-error-limit-reset，都没有时 60，夹到 5～600   |
// | 408、5xx       | Server                                                                               |
// | 3xx 与其他 4xx  | Rejected：请求本身有问题，不重试                                                      |
// alliances、corporations 与 agents 不读：它们按简称匹配，返回的名称与请求对不上（E4）。
// 这里只拼请求、解析答复；发请求在 app 层（WinHTTP），本文件不写日志。

//! ESI 人名核对的请求写法与答复解析。

use std::collections::{HashMap, HashSet};

use serde_json::Value;

use super::{PilotLookupAnswer, PilotLookupFailure, PilotLookupOutcome, key, normalize};

/// 接口地址。
pub const ENDPOINT: &str = "https://esi.evetech.net/universe/ids";
/// `X-Compatibility-Date` 的值；接口描述里只有这一个可选值（E1）。
pub const COMPATIBILITY_DATE: &str = "2020-01-01";
/// 一次请求至多几个名字。
pub const MAX_NAMES_PER_REQUEST: usize = 500;
/// 每个名字至多几个字符。
pub const MAX_NAME_LENGTH: usize = 100;
/// 超时秒数。
pub const TIMEOUT_SECONDS: f64 = 10.0;
/// 答复正文的上限；超过时是 Network("response too large")。正常的答复只有几 KB，上限防止异常答复占满内存。
pub const MAX_RESPONSE_BYTES: usize = 1_048_576;
/// 被限流时等待秒数的下限与上限。
const RETRY_MIN: f64 = 5.0;
/// 见 [`RETRY_MIN`]。
const RETRY_MAX: f64 = 600.0;
/// 答复头里没有等待秒数时的默认值。
const DEFAULT_RETRY: f64 = 60.0;

/// 会让「有同名角色」变成 Ambiguous 的游戏对象类别。同名时消息里指的多半是物品或地点（6.10 节第 4 条）。
const OBJECT_CATEGORIES: [&str; 6] = [
    "inventory_types",
    "systems",
    "constellations",
    "regions",
    "stations",
    "factions",
];

/// 一次核对请求的内容，交给 app 层发出。
#[derive(Debug, Clone, PartialEq)]
pub struct EsiNameRequest {
    /// 请求地址。
    pub url: &'static str,
    /// 请求头，按固定顺序排列。
    pub headers: Vec<(&'static str, String)>,
    /// 请求体：名字的 JSON 数组（UTF-8）。
    pub body: String,
    /// 超时秒数。
    pub timeout_seconds: f64,
}

/// User-Agent：应用名、版本与项目地址。和 macOS 的区别只在应用名，便于 ESI 一侧区分两个平台。
pub fn user_agent(app_version: &str) -> String {
    format!("EVE-O-Preview-Windows/{app_version} (+https://github.com/deletexiumu/eve-o-preview)")
}

/// 把名字整理成可以发送的几组：连续的空白并成一个空格，去掉空的与超过 100 个字符的，按比较键去重，
/// 每组至多 500 个。输入为空时没有组。
pub fn batches<S: AsRef<str>>(names: &[S]) -> Vec<Vec<String>> {
    let mut seen = HashSet::new();
    let mut accepted = Vec::new();
    for raw in names {
        let name = normalize(raw.as_ref());
        // 长度按字符数算，与 ESI 的限制一致（不是字节数）。
        if name.is_empty() || name.chars().count() > MAX_NAME_LENGTH || !seen.insert(key(&name)) {
            continue;
        }
        accepted.push(name);
    }
    accepted
        .chunks(MAX_NAMES_PER_REQUEST)
        .map(<[String]>::to_vec)
        .collect()
}

/// 一次请求的内容。names 应已经过 [`batches`] 整理。
pub fn request<S: AsRef<str>>(names: &[S], app_version: &str) -> EsiNameRequest {
    let list: Vec<&str> = names.iter().map(AsRef::as_ref).collect();
    // 字符串数组的 JSON 编码不会失败；万一失败，发空数组会得到 400（Rejected），不会静默丢名字。
    let body = serde_json::to_string(&list).unwrap_or_else(|_| "[]".to_owned());
    let headers = vec![
        ("Content-Type", "application/json".to_owned()),
        ("Accept", "application/json".to_owned()),
        ("Accept-Language", "en".to_owned()),
        ("X-Compatibility-Date", COMPATIBILITY_DATE.to_owned()),
        ("X-Tenant", "tranquility".to_owned()),
        ("User-Agent", user_agent(app_version)),
    ];
    EsiNameRequest {
        url: ENDPOINT,
        headers,
        body,
        timeout_seconds: TIMEOUT_SECONDS,
    }
}

/// 把答复换成结果。headers 的键是小写。names 是这次请求发出的名字，每个名字在结果里各有一项。
pub fn answer<S: AsRef<str>>(
    status: u16,
    headers: &HashMap<String, String>,
    body: &[u8],
    names: &[S],
) -> Result<PilotLookupAnswer, PilotLookupFailure> {
    match status {
        200 => {}
        420 | 429 => {
            return Err(PilotLookupFailure::RateLimited {
                retry_after: retry_seconds(headers),
            });
        }
        408 | 500..=599 => return Err(PilotLookupFailure::Server { status }),
        _ => return Err(PilotLookupFailure::Rejected { status }),
    }
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(PilotLookupFailure::Network("response too large".to_owned()));
    }
    // 根必须是对象；数组、数字或解析不了都算答复格式不对。
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(body) else {
        return Err(PilotLookupFailure::MalformedAnswer);
    };
    // 角色表：比较键 → (ID, ESI 的写法)。缺 name 或 id 的项跳过，不让一项坏数据拖垮整个答复。
    let mut characters: HashMap<String, (i64, String)> = HashMap::new();
    for item in items(root.get("characters")).ok_or(PilotLookupFailure::MalformedAnswer)? {
        if let (Some(name), Some(id)) = (item.get("name").and_then(Value::as_str), integer(item.get("id"))) {
            characters.insert(key(name), (id, name.to_owned()));
        }
    }
    // 游戏对象的比较键。
    let mut objects = HashSet::new();
    for category in OBJECT_CATEGORIES {
        for item in items(root.get(category)).ok_or(PilotLookupFailure::MalformedAnswer)? {
            if let Some(name) = item.get("name").and_then(Value::as_str) {
                objects.insert(key(name));
            }
        }
    }
    // 每个发出的名字各给一项：没出现在 characters 里的是 NotFound，这样缓存能记下「查过、没有」。
    let mut outcomes = HashMap::new();
    for name in names {
        let name_key = key(name.as_ref());
        let outcome = match characters.get(&name_key) {
            Some(_) if objects.contains(&name_key) => PilotLookupOutcome::Ambiguous,
            Some((id, esi_name)) => PilotLookupOutcome::matched(*id, esi_name),
            None => PilotLookupOutcome::NotFound,
        };
        outcomes.insert(name_key, outcome);
    }
    Ok(PilotLookupAnswer {
        outcomes,
        error_limit_remain: header_int(headers, "x-esi-error-limit-remain"),
        error_limit_reset: header_int(headers, "x-esi-error-limit-reset"),
    })
}

/// 被限流时等多少秒：retry-after，没有时 x-esi-error-limit-reset，都没有时 60，夹到 5～600。
/// 不是有限数（`inf`、`NaN`）时也按 60 算，避免永远等下去或立即重发。
pub(crate) fn retry_seconds(headers: &HashMap<String, String>) -> f64 {
    let parse = |name: &str| headers.get(name).and_then(|v| v.trim().parse::<f64>().ok());
    let raw = parse("retry-after")
        .or_else(|| parse("x-esi-error-limit-reset"))
        .unwrap_or(DEFAULT_RETRY);
    let value = if raw.is_finite() { raw } else { DEFAULT_RETRY };
    value.clamp(RETRY_MIN, RETRY_MAX)
}

/// 一个类别的各项：类别缺失时是空列表（没有命中的类别不出现，E2）；不是数组时返回 None。
/// 数组里不是对象的元素丢掉。
fn items(value: Option<&Value>) -> Option<Vec<&serde_json::Map<String, Value>>> {
    match value {
        None => Some(Vec::new()),
        Some(Value::Array(array)) => Some(array.iter().filter_map(Value::as_object).collect()),
        Some(_) => None,
    }
}

/// JSON 里的整数：整数直接取；`5.0` 这类没有小数部分的浮点数也接受（与 macOS 的 JSONSerialization 一致），
/// 带小数、太大、不是数时为 None。布尔值不是数，serde_json 本来就不会把它当数。
fn integer(value: Option<&Value>) -> Option<i64> {
    let number = value?.as_number()?;
    // 上限 1e15 与 macOS 相同：超过它的数在 Double 里已不能逐一表示，当作坏数据。
    const LIMIT: i64 = 1_000_000_000_000_000;
    if let Some(int) = number.as_i64() {
        return (int.unsigned_abs() < LIMIT as u64).then_some(int);
    }
    let double = number.as_f64()?;
    (double.is_finite() && double.round() == double && double.abs() < LIMIT as f64).then_some(double as i64)
}

/// 答复头里的整数；没有或不是整数时为 None。
fn header_int(headers: &HashMap<String, String>, name: &str) -> Option<i64> {
    headers.get(name).and_then(|v| v.trim().parse().ok())
}
