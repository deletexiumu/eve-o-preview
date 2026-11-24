// SPDX-License-Identifier: GPL-3.0-or-later
//
// GitHub Release 列表答复的解析与限流判断（规则移植 macOS 的 ReleaseFeedParser 与 ReleaseHistory.parse）。
//
// Windows 只取 Release 列表（feed 模块开头说明了原因），这里把一页列表转成 Windows 版的发布信息：
// - 顶层是 JSON 数组，超过 4 MiB 时按 `MalformedFeed` 处理。数组的元素不是对象时跳过这一项。
// - 只留 Windows 版的项：tag 是 `win-v<版本>`，或是 `v<版本>` 且附件里有这个版本的 Windows 压缩包
//   （1.3.2 及更早的 `v*` 是纯 macOS 的 Release）。去掉前缀后要能解析成 `SemanticVersion`；草稿跳过。
// - 一项的 `html_url` 不通过 `feed.accepts` 时只跳过这一项；附件地址不通过时只丢掉这个附件，附件只看前 100 个。
// - `body` 超过 65,536 个字符时截短，缺失或为 null 时取空串；`name` 缺失或为空时标题取 tag。
// - 预发布照样取出（是否提示由 policy 按正在运行的版本决定）。
// - 答复的项数（含被跳过的）达到每页个数时 `is_full` 为真：可能还有下一页，中间版本的说明可能不全。
//
// 限流：403 或 429，且 `x-ratelimit-remaining` 是 0 或有 `retry-after` 时是限流。
// 可以再试的时刻先看 `retry-after`，再看 `x-ratelimit-reset`，都没有时取现在加 1 小时。
// 两个头的值都应是有限的非负数，否则当作没有。得到的时刻不早于现在、不晚于现在加 24 小时。

//! Release 列表的解析与限流判断。

use serde_json::{Map, Value};

use super::feed::{self, UpdateFeed};
use super::history::PAGE_SIZE;
use super::models::{ReleaseAsset, ReleaseInfo, UpdateError};
use super::version::SemanticVersion;
use crate::support::time::parse_iso8601;

/// 列表答复正文的上限：4 MiB。每个 Release 的正文约 10～15 KB，加上附件信息，100 个约 2 MiB。
pub const MAX_LIST_BYTES: usize = 4_194_304;
/// 发布说明保留的最多字符数。
pub const MAX_NOTES_CHARACTERS: usize = 65_536;
/// 每个 Release 最多看前多少个附件。
pub const MAX_ASSETS: usize = 100;
/// 限流答复里两个时刻头都没有时，推后的秒数。
pub const DEFAULT_RATE_LIMIT_DELAY: f64 = 3_600.0;
/// 可以再试的时刻最多推后多少秒：24 小时。
pub const MAX_RATE_LIMIT_DELAY: f64 = 86_400.0;

/// 一页 Release 列表的解析结果。
#[derive(Debug, Clone, PartialEq)]
pub struct ReleaseList {
    /// Windows 版的各个 Release（已去掉草稿与别的 tag），保持答复里的顺序。
    pub releases: Vec<ReleaseInfo>,
    /// 答复的项数是否达到每页的个数。
    pub is_full: bool,
}

/// 解析列表接口的 200 答复。内容不符合规则时返回 `MalformedFeed`，原因是英文，不含正文内容。
pub fn parse_list(data: &[u8], feed: &UpdateFeed) -> Result<ReleaseList, UpdateError> {
    if data.len() > MAX_LIST_BYTES {
        return Err(malformed("release list larger than 4 MiB"));
    }
    // 先整体解成 JSON：列表最多 4 MiB，一次读进内存没有问题。
    let root: Value = serde_json::from_slice(data).map_err(|_| malformed("release list is not JSON"))?;
    let Value::Array(items) = root else {
        return Err(malformed("release list is not an array"));
    };
    // 不是对象的元素与不合规则的项各自跳过，不让一项坏数据挡住整页。
    let releases = items
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|object| release(object, feed))
        .collect();
    Ok(ReleaseList {
        releases,
        is_full: items.len() >= PAGE_SIZE,
    })
}

