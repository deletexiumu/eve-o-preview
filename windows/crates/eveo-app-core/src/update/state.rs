// SPDX-License-Identifier: GPL-3.0-or-later
//
// state.json 里的更新记录（键 `updates`），对应 macOS 的 `UpdateState`（v1.1 设计 8.4、8.5、9.3 节）。
// 键名与 macOS 相同的字段含义也相同：lastCheckAt、etag、cachedRelease、rateLimitedUntil、skippedVersion、
// prepared、lastInstall、intermediateNotes。Windows 的差别：
// - `prepared` 记的是下载、核对、解出后的新 exe（放在 %LOCALAPPDATA%\EVE-O Preview\updates 下），
//   带它的 SHA-256：安装前再算一次，文件被改动或损坏时不装。macOS 记的是 dmg。
// - `pendingSwap` 是 Windows 独有的：便携 exe 替换后等待新版确认（规则在 eveo_core::update::install）。
// - etag 对应的是 Release 列表（Windows 不用 /releases/latest），cachedRelease 是列表里挑出的最新版。
// 某个字段的结构不对时只丢这一个字段，不连累别的记录：例如缓存的发布信息坏了，下一次检查重新取，
// 「跳过此版本」与待确认的替换照旧。不认识的键原样保留，写回时不丢。

//! state.json 的更新记录。

use eveo_core::support::time::{iso8601_seconds, parse_iso8601};
use eveo_core::update::history::{IntermediateReleaseNotes, ReleaseNotesEntry};
use eveo_core::update::install::{InstallRecord, PendingSwap};
use eveo_core::update::models::{ReleaseAsset, ReleaseInfo};
use serde_json::{Map, Value};

/// 已下载、核对过、等待安装的新 exe。
///
/// 下载的 zip、校验和与签名只在内存里核对，核对通过后只把解出的 exe 写进缓存目录；
/// 安装时读回这个文件、核对 SHA-256，再交给平台层的 replace_exe。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedUpdate {
    /// 新 exe 的版本。
    pub version: String,
    /// 新 exe 的完整路径（在更新缓存目录里）。
    pub exe_path: String,
    /// 新 exe 的 SHA-256（小写十六进制）。
    pub sha256: String,
}

/// 更新记录。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UpdateState {
    /// 最近一次得到服务器答复的时刻。
    pub last_check_at: Option<f64>,
    /// 上次答复的 ETag；有缓存的发布信息时随请求发出。
    /// GitHub 对带 If-None-Match 且答复 304 的请求不计入未登录的限额（每小时 60 次），所以每次都带上。
    pub etag: Option<String>,
    /// 上次挑出的最新版；304 时用它继续判断。
    /// 304 之后正在运行的版本可能已经变了（刚更新过），所以每次都按缓存重新判断要不要提示。
    pub cached_release: Option<ReleaseInfo>,
    /// 被限流时可以再试的时刻。在这之前自动检查不发请求，用户点检查时直接显示限流的说明。
    pub rate_limited_until: Option<f64>,
    /// 用户选了「跳过此版本」的版本号。
    pub skipped_version: Option<String>,
    /// 已下载并核对过、等待安装的新 exe。
    pub prepared: Option<PreparedUpdate>,
    /// 待确认的替换。
    pub pending_swap: Option<PendingSwap>,
    /// 最近一次安装的结果。
    pub last_install: Option<InstallRecord>,
    /// cached_release 与正在运行的版本之间各版本的说明。
    /// 更新窗口在最新版的说明之后列出它们；最多 10 个、总共约 256 KB，更早的请看发布页。
    pub intermediate_notes: Option<IntermediateReleaseNotes>,
    /// 接受过的更新清单的最大序号（docs/update-manifest.md 第 4 节第 2 条）。序号更小的清单当作这个源失败，
    /// 防止旧清单被重放、把新版本藏起来。只在正式地址下读写。
    pub manifest_sequence: Option<u64>,
    /// updates 里不认识的键，写回时原样保留。
    other: Map<String, Value>,
}

