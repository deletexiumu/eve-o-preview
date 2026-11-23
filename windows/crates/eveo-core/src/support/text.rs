// SPDX-License-Identifier: GPL-3.0-or-later
//
// 与 Foundation 对齐的文本处理。macOS 端用 `trimmingCharacters(in:)`、`caseInsensitiveCompare`、
// `String.count`（按字素簇计数）等，这里给出行为相同的 Rust 写法，让两端对同一个字符串得出同一个结果。

//! 与 Foundation 对齐的文本处理。

use unicode_segmentation::UnicodeSegmentation;

/// 是否是换行类字符，对应 Foundation 的 `CharacterSet.newlines`。
pub fn is_newline(c: char) -> bool {
    matches!(c, '\u{000A}'..='\u{000D}' | '\u{0085}' | '\u{2028}' | '\u{2029}')
}

/// 去掉首尾的空白与换行，对应 `trimmingCharacters(in: .whitespacesAndNewlines)`。
///
/// Rust 的 `char::is_whitespace` 与 Foundation 的这个字符集覆盖同一批字符。
pub fn trim_whitespace_and_newlines(s: &str) -> &str {
    s.trim()
}

/// 只去掉首尾的空白、不去换行，对应 `trimmingCharacters(in: .whitespaces)`。
pub fn trim_whitespace(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

/// 不区分大小写地比较两个字符串，近似 `caseInsensitiveCompare(_:) == .orderedSame`。
///
/// 先转大写再转小写，相当于简单的大小写折叠：`ß` 与 `SS`、`ss` 视为相同，与 Foundation 一致。
pub fn eq_ignore_case(a: &str, b: &str) -> bool {
    a == b || fold(a) == fold(b)
}

/// 大小写折叠后的字符串。
fn fold(s: &str) -> String {
    s.to_uppercase().to_lowercase()
}

/// 按字素簇计的长度，对应 Swift 的 `String.count`。
pub fn char_count(s: &str) -> usize {
    s.graphemes(true).count()
}

/// 前 `n` 个字素簇，对应 Swift 的 `String.prefix(n)`。
pub fn prefix(s: &str, n: usize) -> &str {
    match s.grapheme_indices(true).nth(n) {
        Some((index, _)) => &s[..index],
        None => s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 换行只在 whitespacesAndNewlines 里去掉。
    #[test]
    fn trimming_sets() {
        assert_eq!(trim_whitespace_and_newlines(" \tA\n"), "A");
        assert_eq!(trim_whitespace(" \tA\n"), "A\n");
        assert_eq!(trim_whitespace("\u{3000}A\u{00A0}"), "A");
    }

    /// 大小写折叠。
    #[test]
    fn case_folding() {
        assert!(eq_ignore_case("Default", "DEFAULT"));
        assert!(eq_ignore_case("Straße", "STRASSE"));
        assert!(!eq_ignore_case("A", "B"));
    }

    /// 字素簇计数：组合字符与表情各算一个。
    #[test]
    fn grapheme_counting() {
        assert_eq!(char_count("e\u{301}x"), 2);
        assert_eq!(char_count("👨‍👩‍👧"), 1);
        assert_eq!(prefix("e\u{301}xy", 2), "e\u{301}x");
        assert_eq!(prefix("ab", 5), "ab");
    }
}
