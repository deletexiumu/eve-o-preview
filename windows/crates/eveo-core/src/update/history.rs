// SPDX-License-Identifier: GPL-3.0-or-later
//
// 跨版本的发布说明（macOS v1.1 设计 8.8 节，移植 ReleaseHistory.swift 的挑选部分）。
//
// 用户跳过了几个版本（如正在运行 0.9.1、最新是 0.9.3）时，更新窗口还要显示中间版本（0.9.2）的说明。
// Windows 的检查本来就取整页列表，中间版本从同一页里挑，不用再请求一次。
// 挑出的说明存在 state.json 里，最多 10 个、总共约 256 KB；超出或列表不全时 `has_more` 为真，
// 窗口在最后提示到发布页看更早的版本。

//! 中间版本的发布说明。

use std::collections::HashSet;

use super::models::ReleaseInfo;
use super::version::SemanticVersion;

/// 列表请求每页的个数（与 `feed::PRODUCTION_LIST_URL` 的 `per_page` 一致）。macOS 版也占位置。
pub const PAGE_SIZE: usize = 100;
/// 最多保留的中间版本数。落后更多的用户只看到最近的这些，其余请看发布页。
pub const MAX_ENTRIES: usize = 10;
/// 保留的中间版本说明的总字符数上限，约 256 KB：这些说明存在 state.json 里，每次写状态都要重写。
pub const MAX_TOTAL_CHARACTERS: usize = 262_144;

/// 一个版本的发布说明，只含版本号与正文（正文是 Release 的原文，含各语言的块）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseNotesEntry {
    /// 规范写法的版本号，如 `0.9.2`。
    pub version: String,
    /// Release 正文，最多 65,536 个字符。
    pub notes: String,
}

/// 某个最新版对应的中间版本说明。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntermediateReleaseNotes {
    /// 这些说明是为哪个最新版取的。最新版变了就要重取。
    pub latest_version: String,
    /// 取的时候正在运行的版本，即这些说明覆盖的下界。
    pub running_version: String,
    /// 中间版本的说明，新版在前。
    pub entries: Vec<ReleaseNotesEntry>,
    /// 是否还有更早的中间版本没有列出。
    pub has_more: bool,
}

/// 从说明里挑出 running < v < latest 的版本，按版本号从新到旧排，同一版本只留第一次出现的。
/// 版本号解析不了的项跳过。显示前也用它按当时正在运行的版本再过滤一次存下的记录。
pub fn intermediate(
    entries: &[ReleaseNotesEntry],
    running: &SemanticVersion,
    latest: &SemanticVersion,
) -> Vec<ReleaseNotesEntry> {
    let mut seen = HashSet::new();
    let mut picked: Vec<(SemanticVersion, &ReleaseNotesEntry)> = entries
        .iter()
        .filter_map(|entry| {
            let version = SemanticVersion::parse(&entry.version)?;
            (running < &version && &version < latest && seen.insert(version.clone()))
                .then_some((version, entry))
        })
        .collect();
    // 列表接口按创建时间排序，补发的旧版本可能排在前面，所以这里按版本号重新排（稳定排序）。
    picked.sort_by(|a, b| b.0.cmp(&a.0));
    picked.into_iter().map(|(_, entry)| entry.clone()).collect()
}

