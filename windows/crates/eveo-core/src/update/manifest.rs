// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新清单的验签与解析（docs/update-manifest.md 第 2、4 节）。macOS 的 UpdateManifest.swift 按同样的规则实现，
// 两端用 shared/fixtures/update-manifest/ 的样例核对。
//
// 清单是一个签名信封：`{"format": 1, "payload": "<正文的 base64>", "signature": "<ed25519 签名的 base64>"}`。
// 签名的消息是 `SIGNING_PREFIX` 接上正文的原始字节。先验签再解析正文，验不过的正文一个字段都不看。
//
// 正文里与本平台有关的部分：
// - `latest.<平台>`：改动了本平台的最新正式版，转成 ReleaseInfo。版本号要能解析；发布页要通过 `feed.accepts`（GitHub
//   的发布页规则）；每个文件都要有正数的 `size` 与 64 位十六进制的 `sha256`，地址只留通过 `feed.accepts_asset` 的，
//   一个都不剩时整份清单不收（文件下不来，提示了也装不上）。第一个地址作下载地址，其余作后备。
// - `releases`：各版本的平台与说明。缺字段或类型不对的项跳过，不影响整份清单。
// 不认识的字段一律忽略：以后加字段不用改 schema（第 2.3 节）。
//
// 公钥为 None 时（本机构建没有编进公钥）不验签：这种构建只能提示、不能安装（policy::capability），
// 提示里的发布页仍要通过 GitHub 的规则，所以不验签也只影响「有没有新版本」的判断。

//! 更新清单的验签与解析。

use ed25519_dalek::{Signature, VerifyingKey};
use serde_json::{Map, Value};

use super::checksums::base64_decode;
use super::feed::UpdateFeed;
use super::models::{ReleaseAsset, ReleaseInfo, UpdateError};
use super::parser::{MAX_NOTES_CHARACTERS, ReleaseList, truncate_chars};
use super::version::SemanticVersion;

/// 清单的文件名。
pub const MANIFEST_NAME: &str = "update-manifest.json";
/// 清单文件的上限：1 MiB。发布流程把它控制在 512 KiB 以内，这里留一倍余量。
pub const MAX_MANIFEST_BYTES: usize = 1_048_576;
/// 签名的消息的前缀，与 scripts/build_update_manifest.py 相同。
pub const SIGNING_PREFIX: &[u8] = b"eveo-update-manifest-v1\n";
/// 信封的格式号与正文的 schema；别的值都不收。
const FORMAT: u64 = 1;
/// 正文的 schema。
const SCHEMA: u64 = 1;
/// 本平台在清单里的键。
pub const OWN_PLATFORM: &str = "windows";
/// SHA-256 的十六进制长度。
const SHA256_HEX_LENGTH: usize = 64;

/// 清单里的一个版本：版本号、改动了哪些平台、发布说明的原文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestEntry {
    /// 规范写法的版本号，如 `1.4.1`。
    pub version: String,
    /// 改动了的平台，如 `["windows"]`。
    pub platforms: Vec<String>,
    /// 发布说明原文，最多 65,536 个字符。
    pub notes: String,
}

/// 验过签、解析好的清单（只含一个平台需要的部分）。
#[derive(Debug, Clone, PartialEq)]
pub struct Manifest {
    /// 清单的序号；应用记下接受过的最大值，拒收更小的（防止旧清单被重放）。
    pub sequence: u64,
    /// 改动了这个平台的最新正式版；清单里没有这个平台时是 None。
    pub latest: Option<ReleaseInfo>,
    /// 各版本，保持清单里的顺序（新版在前）。
    pub entries: Vec<ManifestEntry>,
}

