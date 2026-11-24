// SPDX-License-Identifier: GPL-3.0-or-later
//
// ESI 请求的写法与答复的解析：请求头与请求体、分组、200 的各种答复、限流与其他状态码。

use std::collections::HashMap;

use crate::intel::pilots::wire::{MAX_RESPONSE_BYTES, answer, batches, request};
use crate::intel::pilots::{PilotLookupAnswer, PilotLookupFailure, PilotLookupOutcome};

/// 结果的简写。
type Answer = Result<PilotLookupAnswer, PilotLookupFailure>;

/// 用（键，值）列表建答复头。
fn headers(items: &[(&str, &str)]) -> HashMap<String, String> {
    items
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

/// 把 JSON 文本当作 200 的答复解析。
fn parse(json: &str, names: &[&str]) -> Answer {
    answer(200, &HashMap::new(), json.as_bytes(), names)
}

/// 取成功的结果；失败时测试失败。
fn outcomes(result: Answer) -> HashMap<String, PilotLookupOutcome> {
    result.expect("应当成功").outcomes
}

/// 请求：地址不带查询串，6 个请求头，请求体是名字的 JSON 数组，超时 10 秒。
#[test]
fn request_shape() {
    // 版本号随请求发出，ESI 一侧出问题时能按版本联系到项目；不含任何用户信息。
    let value = request(&["Kael Doran", "Mira Voss"], "1.2.0");
    assert_eq!(value.url, "https://esi.evetech.net/universe/ids");
    assert!(!value.url.contains('?'));
    let expected = [
        ("Content-Type", "application/json"),
        ("Accept", "application/json"),
        ("Accept-Language", "en"),
        ("X-Compatibility-Date", "2020-01-01"),
        ("X-Tenant", "tranquility"),
        (
            "User-Agent",
            "EVE-O-Preview-Windows/1.2.0 (+https://github.com/deletexiumu/eve-o-preview)",
        ),
    ];
    let actual: Vec<(&str, &str)> = value.headers.iter().map(|(k, v)| (*k, v.as_str())).collect();
    assert_eq!(actual, expected);
    let body: Vec<String> = serde_json::from_str(&value.body).unwrap();
    assert_eq!(body, ["Kael Doran", "Mira Voss"]);
    assert_eq!(value.timeout_seconds, 10.0);
}

/// 分组：空的、只有空白的、超过 100 个字符的去掉；空白并成一个空格；按比较键去重；每组至多 500 个。
#[test]
fn batch_rules() {
    assert!(batches::<&str>(&[]).is_empty());
    let long = "a".repeat(101);
    // 任何一项不合规，ESI 都会让整个请求 400 并扣错误额度，所以发出前先筛掉。
    let names = ["", "  ", long.as_str(), "Kael  Doran", "kael doran", "Mira"];
    assert_eq!(
        batches(&names),
        [vec!["Kael Doran".to_owned(), "Mira".to_owned()]]
    );
    let many: Vec<String> = (0..501).map(|i| format!("Name{i}")).collect();
    let sizes: Vec<usize> = batches(&many).iter().map(Vec::len).collect();
    assert_eq!(sizes, [500, 1]);
    // 正好 100 个字符的留下。
    assert_eq!(batches(&["b".repeat(100)])[0][0].len(), 100);
}

/// 角色按比较键对照，结果用 ESI 的写法；请求里的每个名字都有一项。
#[test]
fn characters_match_case_insensitively() {
    let json = r#"{"characters":[{"id":90000001,"name":"Kael Doran"}],
        "alliances":[{"id":99000001,"name":"Something Else"}]}"#;
    // alliances 按简称匹配，名称与请求对不上，不读。
    let result = outcomes(parse(json, &["kael DORAN", "Mira Voss"]));
    assert_eq!(
        result["kael doran"],
        PilotLookupOutcome::matched(90_000_001, "Kael Doran")
    );
    assert_eq!(result["mira voss"], PilotLookupOutcome::NotFound);
    assert_eq!(result.len(), 2);
}

/// 同名的物品存在时是 Ambiguous：「Stabber」更可能指船，不是叫 Stabber 的角色。
#[test]
fn game_objects_make_ambiguous() {
    let json = r#"{"characters":[{"id":1,"name":"STABBER"},{"id":2,"name":"Veldspar"}],
        "inventory_types":[{"id":622,"name":"Stabber"},{"id":1230,"name":"Veldspar"}]}"#;
    let result = outcomes(parse(json, &["Stabber", "Veldspar"]));
    assert_eq!(result["stabber"], PilotLookupOutcome::Ambiguous);
    assert_eq!(result["veldspar"], PilotLookupOutcome::Ambiguous);
}