/// 由一页列表得出要存的记录：中间版本最多 `MAX_ENTRIES` 个、总字符数不超过 `MAX_TOTAL_CHARACTERS`（超出时留较新的），
/// 并判断是否还有没列出的更早版本。
///
/// releases 是调用方按渠道过滤过的 Windows 版（正在运行正式版时不含预发布）。如果整页都比正在运行的版本新，
/// 且页是满的，更早的中间版本可能在下一页，`has_more` 为真。
pub fn record(
    releases: &[&ReleaseInfo],
    is_full: bool,
    running: &SemanticVersion,
    latest: &SemanticVersion,
) -> IntermediateReleaseNotes {
    let entries: Vec<ReleaseNotesEntry> = releases
        .iter()
        .map(|release| ReleaseNotesEntry {
            version: release.version.clone(),
            notes: release.notes.clone(),
        })
        .collect();
    let all = intermediate(&entries, running, latest);
    // 从最新的开始收，超过条数或总字符数时停下：较旧的版本请看发布页。
    let mut kept = Vec::new();
    let mut total = 0;
    for entry in all.iter().take(MAX_ENTRIES) {
        let count = entry.notes.chars().count();
        if total + count > MAX_TOTAL_CHARACTERS {
            break;
        }
        total += count;
        kept.push(entry.clone());
    }
    // 这一页里有不比正在运行的版本新的版本，说明下界已覆盖到；否则满页时可能还有更早的。
    let reached_running = entries
        .iter()
        .any(|entry| SemanticVersion::parse(&entry.version).is_some_and(|version| &version <= running));
    let has_more = kept.len() < all.len() || (is_full && !reached_running);
    IntermediateReleaseNotes {
        latest_version: latest.to_string(),
        running_version: running.to_string(),
        entries: kept,
        has_more,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 版本号字面量。
    fn version(text: &str) -> SemanticVersion {
        SemanticVersion::parse(text).expect("版本号")
    }

    /// 一项说明。
    fn entry(version: &str, notes: &str) -> ReleaseNotesEntry {
        ReleaseNotesEntry {
            version: version.to_owned(),
            notes: notes.to_owned(),
        }
    }

    /// 一个只有版本号与正文的发布版。
    fn release(version: &str, notes: &str) -> ReleaseInfo {
        ReleaseInfo {
            version: version.to_owned(),
            tag_name: format!("win-v{version}"),
            title: String::new(),
            notes: notes.to_owned(),
            page_url: String::new(),
            published_at: None,
            is_prerelease: false,
            is_draft: false,
            assets: Vec::new(),
        }
    }

    /// 只看版本号。
    fn versions(entries: &[ReleaseNotesEntry]) -> Vec<&str> {
        entries.iter().map(|e| e.version.as_str()).collect()
    }

    /// 只留 running < v < latest，按版本号从新到旧排，重复的版本只留第一次出现的。
    #[test]
    fn intermediate_picks_range_newest_first() {
        let entries: Vec<_> = ["1.0.0", "1.1.2", "1.1.3", "1.1.1", "1.2.0", "1.1.2"]
            .iter()
            .enumerate()
            .map(|(i, v)| entry(v, &format!("n{i}")))
            .collect();
        let picked = intermediate(&entries, &version("1.1.0"), &version("1.1.3"));
        assert_eq!(versions(&picked), ["1.1.2", "1.1.1"]);
        assert_eq!(picked[0].notes, "n1");
    }

    /// 正在运行的是 CI 构建（小于同号正式版）时，那个正式版也算中间版本。
    #[test]
    fn prerelease_running_version_includes_its_release() {
        let entries = [entry("1.1.2", ""), entry("1.1.1", "")];
        let picked = intermediate(&entries, &version("1.1.2-pr.3.abc1234"), &version("1.1.3"));
        assert_eq!(versions(&picked), ["1.1.2"]);
    }

    /// 相邻版本之间没有中间版本；列表覆盖到了正在运行的版本，所以 `has_more` 为假。
    #[test]
    fn adjacent_versions_have_no_intermediate() {
        let list = [release("1.1.3", ""), release("1.1.2", "")];
        let refs: Vec<_> = list.iter().collect();
        let record = record(&refs, false, &version("1.1.2"), &version("1.1.3"));
        assert!(record.entries.is_empty());
        assert!(!record.has_more);
        assert_eq!(record.latest_version, "1.1.3");
        assert_eq!(record.running_version, "1.1.2");
    }

    /// 超过 `MAX_ENTRIES` 个时留最新的那些，`has_more` 为真。
    #[test]
    fn entry_limit() {
        let mut list: Vec<_> = (1..=15)
            .rev()
            .map(|n| release(&format!("1.0.{n}"), "n"))
            .collect();
        list.push(release("1.0.0", ""));
        let refs: Vec<_> = list.iter().collect();
        let record = record(&refs, false, &version("1.0.0"), &version("1.0.16"));
        assert_eq!(record.entries.len(), MAX_ENTRIES);
        assert_eq!(record.entries[0].version, "1.0.15");
        assert!(record.has_more);
    }

    /// 总字符数超过上限时从较旧的开始丢，`has_more` 为真。
    #[test]
    fn size_limit() {
        let big = "x".repeat(MAX_TOTAL_CHARACTERS / 2);
        let list: Vec<_> = ["1.0.3", "1.0.2", "1.0.1"]
            .iter()
            .map(|v| release(v, &big))
            .collect();
        let refs: Vec<_> = list.iter().collect();
        let record = record(&refs, false, &version("1.0.0"), &version("1.0.4"));
        assert_eq!(versions(&record.entries), ["1.0.3", "1.0.2"]);
        assert!(record.has_more);
    }

    /// 满页且整页都比正在运行的版本新：`has_more` 为真；不满页时为假。
    #[test]
    fn full_page_without_running_version_has_more() {
        let list = [release("1.0.9", ""), release("1.0.8", "")];
        let refs: Vec<_> = list.iter().collect();
        assert!(record(&refs, true, &version("1.0.1"), &version("1.0.9")).has_more);
        assert!(!record(&refs, false, &version("1.0.1"), &version("1.0.9")).has_more);
    }
}
