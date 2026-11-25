// SPDX-License-Identifier: GPL-3.0-or-later
//
// Release 列表解析与限流判断的用例，移植 macOS 的 ReleaseFeedParserTests 与 ReleaseHistoryTests 的解析部分，
// 另加 Windows 的规则（认 `win-v` 与带 Windows 压缩包的 `v` 两种 tag，纯 macOS 的项跳过）。

use super::*;
use serde_json::json;

/// 正式地址。
fn feed() -> UpdateFeed {
    UpdateFeed::production()
}

/// 本仓库的 Release 地址。
fn url(path: &str) -> String {
    format!("{}{path}", feed::PRODUCTION_ASSET_PREFIX)
}

/// 列表里的一项：GitHub 答复的字段，按需覆盖或删除（值为 null 的键删除）。
fn item(tag: &str, overrides: Value) -> Value {
    let mut object = json!({
        "html_url": url(&format!("tag/{tag}")),
        "tag_name": tag,
        "name": format!("EVE-O Preview for Windows {tag}"),
        "draft": false,
        "prerelease": false,
        "published_at": "2026-11-20T16:26:38Z",
        "body": "<!-- lang:en -->\nFirst release.\n<!-- /lang:en -->",
        "assets": [
            {"name": "EVE-O-Preview-0.9.0-windows-x64.zip", "size": 4_221_880,
             "browser_download_url": url(&format!("download/{tag}/EVE-O-Preview-0.9.0-windows-x64.zip"))},
            {"name": "SHA256SUMS.txt", "size": 299, "browser_download_url": url(&format!("download/{tag}/SHA256SUMS.txt"))}
        ]
    });
    let target = object.as_object_mut().expect("对象");
    for (key, value) in overrides.as_object().expect("对象") {
        if value.is_null() {
            target.remove(key);
        } else {
            target.insert(key.clone(), value.clone());
        }
    }
    object
}

/// 把若干项编成列表答复并解析。
fn parse(items: Vec<Value>) -> Result<ReleaseList, UpdateError> {
    parse_list(Value::Array(items).to_string().as_bytes(), &feed())
}

/// GitHub 答复的样例：各字段取到；macOS 的项与草稿跳过，顺序保持。
#[test]
fn parses_windows_items() {
    // 一页里混着 macOS 版、草稿、预发布、不是对象的项和 tag 解析不了的项：
    // 只有 win-v0.9.0 与 win-v0.9.1-beta.1 留下，顺序与答复相同。
    let list = parse(vec![
        item("v1.3.1", json!({})),
        item("win-v0.9.0", json!({})),
        item("win-v0.9.1", json!({"draft": true})),
        item(
            "win-v0.9.1-beta.1",
            json!({"prerelease": true, "body": null, "name": ""}),
        ),
        json!("not an object"),
        item("win-vlatest", json!({})),
    ])
    .expect("有效");
    // 6 项不到一页，不算满页。
    assert!(!list.is_full);
    assert_eq!(list.releases.len(), 2);
    let info = &list.releases[0];
    assert_eq!(info.version, "0.9.0");
    assert_eq!(info.tag_name, "win-v0.9.0");
    assert_eq!(info.title, "EVE-O Preview for Windows win-v0.9.0");
    assert_eq!(info.page_url, url("tag/win-v0.9.0"));
    assert_eq!(info.notes, "<!-- lang:en -->\nFirst release.\n<!-- /lang:en -->");
    assert_eq!(info.published_at, parse_iso8601("2026-11-20T16:26:38Z"));
    assert!(!info.is_draft && !info.is_prerelease);
    assert_eq!(info.assets.len(), 2);
    assert_eq!(info.assets[1].size, Some(299));
    assert!(info.asset("SHA256SUMS.txt").is_some());
    // 预发布原样取出：body 为 null 时取空串，name 为空时标题取 tag。
    let beta = &list.releases[1];
    assert_eq!(beta.version, "0.9.1-beta.1");
    assert!(beta.is_prerelease);
    assert_eq!(beta.notes, "");
    assert_eq!(beta.title, "win-v0.9.1-beta.1");
}