/// 空答复全是 NotFound；corporations 里名称对不上的项与请求以外的角色都忽略。
#[test]
fn empty_answer_and_ignored_categories() {
    let not_found = |result: Answer| outcomes(result)["kael doran"].clone();
    assert_eq!(
        not_found(parse("{}", &["Kael Doran"])),
        PilotLookupOutcome::NotFound
    );
    let json =
        r#"{"corporations":[{"id":5,"name":"Kael Doran Corp"}],"characters":[{"id":3,"name":"Someone"}]}"#;
    assert_eq!(
        not_found(parse(json, &["Kael Doran"])),
        PilotLookupOutcome::NotFound
    );
    // `5.0` 这类整数值的浮点数也认作 ID；带小数的项跳过。
    let json = r#"{"characters":[{"id":5.0,"name":"Kael Doran"},{"id":1.5,"name":"Mira Voss"}]}"#;
    let result = outcomes(parse(json, &["Kael Doran", "Mira Voss"]));
    assert_eq!(result["kael doran"], PilotLookupOutcome::matched(5, "Kael Doran"));
    assert_eq!(result["mira voss"], PilotLookupOutcome::NotFound);
}

/// 根不是对象、不是 JSON、类别不是数组时是 MalformedAnswer；超过 1 MiB 是 Network。
#[test]
fn malformed_bodies() {
    assert_eq!(parse("[]", &["a"]), Err(PilotLookupFailure::MalformedAnswer));
    assert_eq!(
        parse("not json", &["a"]),
        Err(PilotLookupFailure::MalformedAnswer)
    );
    assert_eq!(
        parse(r#"{"characters": 5}"#, &["a"]),
        Err(PilotLookupFailure::MalformedAnswer)
    );
    assert_eq!(
        parse(r#"{"systems": null}"#, &["a"]),
        Err(PilotLookupFailure::MalformedAnswer)
    );
    // null 不是数组，也算格式不对（类别缺失才当空列表）。正文过大时不解析，直接当网络问题。
    let huge = vec![b' '; MAX_RESPONSE_BYTES + 1];
    assert_eq!(
        answer(200, &HashMap::new(), &huge, &["a"]),
        Err(PilotLookupFailure::Network("response too large".into()))
    );
}

/// 错误额度的两个答复头；不是整数时为 None。
#[test]
fn error_limit_headers() {
    let limits = headers(&[
        ("x-esi-error-limit-remain", "98"),
        ("x-esi-error-limit-reset", "42"),
    ]);
    let value = answer(200, &limits, b"{}", &["a"]).unwrap();
    assert_eq!(
        (value.error_limit_remain, value.error_limit_reset),
        (Some(98), Some(42))
    );
    let bare = answer(200, &headers(&[("x-esi-error-limit-remain", "x")]), b"{}", &["a"]).unwrap();
    assert_eq!((bare.error_limit_remain, bare.error_limit_reset), (None, None));
}

/// 420、429：先取 retry-after，再取 x-esi-error-limit-reset，都没有时 60，夹到 5～600。
#[test]
fn rate_limits() {
    let retry = |status: u16, items: &[(&str, &str)]| answer(status, &headers(items), b"", &["a"]);
    let limited = |seconds: f64| Err(PilotLookupFailure::RateLimited { retry_after: seconds });
    assert_eq!(retry(429, &[("retry-after", "30")]), limited(30.0));
    assert_eq!(retry(420, &[("x-esi-error-limit-reset", "45")]), limited(45.0));
    assert_eq!(retry(420, &[]), limited(60.0));
    assert_eq!(retry(429, &[("retry-after", "1")]), limited(5.0));
    assert_eq!(retry(429, &[("retry-after", "9999")]), limited(600.0));
    // 不是有限数时按 60 算。
    assert_eq!(retry(429, &[("retry-after", "inf")]), limited(60.0));
}

/// 408 与 5xx 是 Server；3xx 与其他 4xx 是 Rejected。
#[test]
fn status_classes() {
    let classify = |status: u16| answer(status, &HashMap::new(), b"{}", &["a"]);
    assert_eq!(classify(503), Err(PilotLookupFailure::Server { status: 503 }));
    assert_eq!(classify(408), Err(PilotLookupFailure::Server { status: 408 }));
    assert_eq!(classify(400), Err(PilotLookupFailure::Rejected { status: 400 }));
    assert_eq!(classify(302), Err(PilotLookupFailure::Rejected { status: 302 }));
    assert_eq!(classify(404), Err(PilotLookupFailure::Rejected { status: 404 }));
}
