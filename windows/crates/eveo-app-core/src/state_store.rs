// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用自己记下的状态 state.json，对应 macOS 的 AppState 与 JSONStateStore（docs/macos/design-v1.1.md 3.3 节）。
// 位置：%APPDATA%\EVE-O Preview\state.json（paths::DataPaths::state_file），与用户的 config.json 分开：
// - config.json 每次改动都重算规划；state.json 里的记录（手动位置、以后的更新检查时刻）改了不应触发这些。
// - config.json 读取失败时整个会话不写盘；state.json 丢了也只是少了几条记录。
//
// Windows 用到的部分：
// - chat.manualLocations（docs/macos/design-intel-translate.md 6.2 节）：角色名 → 手动设置的位置。
//   角色登录后一直停在同一个星系时，聊天日志与游戏日志都没有线索，靠它在重启后恢复位置。
// - diagnostics（v1.1 设计 3.3、6.3 节）：待报告的崩溃 pendingCrash 与用户选过「不报告」的会话编号（最多 20 个）。
// - updates：自动更新的记录（state_updates.rs），替换 exe 后等待确认的记录与最近一次安装的结果。
//
// 读取的规则与 macOS 相同：文件不存在、不是合法 JSON、顶层不是对象或 stateVersion 不是 1 时用默认状态，不报错、
// 不隔离文件，下一次写入覆盖它；chat 或手动位置表的结构不符时只丢掉这一部分。
// 不认识的键原样保留（以后的版本加的更新、诊断记录），写回时不丢。键按字母排序，原子写入。
// 文件里有角色名，只留在本机，不进问题报告。

//! `state.json` 的读写。

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use eveo_core::chat_log::tracker::CharacterLocation;
use eveo_core::support::time::{iso8601_seconds, parse_iso8601};
use serde_json::{Map, Value};

pub use crate::state_updates::UpdateState;

/// 当前的状态文件版本。
pub const STATE_VERSION: i64 = 1;

/// 顶层的版本键。
const VERSION_KEY: &str = "stateVersion";
/// 预警与翻译的记录所在的键。
const CHAT_KEY: &str = "chat";
/// chat 里手动位置表的键。
const MANUAL_KEY: &str = "manualLocations";
/// 诊断记录所在的键。
const DIAGNOSTICS_KEY: &str = "diagnostics";
/// 更新记录所在的键，与 macOS 相同。
const UPDATES_KEY: &str = "updates";
/// 最多记住几个「不报告」的会话编号。
pub const MAX_DISMISSED_SESSIONS: usize = 20;

/// 待报告的崩溃：上一次运行崩溃了，用户还没有生成报告或选「不报告」。
#[derive(Debug, Clone, PartialEq)]
pub struct PendingCrash {
    /// 崩溃的那次运行的会话编号。
    pub session_id: String,
    /// 那次运行的应用版本。
    pub app_version: String,
    /// 那次运行开始的时刻。
    pub started_at: f64,
    /// 发现崩溃的时刻。
    pub detected_at: f64,
    /// 找到的 WER 报告目录名（不含路径）。
    pub report_file_names: Vec<String>,
}

impl PendingCrash {
    /// 从 JSON 解出；缺字段或类型不符时为 None（与 macOS 的 Codable 相同，整条丢掉）。
    fn decode(value: &Value) -> Option<Self> {
        let text = |key: &str| value.get(key).and_then(Value::as_str);
        Some(Self {
            session_id: text("sessionID")?.to_owned(),
            app_version: text("appVersion")?.to_owned(),
            started_at: parse_iso8601(text("startedAt")?)?,
            detected_at: parse_iso8601(text("detectedAt")?)?,
            report_file_names: value
                .get("reportFileNames")?
                .as_array()?
                .iter()
                .map(|v| v.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()?,
        })
    }

    /// 编码成 JSON，键名与 macOS 相同。
    fn encode(&self) -> Value {
        serde_json::json!({
            "appVersion": self.app_version,
            "detectedAt": iso8601_seconds(self.detected_at),
            "reportFileNames": self.report_file_names,
            "sessionID": self.session_id,
            "startedAt": iso8601_seconds(self.started_at),
        })
    }
}

/// state.json 里的诊断记录。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DiagnosticsState {
    /// 待报告的崩溃。
    pub pending_crash: Option<PendingCrash>,
    /// 用户选过「不报告」的会话编号，旧的在前，最多 20 个。
    pub dismissed_session_ids: Vec<String>,
    /// diagnostics 里不认识的键，写回时原样保留。
    other: Map<String, Value>,
}