/// 发布页地址不合格的项跳过；附件地址不合格或缺字段的附件丢掉；附件只看前 100 个。
#[test]
fn filters_urls_and_assets() {
    // 发布页在别人的仓库：整项跳过，不影响别的项。
    let foreign = item(
        "win-v0.9.0",
        json!({"html_url": "https://github.com/someone/eve-o-preview/releases/tag/x"}),
    );
    assert!(parse(vec![foreign]).unwrap().releases.is_empty());
    // 四个附件：别的主机、合格的、缺地址的、缺名字的，只留合格的那个。
    let assets = json!([
        {"name": "a.zip", "browser_download_url": "https://evil.example/a.zip", "size": 1},
        {"name": "SHA256SUMS.txt", "browser_download_url": url("download/win-v0.9.0/SHA256SUMS.txt"), "size": 2},
        {"name": "no-url.txt", "size": 3},
        {"browser_download_url": url("download/win-v0.9.0/no-name.txt")}
    ]);
    let list = parse(vec![item("win-v0.9.0", json!({ "assets": assets }))]).unwrap();
    assert_eq!(
        list.releases[0].assets,
        [ReleaseAsset {
            name: "SHA256SUMS.txt".into(),
            download_url: url("download/win-v0.9.0/SHA256SUMS.txt"),
            size: Some(2),
            sha256: None,
            mirrors: Vec::new(),
        }]
    );
    // 150 个附件只看前 100 个，最后一个是 a99。
    let many: Vec<Value> = (0..150)
        .map(|i| json!({"name": format!("a{i}"), "browser_download_url": url(&format!("download/a{i}"))}))
        .collect();
    let list = parse(vec![item("win-v0.9.0", json!({ "assets": many }))]).unwrap();
    assert_eq!(list.releases[0].assets.len(), MAX_ASSETS);
    assert_eq!(list.releases[0].assets[99].name, "a99");
}

/// 测试地址下附件应与检查地址同源。
#[test]
fn test_feed_same_origin() {
    // 127.0.0.1 与 localhost 是同一台机器，但不同源：后者的附件丢掉。
    let test = UpdateFeed::resolve(Some("http://127.0.0.1:8123/releases.json"));
    let data = json!([item(
        "win-v0.9.1",
        json!({
            "html_url": "http://127.0.0.1:8123/",
            "assets": [
                {"name": "x.zip", "browser_download_url": "http://127.0.0.1:8123/x.zip"},
                {"name": "SHA256SUMS.txt", "browser_download_url": "http://localhost:8123/SHA256SUMS.txt"}
            ]
        })
    )]);
    let list = parse_list(data.to_string().as_bytes(), &test).unwrap();
    let names: Vec<_> = list.releases[0].assets.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, ["x.zip"]);
}

/// 超长的正文截短到 65,536 个字符；满页时 `is_full` 为真；published_at 带小数秒也能解析，解析不了时是 None。
#[test]
fn notes_page_and_dates() {
    // 按字符截短，不按字节：é 是两个字节，截完仍是完整的字符。
    let long = "é".repeat(70_000);
    let list = parse(vec![item("win-v0.9.0", json!({ "body": long }))]).unwrap();
    assert_eq!(list.releases[0].notes.chars().count(), MAX_NOTES_CHARACTERS);
    // 满页按答复的项数算，被跳过的 macOS 项也算在内。
    let full: Vec<Value> = (0..super::PAGE_SIZE)
        .map(|i| item(&format!("v1.0.{i}"), json!({})))
        .collect();
    assert!(parse(full).unwrap().is_full);
    let fractional = parse(vec![item(
        "win-v0.9.0",
        json!({"published_at": "2026-11-20T16:26:38.5Z"}),
    )])
    .unwrap();
    assert!(fractional.releases[0].published_at.is_some());
    let bad = parse(vec![item("win-v0.9.0", json!({"published_at": "yesterday"}))]).unwrap();
    assert_eq!(bad.releases[0].published_at, None);
}

