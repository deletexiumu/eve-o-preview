// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新清单的用例。主要用 shared/fixtures/update-manifest/ 的样例（macOS 用同一份核对）：有效的清单、两个平台各自的
// latest、中间版本的挑选，以及几份应当被拒收的变体。另有几条只在 Rust 这边才有意义的用例（没有公钥时不验签等）。

use serde_json::Value;

use super::*;
use crate::update::checksums::public_key_from_hex;
use crate::update::history::{ReleaseNotesEntry, intermediate};

/// 样例清单（签名信封的原文）。
const MANIFEST: &str = include_str!("../../../../../shared/fixtures/update-manifest/manifest.json");
/// 样例的期望值。
const CASES: &str = include_str!("../../../../../shared/fixtures/update-manifest/cases.json");

/// 解析期望值。
fn cases() -> Value {
    serde_json::from_str(CASES).expect("cases.json")
}

/// 样例的测试公钥。
fn key() -> [u8; 32] {
    public_key_from_hex(cases()["publicKey"].as_str().unwrap()).expect("公钥")
}

/// 用正式地址的规则、测试公钥打开一份清单。
fn open_production(data: &str, platform: &str) -> Result<Manifest, UpdateError> {
    open(data.as_bytes(), Some(&key()), &UpdateFeed::production(), platform)
}

/// 两个平台的 latest 都与期望值一致：版本、tag、发布页、标题，以及每个文件的大小、SHA-256 与按顺序的地址。
#[test]
fn shared_fixture_latest() {
    let cases = cases();
    for platform in ["macos", "windows"] {
        let manifest = open_production(MANIFEST, platform).expect("有效的清单");
        assert_eq!(manifest.sequence, cases["sequence"].as_u64().unwrap());
        let expected = &cases["latest"][platform];
        let latest = manifest.latest.expect("latest");
        assert_eq!(latest.version, expected["version"].as_str().unwrap());
        assert_eq!(latest.tag_name, expected["tag"].as_str().unwrap());
        assert_eq!(latest.page_url, expected["pageURL"].as_str().unwrap());
        assert_eq!(latest.title, format!("EVE-O Preview {}", latest.version));
        // 说明取 releases 里同一版本的那一项。
        assert!(latest.notes.contains(&format!("Release {}.", latest.version)));
        let files = expected["files"].as_array().unwrap();
        assert_eq!(latest.assets.len(), files.len());
        for (asset, file) in latest.assets.iter().zip(files) {
            assert_eq!(asset.name, file["name"].as_str().unwrap());
            assert_eq!(asset.size, file["size"].as_u64());
            assert_eq!(asset.sha256.as_deref(), file["sha256"].as_str());
            let urls: Vec<&str> = file["urls"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(Value::as_str)
                .collect();
            assert_eq!(asset.urls().collect::<Vec<_>>(), urls);
        }
    }
}

/// 中间版本：平台含本平台、且 running < v < latest，新版在前。
#[test]
fn shared_fixture_intermediate() {
    for case in cases()["intermediate"].as_array().unwrap() {
        let platform = case["platform"].as_str().unwrap();
        let manifest = open_production(MANIFEST, platform).unwrap();
        let list = manifest.release_list(platform);
        let latest = SemanticVersion::parse(&list.releases[0].version).unwrap();
        let running = SemanticVersion::parse(case["running"].as_str().unwrap()).unwrap();
        let entries: Vec<ReleaseNotesEntry> = list
            .releases
            .iter()
            .map(|release| ReleaseNotesEntry {
                version: release.version.clone(),
                notes: release.notes.clone(),
            })
            .collect();
        let picked: Vec<String> = intermediate(&entries, &running, &latest)
            .into_iter()
            .map(|entry| entry.version)
            .collect();
        let expected: Vec<&str> = case["versions"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert_eq!(picked, expected, "{case}");
    }
}

/// 应当被拒收的变体：正文被改、别的私钥、没有前缀、格式与 schema 不对、缺 SHA-256、不是 JSON。
#[test]
fn shared_fixture_invalid() {
    for case in cases()["invalid"].as_array().unwrap() {
        let envelope = case["envelope"].as_str().unwrap();
        assert!(
            open_production(envelope, OWN_PLATFORM).is_err(),
            "{}",
            case["name"]
        );
    }
}

/// 签名不对时报 `SignatureInvalid`，界面据此说明「更新不可信」。
#[test]
fn bad_signature_error() {
    let tampered = cases()["invalid"][0]["envelope"].as_str().unwrap().to_owned();
    assert_eq!(
        open_production(&tampered, OWN_PLATFORM),
        Err(UpdateError::SignatureInvalid)
    );
}

/// 没有公钥（本机构建）时不验签：被改过的正文也能解析，但这种构建只能提示、不能安装。
#[test]
fn no_key_skips_verification() {
    let tampered = cases()["invalid"][0]["envelope"].as_str().unwrap().to_owned();
    let manifest = open(tampered.as_bytes(), None, &UpdateFeed::production(), OWN_PLATFORM).unwrap();
    assert_eq!(manifest.sequence, cases()["sequence"].as_u64().unwrap() + 1);
}

/// 清单里没有这个平台：latest 为空，发布列表也为空（不提示）。
#[test]
fn unknown_platform_has_no_latest() {
    let manifest = open_production(MANIFEST, "linux").unwrap();
    assert_eq!(manifest.latest, None);
    assert!(manifest.release_list("linux").releases.is_empty());
}

/// 测试地址下附件要与清单同源：样例里的正式地址全被丢掉，整份清单不收。
#[test]
fn test_feed_rejects_foreign_assets() {
    let feed = UpdateFeed::resolve(Some("http://127.0.0.1:8123/update-manifest.json"));
    assert!(open(MANIFEST.as_bytes(), Some(&key()), &feed, OWN_PLATFORM).is_err());
}

/// 超过 1 MiB 的文件不解析。
#[test]
fn oversized_manifest() {
    let big = vec![b' '; MAX_MANIFEST_BYTES + 1];
    assert!(matches!(
        open(&big, Some(&key()), &UpdateFeed::production(), OWN_PLATFORM),
        Err(UpdateError::MalformedFeed(_))
    ));
}