/// 列表里的一项按本文件开头的规则转成发布信息；不合规则时返回 None。
fn release(object: &Map<String, Value>, feed: &UpdateFeed) -> Option<ReleaseInfo> {
    if object.get("draft").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    // tag 先去掉 `win-v` 或 `v`；`v*` 的项在取完附件后还要核对有没有 Windows 压缩包。
    let tag = object.get("tag_name")?.as_str()?;
    let version_text = feed::version_text(tag)?;
    let version = SemanticVersion::parse(version_text)?;
    // 发布页会被打开，地址不合格的整项不用。
    let page_url = object.get("html_url")?.as_str()?;
    if !feed.accepts(page_url) {
        return None;
    }
    let notes = object
        .get("body")
        .and_then(Value::as_str)
        .map(|body| truncate_chars(body, MAX_NOTES_CHARACTERS))
        .unwrap_or_default();
    let title = object
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .unwrap_or(tag);
    let assets: Vec<ReleaseAsset> = object
        .get("assets")
        .and_then(Value::as_array)
        .map(|assets| {
            assets
                .iter()
                .take(MAX_ASSETS)
                .filter_map(|asset| asset_from(asset, feed))
                .collect()
        })
        .unwrap_or_default();
    // 统一发布的 tag 也用在纯 macOS 的旧 Release 上：没有本版本 Windows 压缩包的不是 Windows 版。
    // 附件名按 tag 里的原样版本文字拼，与发布脚本一致。
    if feed::is_unified_tag(tag) && !has_archive(&assets, version_text) {
        return None;
    }
    Some(ReleaseInfo {
        version: version.to_string(),
        tag_name: tag.to_owned(),
        title: title.to_owned(),
        notes,
        page_url: page_url.to_owned(),
        published_at: object
            .get("published_at")
            .and_then(Value::as_str)
            .and_then(parse_iso8601),
        is_prerelease: object.get("prerelease").and_then(Value::as_bool).unwrap_or(false),
        is_draft: false,
        assets,
    })
}

/// 附件里是否有这个版本的 Windows 压缩包（只看通过地址核对的附件）。
fn has_archive(assets: &[ReleaseAsset], version_text: &str) -> bool {
    let name = feed::archive_name(version_text);
    assets.iter().any(|asset| asset.name == name)
}

/// 一个附件；缺字段或地址不通过 `feed.accepts` 时返回 None。
fn asset_from(value: &Value, feed: &UpdateFeed) -> Option<ReleaseAsset> {
    let object = value.as_object()?;
    let name = object.get("name")?.as_str()?;
    let url = object.get("browser_download_url")?.as_str()?;
    if !feed.accepts(url) {
        return None;
    }
    Some(ReleaseAsset {
        name: name.to_owned(),
        download_url: url.to_owned(),
        size: object.get("size").and_then(Value::as_u64),
    })
}

/// 按字符（Unicode 标量）截短，与 Swift 的 `prefix` 按字符计数相近。
pub(crate) fn truncate_chars(text: &str, limit: usize) -> String {
    match text.char_indices().nth(limit) {
        Some((cut, _)) => text[..cut].to_owned(),
        None => text.to_owned(),
    }
}

/// 建一个 `MalformedFeed`。
fn malformed(reason: &str) -> UpdateError {
    UpdateError::MalformedFeed(reason.to_owned())
}

/// 判断一次答复是不是限流，并给出可以再试的时刻。header 按名字（小写）取值。不是限流时返回 None。
pub fn rate_limit<'a>(status: u16, header: impl Fn(&str) -> Option<&'a str>, now: f64) -> Option<f64> {
    if status != 403 && status != 429 {
        return None;
    }
    let remaining = header("x-ratelimit-remaining").map(str::trim);
    let retry_after = header("retry-after");
    if remaining != Some("0") && retry_after.is_none() {
        return None;
    }
    // 先在秒数上截到上限，过大的值不会写出 state.json 读不回来的日期。
    let latest = now + MAX_RATE_LIMIT_DELAY;
    if let Some(seconds) = non_negative_number(retry_after) {
        return Some((now + seconds.min(MAX_RATE_LIMIT_DELAY)).min(latest));
    }
    if let Some(reset) = non_negative_number(header("x-ratelimit-reset")) {
        return Some(reset.min(latest).max(now));
    }
    Some(now + DEFAULT_RATE_LIMIT_DELAY)
}

/// 头的值是有限的非负数时返回它；缺失、解析不了、`inf`、`nan` 或负数时返回 None。
fn non_negative_number(text: Option<&str>) -> Option<f64> {
    let value: f64 = text?.trim().parse().ok()?;
    (value.is_finite() && value >= 0.0).then_some(value)
}

#[cfg(test)]
#[path = "parser_tests.rs"]
mod tests;