/// 不是 JSON、不是数组、超过 4 MiB 时返回 MalformedFeed。
#[test]
fn malformed_lists() {
    // 取出 MalformedFeed 的原因；别的结果直接让用例失败。
    let reason = |data: &[u8]| match parse_list(data, &feed()) {
        Err(UpdateError::MalformedFeed(reason)) => reason,
        other => panic!("应是 MalformedFeed：{other:?}"),
    };
    assert_eq!(reason(b"{"), "release list is not JSON");
    assert_eq!(
        reason(br#"{"tag_name":"win-v1.0.0"}"#),
        "release list is not an array"
    );
    assert_eq!(
        reason(&vec![b' '; MAX_LIST_BYTES + 1]),
        "release list larger than 4 MiB"
    );
}

/// 限流判断，与 macOS 的用例相同。
#[test]
fn rate_limits() {
    // 现在的时刻与 macOS 用例相同，便于对照。
    let now = 1_800_000_000.0;
    // 用一组（名字，值）模拟答复头，按名字查找。
    let check = |status: u16, headers: &[(&str, &str)]| {
        let headers: Vec<(String, String)> = headers
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        rate_limit(
            status,
            |name| headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str()),
            now,
        )
    };
    // 403 加额度为 0：时刻取 reset。
    assert_eq!(
        check(
            403,
            &[
                ("x-ratelimit-remaining", "0"),
                ("x-ratelimit-reset", "1800001234")
            ]
        ),
        Some(1_800_001_234.0)
    );
    // 429 加 retry-after：现在加这么多秒；两个头都有时先看 retry-after；都没有时推后 1 小时。
    assert_eq!(check(429, &[("retry-after", "120")]), Some(now + 120.0));
    assert_eq!(
        check(
            403,
            &[
                ("x-ratelimit-remaining", "0"),
                ("retry-after", "60"),
                ("x-ratelimit-reset", "1900000000")
            ]
        ),
        Some(now + 60.0)
    );
    assert_eq!(check(403, &[("x-ratelimit-remaining", "0")]), Some(now + 3_600.0));
    // retry-after 无效时当作没有，改看 reset，再没有时推后 1 小时。
    for value in ["inf", "nan", "-5", "-inf", "soon", "1e400"] {
        assert_eq!(
            check(429, &[("retry-after", value)]),
            Some(now + 3_600.0),
            "{value}"
        );
        assert_eq!(
            check(
                429,
                &[("retry-after", value), ("x-ratelimit-reset", "1800000600")]
            ),
            Some(1_800_000_600.0)
        );
    }
    // reset 无效时当作没有。
    for value in ["inf", "nan", "-1", "-1800000000"] {
        assert_eq!(
            check(
                403,
                &[("x-ratelimit-remaining", "0"), ("x-ratelimit-reset", value)]
            ),
            Some(now + 3_600.0)
        );
    }
    // 过大的值截到现在加 24 小时；早于现在的 reset 取现在；值两侧的空白去掉。
    let day = now + 86_400.0;
    assert_eq!(check(429, &[("retry-after", "99999999999")]), Some(day));
    assert_eq!(
        check(
            403,
            &[
                ("x-ratelimit-remaining", "0"),
                ("x-ratelimit-reset", "99999999999")
            ]
        ),
        Some(day)
    );
    assert_eq!(
        check(
            403,
            &[("x-ratelimit-remaining", "0"), ("x-ratelimit-reset", "1000")]
        ),
        Some(now)
    );
    assert_eq!(check(429, &[("retry-after", " 30 ")]), Some(now + 30.0));
    // 还有额度的 403、200、404 都不是限流。
    assert_eq!(check(403, &[("x-ratelimit-remaining", "12")]), None);
    assert_eq!(check(403, &[]), None);
    assert_eq!(check(200, &[("x-ratelimit-remaining", "0")]), None);
    assert_eq!(check(404, &[("retry-after", "5")]), None);
}

/// 统一发布（1.4.0 起）：`v*` 的项带着本版本的 Windows 压缩包才算 Windows 版；纯 macOS 的 `v*`、
/// 压缩包版本号对不上的 `v*` 跳过；过渡用的 `win-v1.4.0` 照样认，同一版本出现两次由 policy 与 history 去重。
#[test]
fn unified_tags_need_the_windows_archive() {
    let unified_assets = |version: &str, tag: &str| {
        json!([
            {"name": format!("EVE-O-Preview-{version}.dmg"), "size": 8_700_000,
             "browser_download_url": url(&format!("download/{tag}/EVE-O-Preview-{version}.dmg"))},
            {"name": format!("EVE-O-Preview-{version}-windows-x64.zip"), "size": 9_600_000,
             "browser_download_url": url(&format!("download/{tag}/EVE-O-Preview-{version}-windows-x64.zip"))},
            {"name": "SHA256SUMS.txt", "size": 400, "browser_download_url": url(&format!("download/{tag}/SHA256SUMS.txt"))},
            {"name": "SHA256SUMS.txt.sig", "size": 89,
             "browser_download_url": url(&format!("download/{tag}/SHA256SUMS.txt.sig"))}
        ])
    };
    let mac_only = json!([
        {"name": "EVE-O-Preview-1.3.2.dmg", "size": 8_699_515,
         "browser_download_url": url("download/v1.3.2/EVE-O-Preview-1.3.2.dmg")},
        {"name": "SHA256SUMS.txt", "size": 299, "browser_download_url": url("download/v1.3.2/SHA256SUMS.txt")}
    ]);
    let list = parse(vec![
        item("v1.4.0", json!({"assets": unified_assets("1.4.0", "v1.4.0")})),
        item("win-v1.4.0", json!({})),
        item("v1.3.2", json!({"assets": mac_only})),
        // 压缩包是别的版本的：不算。
        item("v1.5.0", json!({"assets": unified_assets("1.4.9", "v1.5.0")})),
        item("win-v1.1.0", json!({})),
    ])
    .expect("有效");
    let tags: Vec<&str> = list.releases.iter().map(|info| info.tag_name.as_str()).collect();
    assert_eq!(tags, ["v1.4.0", "win-v1.4.0", "win-v1.1.0"]);
    let unified = &list.releases[0];
    assert_eq!(unified.version, "1.4.0");
    assert_eq!(unified.assets.len(), 4);
    assert!(unified.asset("EVE-O-Preview-1.4.0-windows-x64.zip").is_some());
}