impl UpdateState {
    /// 从 JSON 解出；不是对象时取默认值。
    pub(crate) fn decode(value: Option<Value>) -> Self {
        let Some(Value::Object(mut map)) = value else {
            return Self::default();
        };
        // 每个字段单独取出、单独解：解不出的只是这一个字段为 None。
        let mut take = |key: &str| map.remove(key);
        let last_check_at = take("lastCheckAt").as_ref().and_then(time);
        let etag = take("etag").as_ref().and_then(text_value);
        let cached_release = take("cachedRelease").as_ref().and_then(decode_release);
        let rate_limited_until = take("rateLimitedUntil").as_ref().and_then(time);
        let skipped_version = take("skippedVersion").as_ref().and_then(text_value);
        let prepared = take("prepared").as_ref().and_then(decode_prepared);
        let pending_swap = take("pendingSwap").as_ref().and_then(decode_swap);
        let last_install = take("lastInstall").as_ref().and_then(decode_install);
        let intermediate_notes = take("intermediateNotes").as_ref().and_then(decode_notes);
        let manifest_sequence = take("manifestSequence").as_ref().and_then(Value::as_u64);
        Self {
            last_check_at,
            etag,
            cached_release,
            rate_limited_until,
            skipped_version,
            prepared,
            pending_swap,
            last_install,
            intermediate_notes,
            manifest_sequence,
            other: map,
        }
    }

    /// 编码成 JSON；为空的字段不写键（与 macOS 的 Codable 对 nil 的处理相同）。
    pub(crate) fn encode(&self) -> Value {
        let mut map = self.other.clone();
        // 先写可选字段：值为 None 时跳过，不在文件里留 null。
        let mut put = |key: &str, value: Option<Value>| {
            if let Some(value) = value {
                map.insert(key.to_owned(), value);
            }
        };
        put(
            "lastCheckAt",
            self.last_check_at.map(|t| Value::from(iso8601_seconds(t))),
        );
        put("etag", self.etag.clone().map(Value::from));
        put("cachedRelease", self.cached_release.as_ref().map(encode_release));
        put(
            "rateLimitedUntil",
            self.rate_limited_until.map(|t| Value::from(iso8601_seconds(t))),
        );
        put("skippedVersion", self.skipped_version.clone().map(Value::from));
        put("prepared", self.prepared.as_ref().map(encode_prepared));
        put("pendingSwap", self.pending_swap.as_ref().map(encode_swap));
        put("lastInstall", self.last_install.as_ref().map(encode_install));
        put(
            "intermediateNotes",
            self.intermediate_notes.as_ref().map(encode_notes),
        );
        put("manifestSequence", self.manifest_sequence.map(Value::from));
        Value::Object(map)
    }
}

/// 取一个字符串值。
fn text_value(value: &Value) -> Option<String> {
    value.as_str().map(str::to_owned)
}

/// 取一个 ISO 8601 时刻。
fn time(value: &Value) -> Option<f64> {
    parse_iso8601(value.as_str()?)
}

/// 取对象里的一个字符串字段。
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// 建一个对象：只放有值的字段。键名按字母排序由 serde_json 的 Map 保证。
fn object(fields: Vec<(&str, Option<Value>)>) -> Value {
    Value::Object(
        fields
            .into_iter()
            .filter_map(|(key, value)| value.map(|value| (key.to_owned(), value)))
            .collect(),
    )
}

/// 解出发布信息；必需的字段缺了或类型不对时为 None。附件里坏掉的项跳过。
fn decode_release(value: &Value) -> Option<ReleaseInfo> {
    let assets = value
        .get("assets")?
        .as_array()?
        .iter()
        .filter_map(|asset| {
            Some(ReleaseAsset {
                name: text(asset, "name")?.to_owned(),
                download_url: text(asset, "downloadURL")?.to_owned(),
                size: asset.get("size").and_then(Value::as_u64),
                // 1.5.0 起清单里的附件带 SHA-256 与后备地址；更早写下的记录没有这两个键。
                sha256: text(asset, "sha256").map(str::to_owned),
                mirrors: asset
                    .get("mirrors")
                    .and_then(Value::as_array)
                    .map(|urls| urls.iter().filter_map(text_value).collect())
                    .unwrap_or_default(),
            })
        })
        .collect();
    Some(ReleaseInfo {
        version: text(value, "version")?.to_owned(),
        tag_name: text(value, "tagName")?.to_owned(),
        title: text(value, "title")?.to_owned(),
        notes: text(value, "notes")?.to_owned(),
        page_url: text(value, "pageURL")?.to_owned(),
        published_at: value.get("publishedAt").and_then(time),
        is_prerelease: value.get("isPrerelease")?.as_bool()?,
        is_draft: value.get("isDraft")?.as_bool()?,
        assets,
    })
}

