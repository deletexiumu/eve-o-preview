// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的脱敏，对应 macOS 的 Redactor.swift（v1.1 设计 7.3 节）：把用户名、主机名、角色名换成占位符，
// 把崩溃报告里的设备标识换成 `[redacted]`。脱敏始终开启，适用于报告里每个文件的内容与 Issue 的标题和正文。
//
// 匹配规则（与 macOS 相同）：
// 1. 一次扫描完成。每个位置试全部的词，取能匹配的最长的一个，输出占位符，再从匹配的末尾继续。
//    替换后的文字不再参与匹配，所以名叫 `user` 的角色不会破坏已输出的 `[user]`。
// 2. 不区分大小写。
// 3. 只由 ASCII 字符组成的词要求两侧是边界：前后字符都不是 ASCII 字母或数字。含非 ASCII 字符的词不要求边界。
// 4. 去掉首尾空白后不足 3 个字符的 ASCII 词，只在紧跟用户目录的父目录时替换；不足 2 个字符的非 ASCII 词不替换。
//    Windows 上父目录写作 `\Users\`、JSON 里的 `\\Users\\` 或 `/Users/`。
// 5. 用户目录（如 `C:\Users\Alice`）同时匹配原样的与 JSON 转义的（每个 `\` 写成 `\\`）两种写法，
//    以及 `/` 分隔的写法，换成 `%USERPROFILE%`（与日志的写法相同）。
// 6. 设备标识按 `"键" : "值"` 匹配，冒号两侧的空白可有可无，只替换值。
// 7. 每个词同时按 NFC 与 NFD 两种写法匹配。
//
// 实现：文字转成 char 数组，逐个字符做小写折叠（只取一对一的映射，下标不变）；词按折叠后的前两个字符分桶，
// 桶内按长度从长到短试。日志有几 MiB，这样每个位置只试开头相同的几个词。

//! 问题报告的脱敏。

use std::collections::{BTreeSet, HashMap, HashSet};

use unicode_normalization::UnicodeNormalization;

/// 要替换的词。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RedactionTerms {
    /// Windows 用户名与全名。
    pub user_names: Vec<String>,
    /// 计算机名（NetBIOS 名与 DNS 主机名）。
    pub host_names: Vec<String>,
    /// 角色名。
    pub character_names: Vec<String>,
    /// 用户目录，如 `C:\Users\Alice`。
    pub home_directory: Option<String>,
}

/// 按类别统计的替换次数。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RedactionCounts {
    /// 用户名与用户目录。
    pub user: usize,
    /// 计算机名。
    pub host: usize,
    /// 角色名。
    pub character: usize,
    /// 设备标识。
    pub identifier: usize,
}

impl RedactionCounts {
    /// 合计次数。
    pub fn total(&self) -> usize {
        self.user + self.host + self.character + self.identifier
    }
}

impl std::ops::Add for RedactionCounts {
    type Output = Self;

    /// 按类别相加。
    fn add(self, other: Self) -> Self {
        Self {
            user: self.user + other.user,
            host: self.host + other.host,
            character: self.character + other.character,
            identifier: self.identifier + other.identifier,
        }
    }
}

/// 词的类别，决定计入哪一项次数。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Category {
    /// 用户名与用户目录。
    User,
    /// 计算机名。
    Host,
    /// 角色名。
    Character,
}

/// 一个要匹配的词。
#[derive(Debug, Clone)]
struct Term {
    /// 折叠后的字符，用来比较。
    folded: Vec<char>,
    /// 输出的占位符。
    replacement: String,
    /// 类别。
    category: Category,
    /// 是否要求两侧是边界（只由 ASCII 组成的词）。
    requires_boundary: bool,
    /// 是否只在紧跟用户目录的父目录时替换（不足 3 个字符的 ASCII 词）。
    path_only: bool,
}

/// 脱敏器。建好后可在任何线程使用。
#[derive(Debug, Clone)]
pub struct Redactor {
    /// 至少 2 个字符的词，按折叠后的前两个字符分桶，桶内从长到短。
    pair_buckets: HashMap<(char, char), Vec<Term>>,
    /// 只有 1 个字符的词，按这个字符分桶。
    single_buckets: HashMap<char, Vec<Term>>,
    /// 折叠后的角色名（NFC）→ 占位符。
    character_placeholders: HashMap<String, String>,
}

