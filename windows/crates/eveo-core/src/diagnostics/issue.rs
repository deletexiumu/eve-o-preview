// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预填的 GitHub Issue 地址，对应 macOS 的 IssueURLBuilder.swift（v1.1 设计 7.5 节）：
// - 形式：`https://github.com/deletexiumu/eve-o-preview/issues/new?title=<标题>&body=<正文>`，
//   不带 `template` 与 `labels` 参数。
// - 标题与正文一律用英文。标题超过 120 个字符时截短。正文由小节拼成，每节是 `### <标题>`、空行、内容、空行。
// - 编码：除 RFC 3986 的非保留字符（字母、数字、`-._~`）外一律百分号编码，空格是 `%20`，`+` 是 `%2B`
//   （GitHub 把 `+` 当空格）。比 macOS 的 URLComponents 多编码几个标点，地址略长，预算照算。
// - 预算：地址不超过 6,000 字节。超出时按以下顺序缩短，每一步之后重新计算：
//   1. 从后往前丢掉可选的小节。
//   2. 从 `Environment` 的末尾逐行删。
//   3. 从最后一个小节起按字符从末尾截短内容，补上 `…`；截空了仍超出时再截前一个小节。
//   最后丢掉全部小节、截短标题；都不行时只留不带参数的地址。
// - 标题与正文在交给这里之前已由应用用 Redactor 处理过。

//! 预填的 GitHub Issue 地址。

use crate::diagnostics::summary::EnvironmentReport;

/// 仓库。
pub const REPOSITORY: &str = "deletexiumu/eve-o-preview";
/// 地址的字节上限（百分号编码后）。
pub const MAX_URL_BYTES: usize = 6000;
/// 标题的字符上限。
pub const MAX_TITLE_CHARACTERS: usize = 120;
/// 截短时补在末尾的记号。
const ELLIPSIS: &str = "…";
/// 缩短时逐行删的小节的标题。
pub const ENVIRONMENT_HEADING: &str = "Environment";

/// Issue 正文的一个小节。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssueSection {
    /// 小节标题。
    pub heading: String,
    /// 内容。
    pub body: String,
    /// 必留的小节只会被截短，不会被丢掉。
    pub required: bool,
}

impl IssueSection {
    /// 用各字段建小节。
    pub fn new(heading: impl Into<String>, body: impl Into<String>, required: bool) -> Self {
        Self {
            heading: heading.into(),
            body: body.into(),
            required,
        }
    }
}

/// 一份 Issue 草稿：标题与小节。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssueDraft {
    /// 标题。
    pub title: String,
    /// 小节，按顺序。
    pub sections: Vec<IssueSection>,
}

/// 不带参数的新建 Issue 地址。
pub fn base_url() -> String {
    format!("https://github.com/{REPOSITORY}/issues/new")
}

/// 正文：每节是 `### <标题>`、空行、内容、空行。
pub fn body(draft: &IssueDraft) -> String {
    draft
        .sections
        .iter()
        .map(|s| format!("### {}\n\n{}\n\n", s.heading, s.body))
        .collect()
}

/// 草稿的地址，百分号编码后不超过 limit 字节（limit 不小于不带参数的地址时）。
pub fn issue_url(draft: &IssueDraft, limit: usize) -> String {
    // current 是逐步缩短的草稿；每一步之后都重新编码、比较一次，放得下就返回。
    let mut current = draft.clone();
    current.title = truncated_title(&draft.title);
    if fits(&current, limit) {
        return encoded_url(&current);
    }
    // 第 1 步：从后往前丢掉可选的小节。
    while let Some(index) = current.sections.iter().rposition(|s| !s.required) {
        current.sections.remove(index);
        if fits(&current, limit) {
            return encoded_url(&current);
        }
    }
    // 第 2 步：从 Environment 的末尾逐行删。
    if let Some(index) = current
        .sections
        .iter()
        .position(|s| s.heading == ENVIRONMENT_HEADING)
    {
        let mut lines: Vec<String> = current.sections[index]
            .body
            .split('\n')
            .map(str::to_owned)
            .collect();
        while lines.pop().is_some() {
            current.sections[index].body = lines.join("\n");
            if fits(&current, limit) {
                return encoded_url(&current);
            }
        }
    }
    // 第 3 步：从最后一个小节起，按字符从末尾截短内容；截空了仍超出时再截前一个小节。
    for index in (0..current.sections.len()).rev() {
        let original = current.sections[index].body.clone();
        let kept = longest_fitting_prefix(&original, limit, |text| {
            let mut trial = current.clone();
            trial.sections[index].body = text.to_owned();
            trial
        });
        if let Some(kept) = kept {
            current.sections[index].body = kept;
            return encoded_url(&current);
        }
        current.sections[index].body = if original.is_empty() {
            String::new()
        } else {
            ELLIPSIS.to_owned()
        };
    }
    // 兜底：丢掉全部小节，再截短标题；都不行时只留不带参数的地址。
    let title = current.title.clone();
    let titled = |text: &str| IssueDraft {
        title: text.to_owned(),
        sections: Vec::new(),
    };
    match longest_fitting_prefix(&title, limit, titled) {
        Some(kept) => encoded_url(&titled(&kept)),
        None => base_url(),
    }
}