/// 编码发布信息，键名与 macOS 的 ReleaseInfo 相同。
fn encode_release(release: &ReleaseInfo) -> Value {
    let assets: Vec<Value> = release
        .assets
        .iter()
        .map(|asset| {
            object(vec![
                ("downloadURL", Some(Value::from(asset.download_url.clone()))),
                (
                    "mirrors",
                    (!asset.mirrors.is_empty()).then(|| Value::from(asset.mirrors.clone())),
                ),
                ("name", Some(Value::from(asset.name.clone()))),
                ("sha256", asset.sha256.clone().map(Value::from)),
                ("size", asset.size.map(Value::from)),
            ])
        })
        .collect();
    object(vec![
        ("assets", Some(Value::from(assets))),
        ("isDraft", Some(Value::from(release.is_draft))),
        ("isPrerelease", Some(Value::from(release.is_prerelease))),
        ("notes", Some(Value::from(release.notes.clone()))),
        ("pageURL", Some(Value::from(release.page_url.clone()))),
        (
            "publishedAt",
            release.published_at.map(|t| Value::from(iso8601_seconds(t))),
        ),
        ("tagName", Some(Value::from(release.tag_name.clone()))),
        ("title", Some(Value::from(release.title.clone()))),
        ("version", Some(Value::from(release.version.clone()))),
    ])
}

/// 解出待安装的新 exe。
fn decode_prepared(value: &Value) -> Option<PreparedUpdate> {
    Some(PreparedUpdate {
        version: text(value, "version")?.to_owned(),
        exe_path: text(value, "exePath")?.to_owned(),
        sha256: text(value, "sha256")?.to_owned(),
    })
}

/// 编码待安装的新 exe。
fn encode_prepared(prepared: &PreparedUpdate) -> Value {
    object(vec![
        ("exePath", Some(Value::from(prepared.exe_path.clone()))),
        ("sha256", Some(Value::from(prepared.sha256.clone()))),
        ("version", Some(Value::from(prepared.version.clone()))),
    ])
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
            Some(other) => Some(time(other)?),
        },
    })
}

/// 编码待确认的替换。时刻精确到秒，与 state.json 里别的时刻相同。
fn encode_swap(swap: &PendingSwap) -> Value {
    object(vec![
        ("at", Some(Value::from(iso8601_seconds(swap.at)))),
        ("fromVersion", Some(Value::from(swap.from_version.clone()))),
        (
            "launchedAt",
            swap.launched_at.map(|t| Value::from(iso8601_seconds(t))),
        ),
        ("version", Some(Value::from(swap.version.clone()))),
    ])
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
    object(vec![
        ("at", Some(Value::from(iso8601_seconds(record.at)))),
        ("errorCode", record.error_code.clone().map(Value::from)),
        ("fromVersion", Some(Value::from(record.from_version.clone()))),
        ("succeeded", Some(Value::from(record.succeeded))),
        ("version", Some(Value::from(record.version.clone()))),
    ])
}

/// 解出中间版本的说明，键名与 macOS 相同。坏掉的条目跳过。
fn decode_notes(value: &Value) -> Option<IntermediateReleaseNotes> {
    let entries = value
        .get("entries")?
        .as_array()?
        .iter()
        .filter_map(|entry| {
            Some(ReleaseNotesEntry {
                version: text(entry, "version")?.to_owned(),
                notes: text(entry, "notes")?.to_owned(),
            })
        })
        .collect();
    Some(IntermediateReleaseNotes {
        latest_version: text(value, "latestVersion")?.to_owned(),
        running_version: text(value, "runningVersion")?.to_owned(),
        entries,
        has_more: value.get("hasMore")?.as_bool()?,
    })
}