impl Manifest {
    /// 转成状态机用的发布列表：最新版（带附件）在前，之后是改动了这个平台、比最新版旧的各版本（只有说明，
    /// 给中间版本的说明用）。没有最新版时列表为空。列表总是完整的（`is_full` 为假）。
    pub fn release_list(&self, platform: &str) -> ReleaseList {
        let Some(latest) = &self.latest else {
            return ReleaseList {
                releases: Vec::new(),
                is_full: false,
            };
        };
        let mut releases = vec![latest.clone()];
        let target = SemanticVersion::parse(&latest.version);
        for entry in &self.entries {
            let older = SemanticVersion::parse(&entry.version)
                .zip(target.as_ref())
                .is_some_and(|(version, target)| &version < target);
            if older && entry.platforms.iter().any(|name| name == platform) {
                releases.push(ReleaseInfo {
                    version: entry.version.clone(),
                    tag_name: format!("v{}", entry.version),
                    title: String::new(),
                    notes: entry.notes.clone(),
                    page_url: String::new(),
                    published_at: None,
                    is_prerelease: false,
                    is_draft: false,
                    assets: Vec::new(),
                });
            }
        }
        ReleaseList {
            releases,
            is_full: false,
        }
    }
}

/// 建一个 `MalformedFeed`。
fn malformed(reason: &str) -> UpdateError {
    UpdateError::MalformedFeed(reason.to_owned())
}

/// 验签并解析一份清单，取出 platform 的部分。public_key 为 None 时不验签（见文件开头）。
pub fn open(
    data: &[u8],
    public_key: Option<&[u8; 32]>,
    feed: &UpdateFeed,
    platform: &str,
) -> Result<Manifest, UpdateError> {
    if data.len() > MAX_MANIFEST_BYTES {
        return Err(malformed("manifest larger than 1 MiB"));
    }
    let envelope: Value = serde_json::from_slice(data).map_err(|_| malformed("manifest is not JSON"))?;
    if envelope.get("format").and_then(Value::as_u64) != Some(FORMAT) {
        return Err(malformed("unsupported manifest format"));
    }
    let field = |name: &str| envelope.get(name).and_then(Value::as_str).and_then(base64_decode);
    let payload = field("payload").ok_or_else(|| malformed("manifest payload is not base64"))?;
    let signature = field("signature").ok_or(UpdateError::SignatureInvalid)?;
    if let Some(key) = public_key {
        verify(&payload, &signature, key)?;
    }
    let root: Value =
        serde_json::from_slice(&payload).map_err(|_| malformed("manifest payload is not JSON"))?;
    parse_payload(&root, feed, platform)
}

/// 核对正文的签名：消息是前缀接上正文。签名长度不对、公钥无效或签名不符都是 `SignatureInvalid`。
fn verify(payload: &[u8], signature: &[u8], key: &[u8; 32]) -> Result<(), UpdateError> {
    let bytes: [u8; 64] = signature.try_into().map_err(|_| UpdateError::SignatureInvalid)?;
    let key = VerifyingKey::from_bytes(key).map_err(|_| UpdateError::SignatureInvalid)?;
    let mut message = Vec::with_capacity(SIGNING_PREFIX.len() + payload.len());
    message.extend_from_slice(SIGNING_PREFIX);
    message.extend_from_slice(payload);
    // 严格验签：拒收小阶点之类的边缘签名，与 macOS 的 CryptoKit 用同一组样例核对。
    key.verify_strict(&message, &Signature::from_bytes(&bytes))
        .map_err(|_| UpdateError::SignatureInvalid)
}

/// 解析验过签的正文。
fn parse_payload(root: &Value, feed: &UpdateFeed, platform: &str) -> Result<Manifest, UpdateError> {
    let root = root
        .as_object()
        .ok_or_else(|| malformed("manifest payload is not an object"))?;
    if root.get("schema").and_then(Value::as_u64) != Some(SCHEMA) {
        return Err(malformed("unsupported manifest schema"));
    }
    let sequence = root
        .get("sequence")
        .and_then(Value::as_u64)
        .ok_or_else(|| malformed("manifest sequence missing"))?;
    let entries: Vec<ManifestEntry> = root
        .get("releases")
        .and_then(Value::as_array)
        .ok_or_else(|| malformed("manifest releases missing"))?
        .iter()
        .filter_map(entry)
        .collect();
    let latest = match root
        .get("latest")
        .and_then(Value::as_object)
        .ok_or_else(|| malformed("manifest latest missing"))?
        .get(platform)
    {
        Some(value) => Some(latest(value, &entries, feed)?),
        None => None,
    };
    Ok(Manifest {
        sequence,
        latest,
        entries,
    })
}

