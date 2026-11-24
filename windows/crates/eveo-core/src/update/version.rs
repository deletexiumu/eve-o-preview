// SPDX-License-Identifier: GPL-3.0-or-later
//
// 语义化版本号（macOS v1.1 设计 8.3 节，移植 SemanticVersion.swift）：解析 tag 与构建标签，
// 按语义化版本 2.0.0 第 11 条比较。
//
// 与规范的差别只有一处：纯数字的预发布段带前导零（如提交号 `0012345`）时不报错，按含字母的段处理，
// 所以 CI 的标签 `1.1.0-pr.12.0012345` 能解析。构建信息（`+` 之后）不参与比较，也不参与相等与哈希。
// Windows 的 tag 是 `win-v<版本>`，前缀由 feed 模块去掉，这里只认可选的 `v`。

//! 语义化版本号。

use std::cmp::Ordering;
use std::fmt;
use std::hash::{Hash, Hasher};

/// 语义化版本号，如 `1.2.0-beta.1+build.5`。
#[derive(Debug, Clone)]
pub struct SemanticVersion {
    /// 主版本号。
    pub major: u64,
    /// 次版本号。
    pub minor: u64,
    /// 修订号。
    pub patch: u64,
    /// 预发布标识按 `.` 分段，如 "1.2.0-beta.1" 的 ["beta", "1"]。
    pub prerelease: Vec<String>,
    /// "+" 后面的部分按 `.` 分段，不参与比较。
    pub build: Vec<String>,
}

impl SemanticVersion {
    /// 解析版本号；接受开头的 "v" 或 "V"。格式不对时返回 None。
    ///
    /// 三段数字都应是非负整数；只有两段或有四段时失败。预发布与构建信息按 `.` 分段，
    /// 每段由 ASCII 字母、数字和 `-` 组成，不能为空。
    pub fn parse(text: &str) -> Option<Self> {
        let mut rest = text.strip_prefix(['v', 'V']).unwrap_or(text);
        // 先切掉构建信息，再切预发布标识：预发布标识里可以有 `-`，构建信息里也可以有。
        let mut build_part = None;
        if let Some((head, build)) = rest.split_once('+') {
            build_part = Some(build);
            rest = head;
        }
        let mut prerelease_part = None;
        if let Some((head, pre)) = rest.split_once('-') {
            prerelease_part = Some(pre);
            rest = head;
        }
        // 三段数字缺一不可：`1.1` 与 `1.1.0.0` 都不是语义化版本。
        let numbers: Vec<&str> = rest.split('.').collect();
        let [major, minor, patch] = numbers.as_slice() else {
            return None;
        };
        let prerelease = match prerelease_part {
            Some(part) => identifiers(part)?,
            None => Vec::new(),
        };
        let build = match build_part {
            Some(part) => identifiers(part)?,
            None => Vec::new(),
        };
        Some(Self {
            major: number(major)?,
            minor: number(minor)?,
            patch: number(patch)?,
            prerelease,
            build,
        })
    }

    /// 是否带预发布标识。
    pub fn is_prerelease(&self) -> bool {
        !self.prerelease.is_empty()
    }
}

/// 规范写法，不带 "v"：`主.次.修订[-预发布][+构建信息]`。
impl fmt::Display for SemanticVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)?;
        if !self.prerelease.is_empty() {
            write!(f, "-{}", self.prerelease.join("."))?;
        }
        if !self.build.is_empty() {
            write!(f, "+{}", self.build.join("."))?;
        }
        Ok(())
    }
}

/// 相等只看三段数字与预发布标识。
impl PartialEq for SemanticVersion {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for SemanticVersion {}

/// 哈希与相等的口径一致，不含构建信息。
impl Hash for SemanticVersion {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (self.major, self.minor, self.patch, &self.prerelease).hash(state);
    }
}

impl PartialOrd for SemanticVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// 按语义化版本 2.0.0 第 11 条比较；构建信息不参与。
impl Ord for SemanticVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        // 三段数字按数值比较（不是按字符串：1.10.0 大于 1.9.0）。
        let numbers = (self.major, self.minor, self.patch).cmp(&(other.major, other.minor, other.patch));
        if numbers != Ordering::Equal {
            return numbers;
        }
        // 数字相同时，没有预发布标识的更大。
        match (self.prerelease.is_empty(), other.prerelease.is_empty()) {
            (true, true) => return Ordering::Equal,
            (true, false) => return Ordering::Greater,
            (false, true) => return Ordering::Less,
            (false, false) => {}
        }
        for (left, right) in self.prerelease.iter().zip(&other.prerelease) {
            if left != right {
                return identifier_cmp(left, right);
            }
        }
        // 前面各段都相同时，段数多的更大。
        self.prerelease.len().cmp(&other.prerelease.len())
    }
}

/// 一段非负整数：只含 ASCII 数字，不为空，不溢出。
fn number(text: &str) -> Option<u64> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// 按 `.` 分段并逐段核对字符；有空段或非法字符时返回 None。
fn identifiers(text: &str) -> Option<Vec<String>> {
    text.split('.')
        .map(|segment| {
            let valid =
                !segment.is_empty() && segment.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
            valid.then(|| segment.to_owned())
        })
        .collect()
}

