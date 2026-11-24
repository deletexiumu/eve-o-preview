// SPDX-License-Identifier: GPL-3.0-or-later
//
// state.json 里的更新记录（键 `updates`），对应 macOS 的 `UpdateState`。
// 键名与 macOS 相同的字段含义也相同（`lastInstall`）；`pendingSwap` 是 Windows 独有的：
// 便携 exe 替换后等待新版确认（规则在 eveo_core::update::install）。
// 其余键（检查时刻、ETag、跳过的版本等，由更新控制器加入）在这里没有解析之前原样保留，写回时不丢。
// 某个字段的结构不对时只丢这一个字段，不连累别的记录：待确认的替换坏了，最多少一次回滚的机会。

//! state.json 的更新记录。

use eveo_core::support::time::{iso8601_seconds, parse_iso8601};
use eveo_core::update::install::{InstallRecord, PendingSwap};
use serde_json::{Map, Value};

/// 待确认的替换所在的键。
const PENDING_SWAP_KEY: &str = "pendingSwap";
/// 最近一次安装的结果所在的键。
const LAST_INSTALL_KEY: &str = "lastInstall";

/// 更新记录。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UpdateState {
    /// 待确认的替换。
    pub pending_swap: Option<PendingSwap>,
    /// 最近一次安装的结果。
    pub last_install: Option<InstallRecord>,
    /// updates 里还没解析的键，写回时原样保留。
    other: Map<String, Value>,
}

impl UpdateState {
    /// 从 JSON 解出；不是对象时取默认值。
    pub(crate) fn decode(value: Option<Value>) -> Self {
        let Some(Value::Object(mut map)) = value else {
            return Self::default();
        };
        let pending_swap = map.remove(PENDING_SWAP_KEY).as_ref().and_then(decode_swap);
        let last_install = map.remove(LAST_INSTALL_KEY).as_ref().and_then(decode_install);
        Self {
            pending_swap,
            last_install,
            other: map,
        }
    }

    /// 编码成 JSON；为空的字段不写键（与 macOS 的 Codable 对 nil 的处理相同）。
    pub(crate) fn encode(&self) -> Value {
        let mut map = self.other.clone();
        if let Some(swap) = &self.pending_swap {
            map.insert(PENDING_SWAP_KEY.to_owned(), encode_swap(swap));
        }
        if let Some(record) = &self.last_install {
            map.insert(LAST_INSTALL_KEY.to_owned(), encode_install(record));
        }
        Value::Object(map)
    }
}

/// 取一个字符串字段。
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// 解出待确认的替换；缺字段或类型不对时为 None。launchedAt 可以没有。
fn decode_swap(value: &Value) -> Option<PendingSwap> {
    Some(PendingSwap {
        version: text(value, "version")?.to_owned(),
        from_version: text(value, "fromVersion")?.to_owned(),
        at: parse_iso8601(text(value, "at")?)?,
        // 有这个键却解不出时整条作废：宁可不回滚，也不要把一次启动过的当作没启动过而无限重试。
        launched_at: match value.get("launchedAt") {
            None | Some(Value::Null) => None,
            Some(other) => Some(parse_iso8601(other.as_str()?)?),
        },
    })
}

/// 编码待确认的替换。时刻精确到秒，与 state.json 里别的时刻相同。
fn encode_swap(swap: &PendingSwap) -> Value {
    let mut map = Map::new();
    map.insert("at".into(), Value::from(iso8601_seconds(swap.at)));
    map.insert("fromVersion".into(), Value::from(swap.from_version.clone()));
    if let Some(launched) = swap.launched_at {
        map.insert("launchedAt".into(), Value::from(iso8601_seconds(launched)));
    }
    map.insert("version".into(), Value::from(swap.version.clone()));
    Value::Object(map)
}

/// 解出安装记录，键名与 macOS 相同。
fn decode_install(value: &Value) -> Option<InstallRecord> {
    Some(InstallRecord {
        version: text(value, "version")?.to_owned(),
        from_version: text(value, "fromVersion")?.to_owned(),
        at: parse_iso8601(text(value, "at")?)?,
        succeeded: value.get("succeeded")?.as_bool()?,
        error_code: text(value, "errorCode").map(str::to_owned),
    })
}

/// 编码安装记录；成功时不写 errorCode。
fn encode_install(record: &InstallRecord) -> Value {
    let mut map = Map::new();
    map.insert("at".into(), Value::from(iso8601_seconds(record.at)));
    if let Some(code) = &record.error_code {
        map.insert("errorCode".into(), Value::from(code.clone()));
    }
    map.insert("fromVersion".into(), Value::from(record.from_version.clone()));
    map.insert("succeeded".into(), Value::from(record.succeeded));
    map.insert("version".into(), Value::from(record.version.clone()));
    Value::Object(map)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 往返：两个字段都在；不认识的键保留；为空的字段不写键。
    #[test]
    fn round_trip() {
        let value = json!({
            "etag": "W/\"abc\"",
            "lastInstall": {"version": "0.9.1", "fromVersion": "0.9.0", "at": "2026-11-24T05:00:00Z",
                            "succeeded": false, "errorCode": "launchFailed"},
            "pendingSwap": {"version": "0.9.2", "fromVersion": "0.9.1", "at": "2026-11-24T06:00:00Z"}
        });
        let state = UpdateState::decode(Some(value));
        let swap = state.pending_swap.clone().unwrap();
        assert_eq!((swap.version.as_str(), swap.launched_at), ("0.9.2", None));
        let record = state.last_install.clone().unwrap();
        assert_eq!(record.error_code.as_deref(), Some("launchFailed"));
        let encoded = state.encode();
        assert_eq!(encoded["etag"], "W/\"abc\"");
        assert!(encoded["pendingSwap"].get("launchedAt").is_none());
        assert_eq!(UpdateState::decode(Some(encoded)), state);
        // 两个字段都为空时只剩不认识的键。
        let empty = UpdateState::decode(Some(json!({"skippedVersion": "1.0.0"}))).encode();
        assert_eq!(empty, json!({"skippedVersion": "1.0.0"}));
    }

    /// 坏字段只丢它自己；launchedAt 写坏时整条替换记录作废。
    #[test]
    fn bad_fields() {
        let state = UpdateState::decode(Some(json!({
            "pendingSwap": {"version": "0.9.2", "fromVersion": "0.9.1", "at": "2026-11-24T06:00:00Z",
                            "launchedAt": 5},
            "lastInstall": {"version": "0.9.1", "fromVersion": "0.9.0", "at": "2026-11-24T05:00:00Z",
                            "succeeded": true}
        })));
        assert_eq!(state.pending_swap, None);
        assert!(state.last_install.unwrap().succeeded);
        assert_eq!(UpdateState::decode(Some(json!([1]))), UpdateState::default());
        assert_eq!(UpdateState::decode(None), UpdateState::default());
    }
}