/// 标题超过 120 个字符时截到 119 个字符加 `…`。
fn truncated_title(title: &str) -> String {
    if title.chars().count() <= MAX_TITLE_CHARACTERS {
        return title.to_owned();
    }
    let kept: String = title.chars().take(MAX_TITLE_CHARACTERS - 1).collect();
    kept + ELLIPSIS
}

/// 草稿编码后是否不超过 limit 字节。
fn fits(draft: &IssueDraft, limit: usize) -> bool {
    encoded_url(draft).len() <= limit
}

/// 编码成地址。
fn encoded_url(draft: &IssueDraft) -> String {
    format!(
        "{}?title={}&body={}",
        base_url(),
        percent_encode(&draft.title),
        percent_encode(&body(draft))
    )
}

/// 查询参数的百分号编码：非保留字符原样，其余按 UTF-8 字节编码成 `%XX`（大写）。
pub fn percent_encode(text: &str) -> String {
    // 按字节编码：多字节的 UTF-8 字符每个字节各写一个 %XX，浏览器与 GitHub 都按 UTF-8 解回。
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// 二分查找 text 能保留的最长前缀（按字符），截短时补 `…`。连空串都放不下时返回 None。
/// apply 把候选文字放回草稿。
fn longest_fitting_prefix(text: &str, limit: usize, apply: impl Fn(&str) -> IssueDraft) -> Option<String> {
    // 按字符截，不按字节，免得切断一个多字节字符；保留全部时不补省略号。
    let characters: Vec<char> = text.chars().collect();
    let candidate = |count: usize| -> String {
        if count >= characters.len() {
            text.to_owned()
        } else {
            characters[..count].iter().collect::<String>() + ELLIPSIS
        }
    };
    if !fits(&apply(&candidate(0)), limit) {
        return None;
    }
    // 不变式：保留 low 个字符放得下；保留多于 high 个字符放不下。
    let (mut low, mut high) = (0, characters.len());
    while low < high {
        let middle = (low + high).div_ceil(2);
        if fits(&apply(&candidate(middle)), limit) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    Some(candidate(low))
}

/// 问题报告的草稿（7.5 节的 4 个小节）。
/// crash 为真时标题开头是 `Crash report`，并多一节「Previous run」（上一次的版本与崩溃报告的个数）。
pub fn problem_report_draft(
    crash: bool,
    environment: &EnvironmentReport,
    previous_version: Option<&str>,
    crash_report_count: usize,
    archive_file_name: &str,
) -> IssueDraft {
    let prefix = if crash { "Crash report" } else { "Problem report" };
    // 标题里的系统只写产品名与版本代号，构建号放在 Environment 一节，标题短一些。
    let system = &environment.system;
    let mut os = system.os_name.clone();
    if !system.os_display_version.is_empty() {
        os = format!("{os} {}", system.os_display_version);
    }
    let title = format!("{prefix}: EVE-O Preview {} on {os}", environment.app.version);
    // 「What happened」与「Diagnostics」必留；「Previous run」是可选的，超长时先丢它。
    let mut sections = vec![
        IssueSection::new(
            "What happened",
            "<!-- Describe what you did and what went wrong. Then drag the zip file \
             that File Explorer is showing into this box. -->",
            true,
        ),
        IssueSection::new(ENVIRONMENT_HEADING, environment.issue_lines().join("\n"), true),
    ];
    if crash {
        sections.push(IssueSection::new(
            "Previous run",
            format!(
                "- Version: {}\n- Crash reports: {crash_report_count}",
                previous_version.unwrap_or("unknown")
            ),
            false,
        ));
    }
    sections.push(IssueSection::new(
        "Diagnostics",
        format!("Attach `{archive_file_name}` (File Explorer shows it)."),
        true,
    ));
    IssueDraft { title, sections }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::summary::{AppEnvironment, SystemInfo};

    /// 两节的草稿：一节必留，一节可选。
    fn draft(body_len: usize) -> IssueDraft {
        IssueDraft {
            title: "Problem report".to_owned(),
            sections: vec![
                IssueSection::new("What happened", "x".repeat(body_len), true),
                IssueSection::new("Extra", "y".repeat(body_len), false),
            ],
        }
    }

    /// 编码：空格是 %20，`+` 是 %2B，中文按 UTF-8 编码；未超出时原样。
    #[test]
    fn encodes_query() {
        assert_eq!(percent_encode("a b+c/中"), "a%20b%2Bc%2F%E4%B8%AD");
        let url = issue_url(&draft(5), MAX_URL_BYTES);
        assert!(url.starts_with("https://github.com/deletexiumu/eve-o-preview/issues/new?title=Problem%20report&body=%23%23%23%20What"));
        assert!(url.contains("Extra"));
    }

    /// 超出时先丢可选的小节，再截短必留的小节；结果总不超过上限。
    #[test]
    fn shortens_to_fit() {
        // 两节各 3000 字节，合起来超出 6000：丢掉可选的一节后放得下。
        let full = draft(3000);
        let url = issue_url(&full, MAX_URL_BYTES);
        assert!(url.len() <= MAX_URL_BYTES);
        assert!(!url.contains("Extra"));
        assert!(url.contains("xxxx"));
        // 上限很小时截短必留的小节，补省略号；比不带参数的地址还小时只留它。
        let tight = issue_url(&full, 200);
        assert!(tight.len() <= 200);
        assert!(tight.contains(&percent_encode(ELLIPSIS)));
        assert_eq!(issue_url(&full, 10), base_url());
        let tiny = issue_url(&full, base_url().len() + 20);
        assert!(tiny.len() <= base_url().len() + 20, "{tiny}");
    }

    /// Environment 从末尾逐行删。
    #[test]
    fn drops_environment_lines() {
        let draft = IssueDraft {
            title: "t".to_owned(),
            sections: vec![IssueSection::new(
                ENVIRONMENT_HEADING,
                "- first\n- second\n- third",
                true,
            )],
        };
        // 上限正好少一行的长度：删掉最后一行就放得下。
        let full = issue_url(&draft, MAX_URL_BYTES);
        let limit = full.len() - percent_encode("\n- third").len();
        let url = issue_url(&draft, limit);
        assert!(url.contains("second") && !url.contains("third"));
    }

    /// 标题超过 120 个字符时截短。
    #[test]
    fn truncates_title() {
        let long = "a".repeat(200);
        assert_eq!(truncated_title(&long).chars().count(), MAX_TITLE_CHARACTERS);
        assert!(truncated_title(&long).ends_with(ELLIPSIS));
        assert_eq!(truncated_title("short"), "short");
    }

    /// 崩溃情境的草稿：标题、Previous run 一节与附件名。
    #[test]
    fn crash_draft() {
        let environment = EnvironmentReport {
            app: AppEnvironment {
                version: "0.9.0".into(),
                build_label: "release".into(),
                ..AppEnvironment::default()
            },
            system: SystemInfo {
                os_name: "Windows 11 Pro".into(),
                os_display_version: "24H2".into(),
                os_build: "26100.2314".into(),
                ..SystemInfo::default()
            },
            ..EnvironmentReport::default()
        };
        let draft = problem_report_draft(true, &environment, Some("0.8.0"), 2, "a.zip");
        assert_eq!(
            draft.title,
            "Crash report: EVE-O Preview 0.9.0 on Windows 11 Pro 24H2"
        );
        let headings: Vec<&str> = draft.sections.iter().map(|s| s.heading.as_str()).collect();
        assert_eq!(
            headings,
            ["What happened", "Environment", "Previous run", "Diagnostics"]
        );
        assert!(
            draft.sections[2].body.contains("0.8.0") && draft.sections[2].body.contains("Crash reports: 2")
        );
        assert!(draft.sections[3].body.contains("`a.zip`"));
        let manual = problem_report_draft(false, &environment, None, 0, "a.zip");
        assert!(manual.title.starts_with("Problem report:"));
        assert_eq!(manual.sections.len(), 3);
    }
}