impl DiagnosticsState {
    /// 记下一个「不报告」的会话编号；超过上限时丢掉最早的。
    pub fn dismiss(&mut self, session_id: &str) {
        if !self.dismissed_session_ids.iter().any(|id| id == session_id) {
            self.dismissed_session_ids.push(session_id.to_owned());
        }
        let excess = self
            .dismissed_session_ids
            .len()
            .saturating_sub(MAX_DISMISSED_SESSIONS);
        self.dismissed_session_ids.drain(..excess);
    }

    /// 从 JSON 解出；不是对象时取默认值，各字段坏了只丢那一个。
    fn decode(value: Option<Value>) -> Self {
        let Some(Value::Object(mut map)) = value else {
            return Self::default();
        };
        let pending_crash = map.remove("pendingCrash").and_then(|v| PendingCrash::decode(&v));
        let dismissed_session_ids = map
            .remove("dismissedSessionIDs")
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default();
        Self {
            pending_crash,
            dismissed_session_ids,
            other: map,
        }
    }

    /// 编码成 JSON；没有待报告的崩溃时不写 pendingCrash 这个键。
    fn encode(&self) -> Value {
        let mut map = self.other.clone();
        map.insert(
            "dismissedSessionIDs".to_owned(),
            Value::from(self.dismissed_session_ids.clone()),
        );
        if let Some(crash) = &self.pending_crash {
            map.insert("pendingCrash".to_owned(), crash.encode());
        }
        Value::Object(map)
    }
}

/// state.json 的内容。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AppState {
    /// 手动设置的位置：角色名 → 位置。
    pub manual_locations: BTreeMap<String, CharacterLocation>,
    /// 诊断记录。
    pub diagnostics: DiagnosticsState,
    /// 更新记录。
    pub updates: UpdateState,
    /// 顶层不认识的键（更新、诊断等），写回时原样保留。
    other: Map<String, Value>,
    /// chat 里不认识的键，同样原样保留。
    chat_other: Map<String, Value>,
}

impl AppState {
    /// 从文件内容解出状态；内容不对时得到默认状态（规则见文件头）。
    pub fn decode(bytes: &[u8]) -> Self {
        let Ok(Value::Object(mut root)) = serde_json::from_slice::<Value>(bytes) else {
            return Self::default();
        };
        // 缺版本键按当前版本；版本不认识时整个文件不用。
        let version = root
            .remove(VERSION_KEY)
            .map_or(Some(STATE_VERSION), |v| v.as_i64());
        if version != Some(STATE_VERSION) {
            return Self::default();
        }
        // chat 不是对象时整段丢掉；手动位置表解不出来时取空表，不连累 chat 里别的键。
        let mut chat_other = match root.remove(CHAT_KEY) {
            Some(Value::Object(chat)) => chat,
            _ => Map::new(),
        };
        let manual_locations = chat_other
            .remove(MANUAL_KEY)
            .and_then(|value| serde_json::from_value(value).ok())
            .unwrap_or_default();
        let diagnostics = DiagnosticsState::decode(root.remove(DIAGNOSTICS_KEY));
        let updates = UpdateState::decode(root.remove(UPDATES_KEY));
        Self {
            manual_locations,
            diagnostics,
            updates,
            other: root,
            chat_other,
        }
    }