/// 编码中间版本的说明。
fn encode_notes(notes: &IntermediateReleaseNotes) -> Value {
    let entries: Vec<Value> = notes
        .entries
        .iter()
        .map(|entry| {
            object(vec![
                ("notes", Some(Value::from(entry.notes.clone()))),
                ("version", Some(Value::from(entry.version.clone()))),
            ])
        })
        .collect();
    object(vec![
        ("entries", Some(Value::from(entries))),
        ("hasMore", Some(Value::from(notes.has_more))),
        ("latestVersion", Some(Value::from(notes.latest_version.clone()))),
        ("runningVersion", Some(Value::from(notes.running_version.clone()))),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 一个完整的发布信息。
    fn release() -> ReleaseInfo {
        ReleaseInfo {
            version: "0.9.1".into(),
            tag_name: "win-v0.9.1".into(),
            title: "EVE-O Preview for Windows 0.9.1".into(),
            notes: "<!-- lang:en -->\nFixes.\n<!-- /lang:en -->".into(),
            page_url: "https://github.com/deletexiumu/eve-o-preview/releases/tag/win-v0.9.1".into(),
            published_at: Some(1_800_000_000.0),
            is_prerelease: false,
            is_draft: false,
            assets: vec![ReleaseAsset {
                name: "SHA256SUMS.txt".into(),
                download_url:
                    "https://github.com/deletexiumu/eve-o-preview/releases/download/win-v0.9.1/SHA256SUMS.txt"
                        .into(),
                size: Some(299),
                sha256: Some("ab".repeat(32)),
                mirrors: vec!["https://dl.example.com/v0.9.1/SHA256SUMS.txt".into()],
            }],
        }
    }

    /// 全部字段往返一致；不认识的键保留；为空的字段不写键。
    #[test]
    fn round_trip() {
        let state = UpdateState {
            last_check_at: Some(1_800_000_100.0),
            etag: Some("W/\"abc\"".into()),
            cached_release: Some(release()),
            rate_limited_until: Some(1_800_003_600.0),
            skipped_version: Some("0.9.0".into()),
            prepared: Some(PreparedUpdate {
                version: "0.9.1".into(),
                exe_path: "C:\\x\\EVE-O Preview-0.9.1.exe".into(),
                sha256: "ab".repeat(32),
            }),
            pending_swap: Some(PendingSwap {
                version: "0.9.1".into(),
                from_version: "0.9.0".into(),
                at: 1_800_000_200.0,
                launched_at: None,
            }),
            last_install: Some(InstallRecord {
                version: "0.9.0".into(),
                from_version: "0.8.0".into(),
                at: 1_700_000_000.0,
                succeeded: false,
                error_code: Some("launchFailed".into()),
            }),
            intermediate_notes: Some(IntermediateReleaseNotes {
                latest_version: "0.9.1".into(),
                running_version: "0.8.0".into(),
                entries: vec![ReleaseNotesEntry {
                    version: "0.9.0".into(),
                    notes: "n".into(),
                }],
                has_more: true,
            }),
            manifest_sequence: Some(1_700_000_000),
            other: Map::new(),
        };
        let encoded = state.encode();
        assert!(encoded["pendingSwap"].get("launchedAt").is_none());
        assert_eq!(encoded["cachedRelease"]["assets"][0]["size"], 299);
        assert_eq!(encoded["manifestSequence"], 1_700_000_000);
        assert_eq!(UpdateState::decode(Some(encoded)), state);
        // 全部为空时只剩不认识的键。
        let empty = UpdateState::decode(Some(json!({"future": "1.0.0"}))).encode();
        assert_eq!(empty, json!({"future": "1.0.0"}));
    }

    /// 坏字段只丢它自己；launchedAt 写坏时整条替换记录作废；坏的附件只丢那一项。
    #[test]
    fn bad_fields() {
        let state = UpdateState::decode(Some(json!({
            "pendingSwap": {"version": "0.9.2", "fromVersion": "0.9.1", "at": "2026-11-24T06:00:00Z",
                            "launchedAt": 5},
            "lastInstall": {"version": "0.9.1", "fromVersion": "0.9.0", "at": "2026-11-24T05:00:00Z",
                            "succeeded": true},
            "cachedRelease": {"version": "0.9.1"},
            "lastCheckAt": "yesterday",
            "skippedVersion": "0.9.0"
        })));
        assert_eq!(state.pending_swap, None);
        assert_eq!(state.cached_release, None);
        assert_eq!(state.last_check_at, None);
        assert!(state.last_install.unwrap().succeeded);
        assert_eq!(state.skipped_version.as_deref(), Some("0.9.0"));
        let mut value = encode_release(&release());
        value["assets"] = json!([{"name": "x"}, {"name": "y", "downloadURL": "u"}]);
        let decoded = decode_release(&value).unwrap();
        assert_eq!(decoded.assets.len(), 1);
        assert_eq!(decoded.assets[0].size, None);
        assert_eq!(UpdateState::decode(Some(json!([1]))), UpdateState::default());
        assert_eq!(UpdateState::decode(None), UpdateState::default());
    }
}
