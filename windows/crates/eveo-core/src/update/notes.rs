// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布说明的选取与切块（macOS v1.1 设计 8.2、8.7 节，移植 ReleaseNotes.swift；格式见架构文档 9.7 节）。
//
// Release 正文是 `docs/release-notes/windows/<tag>.md` 的原文：英文在最前，包在 `<!-- lang:en -->` 与 `<!-- /lang:en -->`
// 之间；之后 zh、ja、ko、ru、fr、de、es 各一个可折叠的块，块里是 `<details><summary>…</summary>`、Markdown 正文与 `</details>`。
// `section` 按界面语言取出一段，`blocks` 把它切成标题、列表、段落与代码块，由界面逐块显示。
//
// 与 macOS 相同的、设计没有写明的做法（各有用例）：
// - 有开始标记、没有对应的结束标记时，这一块按不存在处理。
// - 块存在但去掉 `<details>` 与空白行后什么都不剩时，也按不存在处理，改取英文或全文。
// - 编号行与列表行一样允许前面有空格；标题行要从行首开始，`#` 后面要有空格，7 个 `#` 不算标题。
// - 没有结束的代码块一直延续到正文末尾。
// 标记与标签只含 ASCII，查找时在转成 ASCII 小写的副本上找：ASCII 小写不改变字节长度，下标与原文一致。

//! 发布说明的选取与切块。

use crate::model::AppLanguage;
use crate::support::StringEnum;

/// 发布说明里的一块，由 `blocks` 切出。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReleaseNotesBlock {
    /// 标题，level 是 `#` 的个数（1～6）。
    Heading {
        /// `#` 的个数。
        level: usize,
        /// 标题文字。
        text: String,
    },
    /// 段落；原文里相邻的几行用一个空格连起来。
    Paragraph(String),
    /// 无序列表的一项；depth 是缩进的级数，每 2 个空格算一级，从 0 起。
    Bullet {
        /// 缩进的级数。
        depth: usize,
        /// 这一项的文字。
        text: String,
    },
    /// 有序列表的一项；number 是原文写的序号。
    Numbered {
        /// 原文的序号。
        number: i64,
        /// 这一项的文字。
        text: String,
    },
    /// 三个反引号围起来的代码，各行原样保留，用换行连接。
    Code(String),
}

/// 按 8.2 节的约定取出一种语言的正文。
///
/// 1. CRLF 换成 LF。
/// 2. 找 `<!-- lang:<代码> -->` 与它之后第一个 `<!-- /lang:<代码> -->` 之间的文字；标记里的空白可有可无，
///    代码不区分大小写。
/// 3. 界面语言的块存在时取它，否则取 `en` 的块；两块都没有时取整个正文。
/// 4. 取出的文字以 `<details>` 开头时，去掉从 `<details>` 到第一个 `</summary>` 的部分，以及最后一个 `</details>`。
/// 5. 去掉首尾的空白行。
pub fn section(language: AppLanguage, body: &str) -> String {
    let text = normalized_newlines(body);
    let markers = scan_markers(&text);
    // 界面语言在前；界面语言就是英文时只试一次。
    let mut candidates = vec![language.raw()];
    if language != AppLanguage::En {
        candidates.push(AppLanguage::En.raw());
    }
    for code in candidates {
        let Some(raw) = block(code, &markers, &text) else {
            continue;
        };
        let cleaned = trim_blank_lines(&strip_details(raw));
        if !cleaned.is_empty() {
            return cleaned;
        }
    }
    trim_blank_lines(&strip_details(&text))
}

/// 发布说明里平台小节的名字（docs/update-manifest.md 第 4 节第 5 条），与清单里 `latest` 的键一一对应。
pub const PLATFORM_HEADINGS: [&str; 2] = ["macOS", "Windows"];

