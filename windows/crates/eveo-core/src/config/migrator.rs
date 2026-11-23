// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置版本识别与迁移，对应 macOS 的 Config/ConfigMigrator.swift。先只读出 schemaVersion，
// 版本更新时直接报错，不做结构解码；版本较旧时在 JSON 对象上逐版本升级，再整体解码。

use std::fmt;

use serde_json::{Map, Value};

use crate::config::CURRENT_SCHEMA_VERSION;
use crate::model::AppConfig;

/// 读入配置时的错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// 配置文件来自更新的版本。应用用默认配置运行，本次会话不写盘。
    NewerSchema {
        /// 文件里的版本；超出整数范围时记为 `i64::MAX`。
        found: i64,
        /// 本版本支持的最高版本。
        supported: i64,
    },
    /// 文件内容损坏（不是合法 JSON、顶层不是对象、版本号不是非负整数或结构与模型不符）。
    /// 关联值是给开发者看的技术说明，只写日志。
    Corrupt(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::NewerSchema { found, supported } => {
                write!(f, "配置文件的版本 {found} 比本版本支持的 {supported} 新")
            }
            ConfigError::Corrupt(reason) => write!(f, "配置文件损坏：{reason}"),
        }
    }
}

impl std::error::Error for ConfigError {}

/// [`decode`] 的结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Decoded {
    /// 解码出的配置，`schema_version` 已是当前版本；尚未校验。
    pub config: AppConfig,
    /// 迁移前的版本；没有迁移时为 `None`。
    pub migrated_from: Option<i64>,
}

/// 读出 schemaVersion，逐版本升级到当前版本后解码。
///
/// - 顶层没有 `schemaVersion` 键时按当前版本处理（手写的最小配置也能读）。
/// - 版本 0 是开发期的预发布格式，与版本 1 的结构相同，升级只改版本号。
/// - 版本大于当前版本时返回 [`ConfigError::NewerSchema`]；其他问题返回 [`ConfigError::Corrupt`]，调用方据此隔离文件。
pub fn decode(text: &str) -> Result<Decoded, ConfigError> {
    let parsed: Value =
        serde_json::from_str(text).map_err(|e| ConfigError::Corrupt(format!("不是合法的 JSON：{e}")))?;
    let Value::Object(mut object) = parsed else {
        return Err(ConfigError::Corrupt("顶层不是 JSON 对象".to_owned()));
    };
    let version = schema_version(&object)?;
    if version > CURRENT_SCHEMA_VERSION {
        return Err(ConfigError::NewerSchema {
            found: version,
            supported: CURRENT_SCHEMA_VERSION,
        });
    }
    // 逐版本升级：每一步只负责从 v 到 v + 1，便于以后追加新版本。
    for from in version..CURRENT_SCHEMA_VERSION {
        upgrade(&mut object, from);
    }
    let mut config: AppConfig = serde_json::from_value(Value::Object(object))
        .map_err(|e| ConfigError::Corrupt(format!("结构与配置模型不符：{e}")))?;
    config.schema_version = CURRENT_SCHEMA_VERSION;
    Ok(Decoded {
        config,
        migrated_from: (version < CURRENT_SCHEMA_VERSION).then_some(version),
    })
}

/// 把配置编码成写盘用的文字：缩进排版，键按字母排序，便于手工查看和比较（与 macOS 的 sortedKeys 相同）。
pub fn encode(config: &AppConfig) -> String {
    // serde_json 的 Map 默认是有序的 BTreeMap，先转成 Value 就得到按键排序的输出。
    let value = serde_json::to_value(config).expect("配置模型总能编码成 JSON");
    serde_json::to_string_pretty(&value).expect("JSON 值总能写成文字")
}

/// 读出版本号。缺失时取当前版本；不是非负整数时视为损坏。
///
/// 超出整数范围的非负整数（如 `1e20`）一定大于当前版本，返回 `NewerSchema`，`found` 记为 `i64::MAX`；
/// 带小数或为负的值仍视为损坏。布尔值不算数字。
fn schema_version(object: &Map<String, Value>) -> Result<i64, ConfigError> {
    let Some(raw) = object.get("schemaVersion") else {
        return Ok(CURRENT_SCHEMA_VERSION);
    };
    let invalid = || ConfigError::Corrupt("schemaVersion 不是非负整数".to_owned());
    let Value::Number(number) = raw else {
        return Err(invalid());
    };
    if let Some(v) = number.as_u64() {
        return Ok(i64::try_from(v).unwrap_or(i64::MAX));
    }
    let value = number.as_f64().ok_or_else(invalid)?;
    if !value.is_finite() || value < 0.0 || value.trunc() != value {
        return Err(invalid());
    }
    // 2^63 及以上的整数放不进 i64，一定比当前版本新。
    if value >= 9_223_372_036_854_775_808.0 {
        return Err(ConfigError::NewerSchema {
            found: i64::MAX,
            supported: CURRENT_SCHEMA_VERSION,
        });
    }
    Ok(value as i64)
}

/// 从版本 `from` 升级到 `from + 1`。新增版本时在这里追加一个分支。
fn upgrade(object: &mut Map<String, Value>, from: i64) {
    if from == 0 {
        // 版本 0 与版本 1 的结构相同，只改版本号。
        object.insert("schemaVersion".to_owned(), Value::from(1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 空对象按当前版本读出，配置方案为空（由校验补上）。
    #[test]
    fn empty_object() {
        let decoded = decode("{}").unwrap();
        assert_eq!(decoded.migrated_from, None);
        assert!(decoded.config.profiles.is_empty());
    }

    /// 版本 0 迁移到 1。
    #[test]
    fn migrates_v0() {
        let decoded = decode(r#"{"schemaVersion": 0}"#).unwrap();
        assert_eq!(decoded.migrated_from, Some(0));
        assert_eq!(decoded.config.schema_version, 1);
    }

    /// 新版本、超大版本、非法版本与非法 JSON。
    #[test]
    fn version_errors() {
        assert_eq!(
            decode(r#"{"schemaVersion": 2}"#),
            Err(ConfigError::NewerSchema {
                found: 2,
                supported: 1
            })
        );
        assert_eq!(
            decode(r#"{"schemaVersion": 1e20}"#),
            Err(ConfigError::NewerSchema {
                found: i64::MAX,
                supported: 1
            })
        );
        for bad in [
            r#"{"schemaVersion": -1}"#,
            r#"{"schemaVersion": 1.5}"#,
            r#"{"schemaVersion": true}"#,
            "[]",
            "{",
        ] {
            assert!(matches!(decode(bad), Err(ConfigError::Corrupt(_))), "{bad}");
        }
    }

    /// 写出的文字按键排序，可以读回同一份配置。
    #[test]
    fn encode_round_trip() {
        let config = AppConfig::make_default("ID");
        let text = encode(&config);
        assert!(text.find("\"activeProfileID\"").unwrap() < text.find("\"general\"").unwrap());
        assert_eq!(decode(&text).unwrap().config, config);
    }
}
