// SPDX-License-Identifier: GPL-3.0-or-later
//
// 会话标记与上一次运行的归类，对应 macOS 的 SessionModels.swift 与 SessionMarkerRules.swift（v1.1 设计 6.1 节）。
// 每次运行在 %APPDATA%\EVE-O Preview\session.json 里留一个标记，正常退出时标为已结束。
//
// 归类规则，按顺序取第一个成立的：
//
// | 上一次的标记 | 上一个进程还在 | 结果 |
// | --- | --- | --- |
// | 没有，或 markerVersion 不是 1 | 任意 | NoRecord |
// | endedCleanly 为真 | 任意 | Clean |
// | endedCleanly 为假 | 是 | StillRunning |
// | endedCleanly 为假 | 否 | Abnormal |
//
// 文件格式与 macOS 相同：键名 camelCase，startedAt 是精确到秒的 ISO 8601 字符串，键按字母排序。

//! 会话标记。

use serde_json::{Map, Value};

use crate::support::time::{iso8601_seconds, parse_iso8601};

/// 当前的标记格式版本。
pub const MARKER_VERSION: i64 = 1;

/// 一次运行的会话标记。
#[derive(Debug, Clone, PartialEq)]
pub struct SessionMarker {
    /// 标记格式的版本。
    pub marker_version: i64,
    /// 本次运行的编号（大写的 UUID 字符串）。
    pub session_id: String,
    /// 本次运行的进程 PID。
    pub pid: u32,
    /// 应用版本。
    pub app_version: String,
    /// 构建标签（debug、release 或发布流水线给的标签）。
    pub build_label: String,
    /// 开始运行的时刻（1970 年以来的秒数）。
    pub started_at: f64,
    /// 是否经过了正常的退出流程。
    pub ended_cleanly: bool,
}

impl SessionMarker {
    /// 解码 session.json 的内容；不是合法 JSON 或缺字段时返回 None。不检查版本（由 `outcome` 处理）。
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let Value::Object(root) = serde_json::from_slice::<Value>(bytes).ok()? else {
            return None;
        };
        let text = |key: &str| root.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            marker_version: root.get("markerVersion")?.as_i64()?,
            session_id: text("sessionID")?,
            pid: u32::try_from(root.get("pid")?.as_i64()?).ok()?,
            app_version: text("appVersion")?,
            build_label: text("buildLabel")?,
            started_at: parse_iso8601(&text("startedAt")?)?,
            ended_cleanly: root.get("endedCleanly")?.as_bool()?,
        })
    }

    /// 编码成文件内容：缩进两格、键按字母排序，末尾换行。
    pub fn encode(&self) -> Vec<u8> {
        let mut root = Map::new();
        root.insert("appVersion".into(), Value::from(self.app_version.clone()));
        root.insert("buildLabel".into(), Value::from(self.build_label.clone()));
        root.insert("endedCleanly".into(), Value::from(self.ended_cleanly));
        root.insert("markerVersion".into(), Value::from(self.marker_version));
        root.insert("pid".into(), Value::from(self.pid));
        root.insert("sessionID".into(), Value::from(self.session_id.clone()));
        root.insert("startedAt".into(), Value::from(iso8601_seconds(self.started_at)));
        let mut bytes = serde_json::to_vec_pretty(&Value::Object(root)).unwrap_or_else(|_| b"{}".to_vec());
        bytes.push(b'\n');
        bytes
    }
}

/// 上一次运行的归类。
#[derive(Debug, Clone, PartialEq)]
pub enum PreviousRunOutcome {
    /// 没有标记，或标记读不懂。
    NoRecord,
    /// 上一次正常结束。
    Clean,
    /// 上一个实例还在（例如重新启动时旧实例还没退完），不算异常。
    StillRunning(SessionMarker),
    /// 上一次没有正常结束。是否崩溃要看有没有崩溃的证据（crash 模块）。
    Abnormal(SessionMarker),
}

impl PreviousRunOutcome {
    /// 日志里的写法：`noRecord`、`clean`、`stillRunning`、`abnormal`（与 macOS 的报告摘要相同）。
    pub fn raw(&self) -> &'static str {
        match self {
            Self::NoRecord => "noRecord",
            Self::Clean => "clean",
            Self::StillRunning(_) => "stillRunning",
            Self::Abnormal(_) => "abnormal",
        }
    }
}

/// 按规则表归类上一次运行。previous_alive：标记里的进程仍在运行，且是本应用（不是被复用的 PID）。
pub fn outcome(previous: Option<SessionMarker>, previous_alive: bool) -> PreviousRunOutcome {
    let Some(previous) = previous.filter(|m| m.marker_version == MARKER_VERSION) else {
        return PreviousRunOutcome::NoRecord;
    };
    if previous.ended_cleanly {
        PreviousRunOutcome::Clean
    } else if previous_alive {
        PreviousRunOutcome::StillRunning(previous)
    } else {
        PreviousRunOutcome::Abnormal(previous)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 一个标记。
    fn marker(ended_cleanly: bool) -> SessionMarker {
        SessionMarker {
            marker_version: 1,
            session_id: "6F1D3C2A-0000-4000-8000-000000000001".to_owned(),
            pid: 4242,
            app_version: "0.9.0".to_owned(),
            build_label: "release".to_owned(),
            started_at: 1_763_697_906.0,
            ended_cleanly,
        }
    }

    /// 与 macOS 写出的文件互通；往返一致；缺字段或不是 JSON 时为 None。
    #[test]
    fn codec() {
        let macos = br#"{"appVersion":"1.1.0","buildLabel":"1.1.0","endedCleanly":false,"markerVersion":1,
            "pid":123,"sessionID":"ABC","startedAt":"2025-11-21T04:05:06Z"}"#;
        let decoded = SessionMarker::decode(macos).unwrap();
        assert_eq!(decoded.pid, 123);
        assert_eq!(decoded.started_at, 1_763_697_906.0);
        let original = marker(true);
        assert_eq!(SessionMarker::decode(&original.encode()), Some(original));
        assert!(
            String::from_utf8(marker(false).encode())
                .unwrap()
                .contains("\"startedAt\": \"2025-11-21T04:05:06Z\"")
        );
        for bad in [
            &b"not json"[..],
            b"[]",
            br#"{"markerVersion":1}"#,
            br#"{"pid":-1}"#,
        ] {
            assert_eq!(SessionMarker::decode(bad), None);
        }
    }

    /// 规则表的每一行。
    #[test]
    fn outcomes() {
        assert_eq!(outcome(None, false), PreviousRunOutcome::NoRecord);
        let future = SessionMarker {
            marker_version: 2,
            ..marker(false)
        };
        assert_eq!(outcome(Some(future), false), PreviousRunOutcome::NoRecord);
        assert_eq!(outcome(Some(marker(true)), true), PreviousRunOutcome::Clean);
        assert_eq!(
            outcome(Some(marker(false)), true),
            PreviousRunOutcome::StillRunning(marker(false))
        );
        let abnormal = outcome(Some(marker(false)), false);
        assert_eq!(abnormal.raw(), "abnormal");
    }
}