/// 只留本平台的内容：`section` 取出的一段里，标题正好是另一个平台名（不分大小写）的小节整个去掉，
/// 小节到下一个级别相同或更高的标题为止；本平台的小标题也去掉，只留它下面的内容。
/// 两端都改了的内容写在平台小节之前（如「macOS 与 Windows」），标题不正好是平台名，照常保留。
/// own 是本平台的标题名（`Windows`）。代码块里的 `#` 不算标题。
pub fn platform_only(markdown: &str, own: &str) -> String {
    let mut kept = Vec::new();
    // 正在跳过的平台小节的标题级别；不在跳过时是 None。
    let mut skipping: Option<usize> = None;
    let mut in_code = false;
    for line in markdown.split('\n') {
        if line.trim().starts_with("```") {
            in_code = !in_code;
        } else if !in_code && let Some((level, text)) = heading(line) {
            // 遇到级别相同或更高的标题，跳过的小节结束。
            if skipping.is_some_and(|skip| level <= skip) {
                skipping = None;
            }
            if skipping.is_none()
                && PLATFORM_HEADINGS
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(text))
            {
                // 本平台的小标题只去掉这一行；别的平台连内容一起跳过。
                if !own.eq_ignore_ascii_case(text) {
                    skipping = Some(level);
                }
                continue;
            }
        }
        // 去掉的小节前后各有空行，连在一起时只留一个（代码块里的空行原样保留）。
        let doubled = !in_code
            && line.trim().is_empty()
            && kept.last().is_some_and(|last: &&str| last.trim().is_empty());
        if skipping.is_none() && !doubled {
            kept.push(line);
        }
    }
    trim_blank_lines(&kept.join("\n"))
}

/// 标题行的级别与文字（去掉首尾空白）；不是标题时返回 None。规则与 `blocks` 相同。
fn heading(line: &str) -> Option<(usize, &str)> {
    let hashes = line.bytes().take_while(|&b| b == b'#').count();
    let rest = line.get(hashes..)?;
    ((1..=6).contains(&hashes) && rest.starts_with(' ')).then(|| (hashes, rest.trim()))
}

/// 把取出的那段文字按行切成块（8.7 节的表）。
///
/// | 行的形式 | 块 |
/// | --- | --- |
/// | 以 1～6 个 `#` 加空格开头 | `Heading` |
/// | 以 `-`、`*` 或 `+` 加空格开头，前面有 0 个或多个空格 | `Bullet`，每 2 个空格算一级 |
/// | 以数字加 `.` 加空格开头（前面可以有空格） | `Numbered` |
/// | 三个反引号围起来的各行 | `Code` |
/// | 空行 | 结束当前段落 |
/// | 其他 | 并入当前 `Paragraph`，行与行之间加一个空格 |
pub fn blocks(markdown: &str) -> Vec<ReleaseNotesBlock> {
    let mut builder = BlockBuilder::default();
    for line in normalized_newlines(markdown).split('\n') {
        builder.consume(line);
    }
    builder.finish()
}

/// CRLF 与单独的 CR 都换成 LF。
fn normalized_newlines(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

/// 正文里的一个语言标记：`<!-- lang:xx -->` 或 `<!-- /lang:xx -->`。
struct Marker {
    /// 标记在正文里的字节范围，从 `<!--` 到 `-->`。
    start: usize,
    /// 标记结束处（`-->` 之后）的字节位置。
    end: usize,
    /// 语言代码，已转成小写。
    code: String,
    /// 是否是结束标记（`/lang:`）。
    closing: bool,
}

/// 取 code 的第一个开始标记与它之后第一个同代码的结束标记之间的文字；任何一个找不到时返回 None。
fn block<'a>(code: &str, markers: &[Marker], text: &'a str) -> Option<&'a str> {
    let open = markers.iter().find(|m| !m.closing && m.code == code)?;
    let close = markers
        .iter()
        .find(|m| m.closing && m.code == code && m.start >= open.end)?;
    Some(&text[open.end..close.start])
}