/// 一段预发布标识的数值；不是纯数字，或纯数字但带前导零时返回 None（按含字母的段处理）。
fn numeric_value(identifier: &str) -> Option<u64> {
    if !identifier.bytes().all(|b| b.is_ascii_digit())
        || (identifier.len() > 1 && identifier.starts_with('0'))
    {
        return None;
    }
    identifier.parse().ok()
}

/// 两段预发布标识的比较：都是数字按数值；否则纯数字的更小；都含字母按 ASCII 顺序。
fn identifier_cmp(left: &str, right: &str) -> Ordering {
    match (numeric_value(left), numeric_value(right)) {
        (Some(l), Some(r)) => l.cmp(&r),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => left.as_bytes().cmp(right.as_bytes()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// 解析一个应当合法的版本号。
    fn v(text: &str) -> SemanticVersion {
        SemanticVersion::parse(text).unwrap_or_else(|| panic!("{text} 应能解析"))
    }

    /// 带与不带 v（大小写都可以）解析出同样的版本。
    #[test]
    fn parses_with_optional_prefix() {
        for text in ["1.2.3", "v1.2.3", "V1.2.3"] {
            let version = v(text);
            assert_eq!((version.major, version.minor, version.patch), (1, 2, 3));
            assert!(version.prerelease.is_empty() && version.build.is_empty());
            assert_eq!(version.to_string(), "1.2.3");
            assert!(!version.is_prerelease());
        }
    }

    /// 两段、四段、空串、负数、非数字、空的预发布段等写法失败。
    #[test]
    fn rejects_invalid() {
        for text in [
            "1.1",
            "1.1.0.0",
            "",
            "-1.0.0",
            "1.-1.0",
            "1.0.a",
            "v",
            "1.0.0-",
            "1.0.0-alpha..1",
            "1.0.0+",
            "1.0.0-al_pha",
            " 1.0.0",
            "1.0.0 ",
            "vv1.0.0",
            "1..0",
            "win-v1.0.0",
        ] {
            assert!(SemanticVersion::parse(text).is_none(), "{text:?} 不应能解析");
        }
    }

    /// 预发布与构建信息分段保存，规范写法还原原文（不带 v）。
    #[test]
    fn parses_prerelease_and_build() {
        // 预发布与构建信息里都可以有 `.`，各自分段。
        let version = v("v1.2.0-beta.1+build.5");
        assert_eq!(version.prerelease, ["beta", "1"]);
        assert_eq!(version.build, ["build", "5"]);
        assert!(version.is_prerelease());
        assert_eq!(version.to_string(), "1.2.0-beta.1+build.5");
    }

    /// 规范第 11 条的排序样例。
    #[test]
    fn specification_ordering() {
        let texts = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ];
        let versions: Vec<_> = texts.iter().map(|t| v(t)).collect();
        // 相邻两个严格递增；倒过来排序后与原顺序相同。
        for pair in versions.windows(2) {
            assert!(pair[0] < pair[1], "{} < {}", pair[0], pair[1]);
        }
        let mut reversed: Vec<_> = versions.iter().rev().cloned().collect();
        reversed.sort();
        assert_eq!(reversed, versions);
    }

    /// 三段数字按数值比较。
    #[test]
    fn numeric_comparison() {
        assert!(v("1.9.0") < v("1.10.0"));
        assert!(v("1.99.99") < v("2.0.0"));
        assert!(v("1.0.9") < v("1.0.10"));
    }

    /// 构建信息不参与比较、相等与哈希。
    #[test]
    fn build_metadata_ignored() {
        // 同一个版本，一个带构建信息：相等、不分大小、哈希相同。
        let plain = v("1.0.0");
        let built = v("1.0.0+20261121");
        assert_eq!(plain, built);
        assert_eq!(plain.cmp(&built), Ordering::Equal);
        assert_eq!(HashSet::from([plain, built]).len(), 1);
    }

    /// CI 的标签小于同版本号的正式版、大于上一个正式版。
    #[test]
    fn ci_labels_sort_between_releases() {
        for text in ["1.1.0-pr.12.abc1234", "1.1.0-dev.abc1234", "v1.1.0-pr.3.0012345"] {
            let label = v(text);
            assert!(label < v("1.1.0"));
            assert!(v("1.0.0") < label);
            assert!(label.is_prerelease());
        }
    }

    /// 带前导零的数字段能解析，按含字母的段处理：排在纯数字段之后。
    #[test]
    fn leading_zero_segments_are_alphanumeric() {
        let zero = v("1.1.0-pr.12.0012345");
        assert_eq!(zero.prerelease, ["pr", "12", "0012345"]);
        assert!(v("1.1.0-pr.12.99999999") < zero);
        assert!(zero < v("1.1.0-pr.12.abc"));
    }

    /// 纯数字的段小于含字母的段；前面各段相同时段数多的更大。
    #[test]
    fn identifier_rules() {
        assert!(v("1.0.0-1") < v("1.0.0-a"));
        assert!(v("1.0.0-a") < v("1.0.0-a.1"));
        assert!(v("1.0.0-B") < v("1.0.0-a"));
        assert!(v("1.0.0-pr.9") < v("1.0.0-pr.12"));
    }
}