/// 用户名的占位符。
pub const USER_PLACEHOLDER: &str = "[user]";
/// 计算机名的占位符。
pub const HOST_PLACEHOLDER: &str = "[host]";
/// 设备标识的占位符。
pub const IDENTIFIER_PLACEHOLDER: &str = "[redacted]";
/// 用户目录的替换结果。
pub const HOME_PLACEHOLDER: &str = "%USERPROFILE%";
/// 要替换值的 JSON 键（崩溃报告里的设备标识）。
const IDENTIFIER_KEYS: [&str; 2] = ["crashReporterKey", "deviceIdentifierForVendor"];
/// 用户目录的父目录的几种写法（已折叠成小写），不足 3 个字符的 ASCII 词只在它们后面替换。
const PROFILE_PARENTS: [&str; 3] = ["\\users\\", "\\\\users\\\\", "/users/"];

impl Redactor {
    /// 用词表建脱敏器。空白的词被忽略；同一个词（不区分大小写）出现在多个类别时，按用户名、计算机名、角色名的顺序取第一个。
    pub fn new(terms: &RedactionTerms) -> Self {
        // seen 按折叠后的字符去重：同一个词的大小写、规范化写法只留一份，先到的类别为准。
        let mut seen: HashSet<Vec<char>> = HashSet::new();
        // list 是全部要匹配的词，最后按开头的字符分桶。
        let mut list: Vec<Term> = Vec::new();
        // 用户目录：原样、JSON 转义、`/` 分隔三种写法。
        if let Some(home) = terms.home_directory.as_deref().map(str::trim)
            && home.chars().count() > 3
        {
            let trimmed = home.trim_end_matches(['\\', '/']);
            let forms = [
                trimmed.to_owned(),
                trimmed.replace('\\', "\\\\"),
                trimmed.replace('\\', "/"),
            ];
            for form in forms {
                append(
                    &form,
                    HOME_PLACEHOLDER,
                    Category::User,
                    false,
                    &mut list,
                    &mut seen,
                );
            }
        }
        for name in &terms.user_names {
            append(name, USER_PLACEHOLDER, Category::User, true, &mut list, &mut seen);
        }
        for name in &terms.host_names {
            append(name, HOST_PLACEHOLDER, Category::Host, true, &mut list, &mut seen);
        }
        // 角色名按折叠后的名字排序后从 1 起编号，同一份报告里序号稳定。不会被替换的名字（过短）不占序号。
        let mut characters: BTreeSet<(String, String)> = BTreeSet::new();
        let mut keys: HashSet<String> = HashSet::new();
        for raw in &terms.character_names {
            let name = raw.trim();
            let key = folded_string(&name.nfc().collect::<String>());
            if is_eligible(name) && keys.insert(key.clone()) {
                characters.insert((key, name.to_owned()));
            }
        }
        let mut character_placeholders = HashMap::new();
        for (index, (key, name)) in characters.into_iter().enumerate() {
            let placeholder = format!("[character-{}]", index + 1);
            append(
                &name,
                &placeholder,
                Category::Character,
                true,
                &mut list,
                &mut seen,
            );
            character_placeholders.insert(key, placeholder);
        }
        // 分桶：每个位置只试开头两个字符相同的词；只有一个字符的词另放一桶（只可能是路径里的短用户名）。
        let mut pair_buckets: HashMap<(char, char), Vec<Term>> = HashMap::new();
        let mut single_buckets: HashMap<char, Vec<Term>> = HashMap::new();
        for term in list {
            match term.folded.as_slice() {
                [first, second, ..] => pair_buckets.entry((*first, *second)).or_default().push(term),
                [only] => single_buckets.entry(*only).or_default().push(term),
                [] => {}
            }
        }
        // 桶内从长到短：找到的第一个就是最长的匹配。
        for bucket in pair_buckets.values_mut() {
            bucket.sort_by_key(|t| std::cmp::Reverse(t.folded.len()));
        }
        Self {
            pair_buckets,
            single_buckets,
            character_placeholders,
        }
    }

    /// 角色名的占位符，如 `[character-2]`；不在词表里时为 None。
    pub fn placeholder_for_character(&self, name: &str) -> Option<&str> {
        let key = folded_string(&name.trim().nfc().collect::<String>());
        self.character_placeholders.get(&key).map(String::as_str)
    }