/// releases 里的一项；缺字段或类型不对、版本号解析不了时返回 None。
fn entry(value: &Value) -> Option<ManifestEntry> {
    let version = SemanticVersion::parse(value.get("version")?.as_str()?)?;
    let platforms = value
        .get("platforms")?
        .as_array()?
        .iter()
        .map(|name| name.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()?;
    let notes = value.get("notes")?.as_str()?;
    Some(ManifestEntry {
        version: version.to_string(),
        platforms,
        notes: truncate_chars(notes, MAX_NOTES_CHARACTERS),
    })
}

/// `latest.<平台>` 转成发布信息。不合规则时整份清单不收：这一项是要安装的版本，不能带着坏数据往下走。
fn latest(value: &Value, entries: &[ManifestEntry], feed: &UpdateFeed) -> Result<ReleaseInfo, UpdateError> {
    let object = value
        .as_object()
        .ok_or_else(|| malformed("latest is not an object"))?;
    let text = |key: &str| object.get(key).and_then(Value::as_str);
    let version = text("version")
        .and_then(SemanticVersion::parse)
        .ok_or_else(|| malformed("latest version is not a version"))?;
    let tag = text("tag").ok_or_else(|| malformed("latest tag missing"))?;
    let page_url = text("pageURL")
        .filter(|url| feed.accepts(url))
        .ok_or_else(|| malformed("latest pageURL not accepted"))?;
    let assets = object
        .get("files")
        .and_then(Value::as_array)
        .ok_or_else(|| malformed("latest files missing"))?
        .iter()
        .map(|file| asset(file, feed))
        .collect::<Result<Vec<_>, _>>()?;
    // 说明取 releases 里同一版本的那一项；没有时为空（窗口只显示标题）。
    let notes = entries
        .iter()
        .find(|entry| SemanticVersion::parse(&entry.version).as_ref() == Some(&version))
        .map(|entry| entry.notes.clone())
        .unwrap_or_default();
    Ok(ReleaseInfo {
        version: version.to_string(),
        tag_name: tag.to_owned(),
        title: format!("EVE-O Preview {version}"),
        notes,
        page_url: page_url.to_owned(),
        published_at: None,
        is_prerelease: false,
        is_draft: false,
        assets,
    })
}

/// files 里的一个文件。名字、正数的大小与 SHA-256 都必须有；地址只留通过 `accepts_asset` 的，至少要剩一个。
fn asset(value: &Value, feed: &UpdateFeed) -> Result<ReleaseAsset, UpdateError> {
    let object: &Map<String, Value> = value
        .as_object()
        .ok_or_else(|| malformed("file is not an object"))?;
    let name = object
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty() && !name.contains(['/', '\\']))
        .ok_or_else(|| malformed("file name missing"))?;
    let size = object
        .get("size")
        .and_then(Value::as_u64)
        .filter(|&size| size > 0)
        .ok_or_else(|| malformed("file size missing"))?;
    let sha256 = object
        .get("sha256")
        .and_then(Value::as_str)
        .filter(|hash| hash.len() == SHA256_HEX_LENGTH && hash.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or_else(|| malformed("file sha256 missing"))?
        .to_ascii_lowercase();
    let mut urls = object
        .get("urls")
        .and_then(Value::as_array)
        .ok_or_else(|| malformed("file urls missing"))?
        .iter()
        .filter_map(Value::as_str)
        .filter(|url| feed.accepts_asset(url))
        .map(str::to_owned);
    let download_url = urls.next().ok_or_else(|| malformed("file has no usable url"))?;
    Ok(ReleaseAsset {
        name: name.to_owned(),
        download_url,
        size: Some(size),
        sha256: Some(sha256),
        mirrors: urls.collect(),
    })
}

#[cfg(test)]
#[path = "manifest_tests.rs"]
mod tests;