/// 按出现的先后列出正文里全部的语言标记。别的 HTML 注释不算标记。
///
/// 宽松的写法：`<!--` 之后、`-->` 之前，以及 `/`、`lang`、`:` 两侧的空白都可有可无；`lang` 与代码不区分大小写。
fn scan_markers(text: &str) -> Vec<Marker> {
    let mut result = Vec::new();
    let mut search = 0;
    while let Some(found) = text[search..].find("<!--") {
        let open = search + found;
        match parse_marker(text, open) {
            Some(marker) => {
                search = marker.end;
                result.push(marker);
            }
            None => search = open + 4,
        }
    }
    result
}

/// 从一个 `<!--` 起解析标记；不是语言标记时返回 None。
fn parse_marker(text: &str, open: usize) -> Option<Marker> {
    let bytes = text.as_bytes();
    let mut index = skip_whitespace(text, open + 4);
    let closing = bytes.get(index) == Some(&b'/');
    if closing {
        index = skip_whitespace(text, index + 1);
    }
    if !bytes.get(index..index + 4)?.eq_ignore_ascii_case(b"lang") {
        return None;
    }
    index = skip_whitespace(text, index + 4);
    if bytes.get(index) != Some(&b':') {
        return None;
    }
    index = skip_whitespace(text, index + 1);
    // 代码由 ASCII 字母与数字组成，中间可以有 `-`（如 `zh-hans`）。`-` 后面不是字母或数字时停下，
    // 否则 `<!--lang:en-->` 里的 `-->` 会被当成代码的一部分。
    let code_start = index;
    while index < bytes.len() {
        let next_is_code = bytes.get(index + 1).is_some_and(u8::is_ascii_alphanumeric);
        if bytes[index].is_ascii_alphanumeric() || (bytes[index] == b'-' && next_is_code) {
            index += 1;
        } else {
            break;
        }
    }
    if index == code_start {
        return None;
    }
    let code = text[code_start..index].to_ascii_lowercase();
    index = skip_whitespace(text, index);
    if !text[index..].starts_with("-->") {
        return None;
    }
    Some(Marker {
        start: open,
        end: index + 3,
        code,
        closing,
    })
}

/// 跳过空白（含换行），返回第一个非空白字符的字节位置。
fn skip_whitespace(text: &str, start: usize) -> usize {
    text[start..]
        .char_indices()
        .find(|(_, c)| !c.is_whitespace())
        .map_or(text.len(), |(offset, _)| start + offset)
}

/// 文字以 `<details>` 开头（前面允许有空白）时，去掉从它到第一个 `</summary>` 的部分，以及最后一个 `</details>`。
/// 没有 `</summary>` 时只去掉 `<details>` 这个标签本身。标签不区分大小写，`<details open>` 也算。
fn strip_details(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let start = skip_whitespace(text, 0);
    let after_tag = start + "<details".len();
    let opens_details = lower[start..].starts_with("<details")
        && text[after_tag..]
            .chars()
            .next()
            .is_some_and(|c| c == '>' || c.is_whitespace());
    let Some(open_end) = opens_details
        .then(|| lower[after_tag..].find('>').map(|i| after_tag + i + 1))
        .flatten()
    else {
        return text.to_owned();
    };
    let body_start = lower[open_end..]
        .find("</summary>")
        .map_or(open_end, |i| open_end + i + "</summary>".len());
    let mut result = text[body_start..].to_owned();
    if let Some(close) = result.to_ascii_lowercase().rfind("</details>") {
        result.replace_range(close..close + "</details>".len(), "");
    }
    result
}

/// 去掉开头和末尾只含空白的行；中间的行原样保留。
fn trim_blank_lines(text: &str) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    let blank = |line: &&str| line.chars().all(char::is_whitespace);
    let (Some(first), Some(last)) = (
        lines.iter().position(|l| !blank(l)),
        lines.iter().rposition(|l| !blank(l)),
    ) else {
        return String::new();
    };
    lines[first..=last].join("\n")
}