    /// 编码成文件内容：缩进两格、键按字母排序（serde_json 的 Map 本身有序），末尾换行。
    pub fn encode(&self) -> Vec<u8> {
        let mut chat = self.chat_other.clone();
        // CharacterLocation 只有数字与枚举，序列化不会失败；万一失败就写空表。
        let manual =
            serde_json::to_value(&self.manual_locations).unwrap_or_else(|_| Value::Object(Map::new()));
        chat.insert(MANUAL_KEY.to_owned(), manual);
        let mut root = self.other.clone();
        root.insert(CHAT_KEY.to_owned(), Value::Object(chat));
        root.insert(DIAGNOSTICS_KEY.to_owned(), self.diagnostics.encode());
        root.insert(UPDATES_KEY.to_owned(), self.updates.encode());
        root.insert(VERSION_KEY.to_owned(), Value::from(STATE_VERSION));
        let mut bytes = serde_json::to_vec_pretty(&Value::Object(root)).unwrap_or_default();
        bytes.push(b'\n');
        bytes
    }
}

/// state.json 的持有者：记着读入的状态，改动后整份写回（保留不认识的键）。
#[derive(Debug, Clone)]
pub struct StateStore {
    /// 文件的位置。
    path: PathBuf,
    /// 当前的状态。
    state: AppState,
}