    /// 脱敏一段文字，返回结果与按类别的替换次数。
    pub fn redact(&self, text: &str) -> (String, RedactionCounts) {
        // source 是原文的字符，folded 是逐个折叠后的字符，两者下标一一对应：
        // 在 folded 上比较，从 source 上照抄，原文的大小写与写法都保留。
        let source: Vec<char> = text.chars().collect();
        let folded: Vec<char> = source.iter().map(|&c| fold(c)).collect();
        let mut output = String::with_capacity(text.len());
        let mut counts = RedactionCounts::default();
        // index 是正在试的位置；copied_from 之前的原文已写进 output。
        let mut index = 0;
        let mut copied_from = 0;
        while index < source.len() {
            // 没有匹配就看下一个位置；没匹配的原文攒着，遇到匹配或到末尾时一次照抄。
            let Some(found) = self.find(index, &source, &folded) else {
                index += 1;
                continue;
            };
            // 匹配前的原文照抄（设备标识还包括键与开头的引号），再写占位符。
            output.extend(&source[copied_from..found.keep_until]);
            output.push_str(&found.replacement);
            match found.category {
                None => counts.identifier += 1,
                Some(Category::User) => counts.user += 1,
                Some(Category::Host) => counts.host += 1,
                Some(Category::Character) => counts.character += 1,
            }
            index = found.end;
            copied_from = index;
        }
        output.extend(&source[copied_from..]);
        (output, counts)
    }

    /// 在 index 处找一个匹配：先试设备标识，再试最长的词。
    fn find(&self, index: usize, source: &[char], folded: &[char]) -> Option<Found> {
        // 设备标识以键的引号开头；它只替换值，与词的匹配互不重叠。
        if source[index] == '"'
            && let Some(found) = identifier_match(index, source)
        {
            return Some(found);
        }
        let pair = folded
            .get(index + 1)
            .and_then(|&next| self.pair_buckets.get(&(folded[index], next)));
        let single = self.single_buckets.get(&folded[index]);
        // 长的词都在两个字符的桶里，先试它们，再试单个字符的词，保持「最长优先」。
        let mut candidates = pair.into_iter().flatten().chain(single.into_iter().flatten());
        candidates
            .find(|term| matches(term, index, source, folded))
            .map(|term| Found {
                keep_until: index,
                end: index + term.folded.len(),
                replacement: term.replacement.clone(),
                category: Some(term.category),
            })
    }
}

/// 一次匹配的结果。
struct Found {
    /// 原文从当前位置到 keep_until 之前的部分照抄（设备标识只替换值，键和引号照抄）。
    keep_until: usize,
    /// 匹配结束的位置（不含）。
    end: usize,
    /// 输出的占位符。
    replacement: String,
    /// 类别；设备标识是 None。
    category: Option<Category>,
}

/// 把一个词的原样、NFC、NFD 三种写法加进列表（相同的只加一次）。path_rule：是否对短 ASCII 词套用路径规则。
fn append(
    raw: &str,
    replacement: &str,
    category: Category,
    path_rule: bool,
    list: &mut Vec<Term>,
    seen: &mut HashSet<Vec<char>>,
) {
    // 首尾空白不算词的一部分（配置里的名字可能带空格）。
    let word = raw.trim();
    if !is_eligible(word) {
        return;
    }
    let ascii = word.is_ascii();
    let forms = [
        word.to_owned(),
        word.nfc().collect(),
        word.nfd().collect::<String>(),
    ];
    for form in forms {
        let folded: Vec<char> = form.chars().map(fold).collect();
        if seen.insert(folded.clone()) {
            list.push(Term {
                folded,
                replacement: replacement.to_owned(),
                category,
                requires_boundary: ascii,
                path_only: path_rule && ascii && word.chars().count() < 3,
            });
        }
    }
}