/// `blocks` 的逐行状态：当前段落的行、是否在代码块里。
#[derive(Default)]
struct BlockBuilder {
    /// 已切出的块。
    blocks: Vec<ReleaseNotesBlock>,
    /// 当前段落已收的行（已去掉首尾空白）。
    paragraph: Vec<String>,
    /// 在代码块里时是已收的行；不在代码块里时是 None。
    code: Option<Vec<String>>,
}

impl BlockBuilder {
    /// 处理一行（不含换行符）。
    fn consume(&mut self, line: &str) {
        let trimmed = line.trim();
        if let Some(code) = &mut self.code {
            // 代码块里的行原样保留，`#` 与 `-` 都不解释；遇到下一个三个反引号时结束。
            if trimmed.starts_with("```") {
                self.blocks.push(ReleaseNotesBlock::Code(code.join("\n")));
                self.code = None;
            } else {
                code.push(line.to_owned());
            }
            return;
        }
        if trimmed.starts_with("```") {
            self.flush_paragraph();
            self.code = Some(Vec::new());
        } else if trimmed.is_empty() {
            self.flush_paragraph();
        } else if let Some(block) = list_or_heading(line) {
            self.flush_paragraph();
            self.blocks.push(block);
        } else {
            self.paragraph.push(trimmed.to_owned());
        }
    }

    /// 收尾：结束当前段落；没有结束的代码块延续到正文末尾。
    fn finish(mut self) -> Vec<ReleaseNotesBlock> {
        self.flush_paragraph();
        if let Some(lines) = self.code.take() {
            self.blocks.push(ReleaseNotesBlock::Code(lines.join("\n")));
        }
        self.blocks
    }

    /// 把当前段落的行用一个空格连起来，作为一个段落块。
    fn flush_paragraph(&mut self) {
        if !self.paragraph.is_empty() {
            self.blocks
                .push(ReleaseNotesBlock::Paragraph(self.paragraph.join(" ")));
            self.paragraph.clear();
        }
    }
}

/// 标题、无序列表或有序列表的一行；都不是时返回 None。
fn list_or_heading(line: &str) -> Option<ReleaseNotesBlock> {
    let chars: Vec<char> = line.chars().collect();
    let rest = |from: usize| chars[from..].iter().collect::<String>().trim().to_owned();
    // 标题：从行首起 1～6 个 `#`，后面紧跟空格。
    let hashes = chars.iter().take_while(|&&c| c == '#').count();
    if (1..=6).contains(&hashes) && chars.get(hashes) == Some(&' ') {
        return Some(ReleaseNotesBlock::Heading {
            level: hashes,
            text: rest(hashes + 1),
        });
    }
    let indent = chars.iter().take_while(|&&c| c == ' ').count();
    // 无序列表：缩进之后是 `-`、`*` 或 `+`，后面紧跟空格。`**粗体**` 开头的行不算。
    if chars.get(indent).is_some_and(|c| "-*+".contains(*c)) && chars.get(indent + 1) == Some(&' ') {
        return Some(ReleaseNotesBlock::Bullet {
            depth: indent / 2,
            text: rest(indent + 2),
        });
    }
    // 有序列表：缩进之后是数字、`.` 与空格。数字超出 i64 时按普通段落处理。
    let digits = chars[indent..].iter().take_while(|c| c.is_ascii_digit()).count();
    let dot = indent + digits;
    if digits > 0 && chars.get(dot) == Some(&'.') && chars.get(dot + 1) == Some(&' ') {
        let number: i64 = chars[indent..dot].iter().collect::<String>().parse().ok()?;
        return Some(ReleaseNotesBlock::Numbered {
            number,
            text: rest(dot + 2),
        });
    }
    None
}

#[cfg(test)]
#[path = "notes_tests.rs"]
mod tests;