impl StateStore {
    /// 读入文件建持有者；文件不存在或内容不对时从默认状态开始。
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let state = fs::read(&path)
            .map(|bytes| AppState::decode(&bytes))
            .unwrap_or_default();
        Self { path, state }
    }

    /// 文件的位置。
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 当前的状态。
    pub fn state(&self) -> &AppState {
        &self.state
    }

    /// 换上新的手动位置表并写盘；与现有的相同时不写。写盘失败时内存里的状态已经更新，下次改动再写。
    pub fn set_manual_locations(&mut self, manual: BTreeMap<String, CharacterLocation>) -> io::Result<()> {
        if self.state.manual_locations == manual {
            return Ok(());
        }
        self.state.manual_locations = manual;
        self.save()
    }

    /// 改诊断记录并写盘；改完与原来相同时不写。
    pub fn update_diagnostics(&mut self, change: impl FnOnce(&mut DiagnosticsState)) -> io::Result<()> {
        let mut diagnostics = self.state.diagnostics.clone();
        change(&mut diagnostics);
        if diagnostics == self.state.diagnostics {
            return Ok(());
        }
        self.state.diagnostics = diagnostics;
        self.save()
    }

    /// 改更新记录并写盘；改完与原来相同时不写。
    pub fn update_updates(&mut self, change: impl FnOnce(&mut UpdateState)) -> io::Result<()> {
        let mut updates = self.state.updates.clone();
        change(&mut updates);
        if updates == self.state.updates {
            return Ok(());
        }
        self.state.updates = updates;
        self.save()
    }

    /// 整份写盘（原子写入）。
    pub fn save(&self) -> io::Result<()> {
        crate::atomic_file::write_atomic(&self.path, &self.state.encode(), "state")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use eveo_core::chat_log::tracker::LocationSource;

    /// 一条手动位置。
    fn manual(system_id: i64) -> CharacterLocation {
        CharacterLocation {
            system_id,
            time: 1_700_000_000.5,
            source: LocationSource::Manual,
        }
    }

    /// 与 macOS 写出的文件互通：键名、来源的原始值都相同，不认识的键保留。
    #[test]
    fn decodes_macos_layout_and_keeps_unknown_keys() {
        let text = r#"{
            "appliedDefaults": ["a"],
            "chat": {"manualLocations": {"Pilot A": {"source": "manual", "systemID": 30000142, "time": 1700000000.5}},
                     "future": 1},
            "stateVersion": 1,
            "updates": {"etag": "x"}
        }"#;
        let state = AppState::decode(text.as_bytes());
        assert_eq!(state.manual_locations.get("Pilot A"), Some(&manual(30_000_142)));
        let again: Value = serde_json::from_slice(&state.encode()).unwrap();
        assert_eq!(again["updates"]["etag"], "x");
        assert_eq!(again["appliedDefaults"][0], "a");
        assert_eq!(again["chat"]["future"], 1);
        assert_eq!(
            again["chat"]["manualLocations"]["Pilot A"]["systemID"],
            30_000_142
        );
        assert_eq!(again["stateVersion"], 1);
        // 往返一致。
        assert_eq!(AppState::decode(&state.encode()), state);
    }

    /// 内容不对时用默认状态；只有手动位置表坏了时只丢这一部分。
    #[test]
    fn bad_content_falls_back() {
        for text in [
            "",
            "[]",
            "not json",
            r#"{"stateVersion": 2, "chat": {}}"#,
            r#"{"stateVersion": "1"}"#,
        ] {
            assert_eq!(AppState::decode(text.as_bytes()), AppState::default(), "{text}");
        }
        let state = AppState::decode(br#"{"chat": {"manualLocations": [1], "keep": true}, "x": 1}"#);
        assert!(state.manual_locations.is_empty());
        let again: Value = serde_json::from_slice(&state.encode()).unwrap();
        assert_eq!(again["chat"]["keep"], true);
        assert_eq!(again["x"], 1);
    }

    /// 诊断记录：与 macOS 的键名相同；「不报告」最多 20 个；pendingCrash 坏了只丢它。
    #[test]
    fn diagnostics_round_trip() {
        let text = br#"{"diagnostics": {"pendingCrash": {"appVersion": "0.9.0", "detectedAt": "2026-11-24T05:00:10Z",
            "reportFileNames": ["AppCrash_eve-o-preview.e_1"], "sessionID": "S1", "startedAt": "2026-11-24T05:00:00Z"},
            "dismissedSessionIDs": ["A"], "future": 1}, "stateVersion": 1}"#;
        let mut state = AppState::decode(text);
        let crash = state.diagnostics.pending_crash.clone().unwrap();
        assert_eq!(crash.session_id, "S1");
        assert_eq!(crash.detected_at - crash.started_at, 10.0);
        assert_eq!(AppState::decode(&state.encode()), state);
        for index in 0..25 {
            state.diagnostics.dismiss(&format!("S{index}"));
        }
        let ids = &state.diagnostics.dismissed_session_ids;
        assert_eq!(ids.len(), MAX_DISMISSED_SESSIONS);
        assert_eq!(ids.first().map(String::as_str), Some("S5"));
        let again: Value = serde_json::from_slice(&state.encode()).unwrap();
        assert_eq!(again["diagnostics"]["future"], 1);
        let broken = AppState::decode(
            br#"{"diagnostics": {"pendingCrash": {"sessionID": 1}, "dismissedSessionIDs": ["X"]}}"#,
        );
        assert_eq!(broken.diagnostics.pending_crash, None);
        assert_eq!(broken.diagnostics.dismissed_session_ids, ["X"]);
    }

    /// 持有者：没有文件时从空开始；改动后写盘，再读回相同；相同的表不写。
    #[test]
    fn store_round_trip() {
        let dir = std::env::temp_dir().join(format!("eveo-state-{}", std::process::id()));
        let path = dir.join("state.json");
        let _ = fs::remove_file(&path);
        let mut store = StateStore::load(&path);
        assert!(store.state().manual_locations.is_empty());
        let table = BTreeMap::from([("Pilot B".to_owned(), manual(30_002_187))]);
        store.set_manual_locations(table.clone()).unwrap();
        assert_eq!(StateStore::load(&path).state().manual_locations, table);
        // 相同的表不写：删掉文件后再交同一张表，文件不会重新出现。
        fs::remove_file(&path).unwrap();
        store.set_manual_locations(table).unwrap();
        assert!(!path.exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