/// 词 term 能否在 index 处匹配：折叠后的字符相同，并满足边界与路径规则。
fn matches(term: &Term, index: usize, source: &[char], folded: &[char]) -> bool {
    // 先比字符：桶只保证前两个字符相同，其余的在这里比。
    let end = index + term.folded.len();
    if end > folded.len() || folded[index..end] != term.folded[..] {
        return false;
    }
    if term.requires_boundary {
        if index > 0 && source[index - 1].is_ascii_alphanumeric() {
            return false;
        }
        if end < source.len() && source[end].is_ascii_alphanumeric() {
            return false;
        }
    }
    // 短的 ASCII 词（如两个字母的用户名）在正文里太容易误中，只认路径里用户目录那一段。
    if term.path_only {
        return PROFILE_PARENTS
            .iter()
            .any(|parent| follows(parent, index, folded));
    }
    true
}

/// index 处是否是 `"crashReporterKey" : "值"` 一类的设备标识；是时返回只替换值的匹配。
fn identifier_match(index: usize, source: &[char]) -> Option<Found> {
    for key in IDENTIFIER_KEYS {
        let quoted: Vec<char> = format!("\"{key}\"").chars().collect();
        if source.get(index..index + quoted.len()) != Some(&quoted[..]) {
            continue;
        }
        let mut cursor = skip_spaces(index + quoted.len(), source);
        if source.get(cursor) != Some(&':') {
            return None;
        }
        cursor = skip_spaces(cursor + 1, source);
        if source.get(cursor) != Some(&'"') {
            return None;
        }
        let value_start = cursor + 1;
        // 找到没有被反斜杠转义的结束引号。
        let mut value_end = value_start;
        while value_end < source.len() && source[value_end] != '"' {
            value_end += if source[value_end] == '\\' { 2 } else { 1 };
        }
        if value_end >= source.len() {
            return None;
        }
        return Some(Found {
            keep_until: value_start,
            end: value_end,
            replacement: IDENTIFIER_PLACEHOLDER.to_owned(),
            category: None,
        });
    }
    None
}

/// 词（已去掉首尾空白）能否参与替换：不为空；含非 ASCII 字符时至少 2 个字符。
fn is_eligible(word: &str) -> bool {
    !word.is_empty() && (word.is_ascii() || word.chars().count() >= 2)
}

/// 跳过空格、制表符与换行。
fn skip_spaces(start: usize, source: &[char]) -> usize {
    let mut cursor = start;
    while source
        .get(cursor)
        .is_some_and(|c| matches!(c, ' ' | '\t' | '\n' | '\r'))
    {
        cursor += 1;
    }
    cursor
}

/// folded 里 index 之前的部分是否以 prefix（已是小写）结尾。
fn follows(prefix: &str, index: usize, folded: &[char]) -> bool {
    let chars: Vec<char> = prefix.chars().collect();
    index >= chars.len() && folded[index - chars.len()..index] == chars[..]
}

/// 一个字符的小写折叠。只取一对一的映射，保证折叠前后下标对应；一对多的字符保持原样。
fn fold(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }
    // 例如土耳其语的 İ 小写是两个字符，保持原样；这类字符在名字里极少见。
    let mut lower = c.to_lowercase();
    match (lower.next(), lower.next()) {
        (Some(only), None) => only,
        _ => c,
    }
}

/// 整个字符串的折叠，用作去重与查找的键。
fn folded_string(text: &str) -> String {
    text.chars().map(fold).collect()
}

/// 全部配置方案里出现过的角色名，加上在线客户端的角色名：去掉首尾空白、去掉空的、区分大小写地去重，按名字排序。
/// 不区分大小写的合并由 [`Redactor`] 做。来源：每个配置方案的布局、隐藏名单、高亮颜色、角色热键的键与循环组成员。
pub fn character_names(config: &crate::model::AppConfig, online: &[String]) -> Vec<String> {
    let mut names: BTreeSet<String> = BTreeSet::new();
    let mut add = |name: &String| {
        let trimmed = name.trim();
        if !trimmed.is_empty() {
            names.insert(trimmed.to_owned());
        }
    };
    for profile in &config.profiles {
        profile.layouts.keys().for_each(&mut add);
        profile.hidden_characters.iter().for_each(&mut add);
        profile.highlight_colors.keys().for_each(&mut add);
        profile.character_hotkeys.keys().for_each(&mut add);
        profile
            .cycle_groups
            .iter()
            .flat_map(|g| &g.members)
            .for_each(&mut add);
    }
    online.iter().for_each(&mut add);
    names.into_iter().collect()
}

#[cfg(test)]
#[path = "redactor_tests.rs"]
mod tests;
