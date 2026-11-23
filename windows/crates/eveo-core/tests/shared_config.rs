// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置的一致性测试：读 shared/fixtures/config/cases.json，逐个走「解码 → 迁移 → 校验 → 编码」，
// 与期望结果比较（架构文档 5.4 节）。macOS 端的对应测试是 SharedConfigFixtureTests.swift。
// 期望里的 `<uuid>` 匹配任意大写 UUID，`<absent>` 表示这个键不应写出；`match` 为 subset 时只比较期望里出现的键。

//! 与 macOS 共用的配置用例。

use std::path::PathBuf;

use eveo_core::config::{self, ConfigError};
use serde::Deserialize;
use serde_json::Value;

/// cases.json 的顶层。
#[derive(Deserialize)]
struct CaseFile {
    /// 全部用例。
    cases: Vec<Case>,
}

/// 一个用例：输入是 JSON 值（`input`）或原始文字（`inputText`，用于不合法的 JSON）。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    /// 用例说明。
    name: String,
    /// 配置文件的内容。
    input: Option<Value>,
    /// 配置文件的原始文字。
    input_text: Option<String>,
    /// 期望结果。
    expected: Value,
}

/// 读用例文件。crate 在 windows/crates/eveo-core，往上三级是仓库根目录。
fn load() -> CaseFile {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures/config/cases.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}：{e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{} 格式不对：{e}", path.display()))
}

/// 是否是大写的 UUID（8-4-4-4-12 位十六进制）。
fn is_uuid(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    parts.iter().map(|p| p.len()).eq([8, 4, 4, 4, 12])
        && parts
            .iter()
            .all(|p| p.chars().all(|c| c.is_ascii_digit() || ('A'..='F').contains(&c)))
}

/// 按期望比较实际的 JSON：`exact` 为真时对象的键必须完全相同，否则只看期望里的键。
/// 不一致时返回出错位置的路径。
fn compare(expected: &Value, actual: Option<&Value>, exact: bool, path: &str) -> Result<(), String> {
    match (expected, actual) {
        (Value::String(s), actual) if s == "<absent>" => match actual {
            None => Ok(()),
            Some(v) => Err(format!("{path}：期望没有这个键，实际是 {v}")),
        },
        (_, None) => Err(format!("{path}：缺少这个键")),
        (Value::String(s), Some(Value::String(a))) if s == "<uuid>" => {
            if is_uuid(a) {
                Ok(())
            } else {
                Err(format!("{path}：{a} 不是 UUID"))
            }
        }
        (Value::Object(e), Some(Value::Object(a))) => {
            if exact {
                let extra: Vec<&String> = a.keys().filter(|k| !e.contains_key(*k)).collect();
                if !extra.is_empty() {
                    return Err(format!("{path}：多出的键 {extra:?}"));
                }
            }
            e.iter()
                .try_for_each(|(k, v)| compare(v, a.get(k), exact, &format!("{path}.{k}")))
        }
        (Value::Array(e), Some(Value::Array(a))) => {
            if e.len() != a.len() {
                return Err(format!("{path}：期望 {} 项，实际 {} 项", e.len(), a.len()));
            }
            e.iter()
                .zip(a)
                .enumerate()
                .try_for_each(|(i, (e, a))| compare(e, Some(a), exact, &format!("{path}[{i}]")))
        }
        // 数字按数值比较：384 与 384.0 相同。
        (Value::Number(e), Some(Value::Number(a))) if e.as_f64() == a.as_f64() => Ok(()),
        (e, Some(a)) if e == a => Ok(()),
        (e, Some(a)) => Err(format!("{path}：期望 {e}，实际 {a}")),
    }
}

/// 一个用例的实际结果，写成与期望相同的 JSON 结构。
fn run(case: &Case) -> Value {
    let text = case
        .input_text
        .clone()
        .unwrap_or_else(|| case.input.as_ref().expect("缺 input").to_string());
    match config::decode(&text) {
        Err(ConfigError::NewerSchema { found, .. }) => {
            serde_json::json!({"outcome": "newerSchema", "found": found})
        }
        Err(ConfigError::Corrupt(_)) => serde_json::json!({"outcome": "corrupt"}),
        Ok(decoded) => {
            let normalized = config::normalized(decoded.config);
            let encoded: Value = serde_json::from_str(&config::encode(&normalized.config)).unwrap();
            serde_json::json!({
                "outcome": "ok",
                "migratedFrom": decoded.migrated_from,
                "clamped": normalized.clamped,
                "config": encoded,
            })
        }
    }
}

/// 逐个用例比较。
#[test]
fn config_cases() {
    let file = load();
    assert!(!file.cases.is_empty());
    for case in &file.cases {
        let actual = run(case);
        let expected = &case.expected;
        assert_eq!(actual["outcome"], expected["outcome"], "{}", case.name);
        match expected["outcome"].as_str() {
            Some("newerSchema") => assert_eq!(actual["found"], expected["found"], "{}", case.name),
            Some("ok") => {
                assert_eq!(
                    actual["migratedFrom"], expected["migratedFrom"],
                    "{}：migratedFrom",
                    case.name
                );
                assert_eq!(actual["clamped"], expected["clamped"], "{}：clamped", case.name);
                let exact = expected["match"] == "exact";
                if let Err(message) = compare(&expected["config"], Some(&actual["config"]), exact, "config") {
                    panic!("{}：{message}", case.name);
                }
                // 校验后的配置再校验一次应当不变（幂等）。
                let again = config::normalized(config::decode(&actual["config"].to_string()).unwrap().config);
                assert!(
                    again.clamped.is_empty(),
                    "{}：第二次校验又改了 {:?}",
                    case.name,
                    again.clamped
                );
            }
            _ => {}
        }
    }
}
