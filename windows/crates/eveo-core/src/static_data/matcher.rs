// SPDX-License-Identifier: GPL-3.0-or-later
//
// 术语匹配，对应 macOS 的 TermMatcher.swift（设计文档 6.3 节）：在聊天正文里找星系、星域、舰船、舰船分组与情报用语。
//
// 索引：每个术语的每个名称（英文名与各语言名称）各建一个键。含汉字、假名或谚文的名称建「字符键」（原样，
// 2 个字符以上）；其余名称建「词键」（切成小写的词，用一个空格连接）。舰船缩写、情报用语另建键。
// 同一个键对应多个术语时，按「舰船、舰船分组、星域、星系、情报用语」的顺序取第一个；星系之间重名时
// 已知空间优先，再取 ID 小的（同 EveStaticData::system_named）。
//
// 扫描：先在每个汉字、假名、谚文的位置上试最长的字符键；再在剩下的文字里取词，从每个词起试连续的 1～6 个词
// （两个词之间只隔一个空格或引号才算连续），最长的先试；查不到时把最后一个词的 es 或 s 去掉再查。
// 只有一个词的匹配另有两条限制（6.3 节第 4、5 条），见 passes_single_word_rules。匹配后紧跟的 `*` 并入范围。
//
// 字符键的边界：字符键本身不看边界，以下两类另有要求，见 passes_boundary。
// - 中文情报用语（安全、无人）：前面 2 个字符里没有否定字，后面不紧跟汉字、假名或谚文。
//   「不安全」「不太安全」「无人机」「安全等级」因此不认作「安全」；「非常」不算否定。
// - COMMON_WORD_LOCALIZED_NAMES 里的译名（是日常中文词的星系与星域名，如「出口」「地窖」）：
//   后面紧跟 `*`，或前后都不紧挨汉字、假名、谚文时才算匹配。音译名照常不看边界。
//
// 第 5 条（3 个以内的 ASCII 字母、或在 AMBIGUOUS_SHORT_NAMES 里的词要首字母大写或带 `*`）的三处例外：
// 情报用语不受限；舰船缩写表的词不受限；舰船与舰船分组不受限，但命中的键在 CASE_SENSITIVE_SHIP_NAMES
// 或 AMBIGUOUS_SHORT_NAMES 里时仍受限。
//
// Swift 按字素（Character）切文字，这里按 Unicode 码位（char）切；聊天里的名称不含组合字符，结果相同。
// 匹配的范围是原文的字节下标，可以直接切原文。

//! 在聊天正文里找星系、星域、舰船、舰船分组与情报用语。

use std::collections::{BTreeMap, HashMap};
use std::ops::Range;

use super::lexicon::{
    AMBIGUOUS_SHORT_NAMES, CASE_SENSITIVE_SHIP_NAMES, CJK_NEGATION_LOOK_BACK, CJK_NEGATIONS, CLEAR_WORDS,
    COMMON_WORD_LOCALIZED_NAMES, NO_VISUAL_WORDS, SHIP_ALIASES, is_cjk, is_stop_word, is_word_character,
    is_word_joiner, is_word_link, word_key,
};
use super::{Localized, NamedRecord, ShipName, SolarSystem, SpaceKind};
use crate::model::AppLanguage;
use crate::support::StringEnum;

/// 情报用语。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IntelWord {
    /// 安全（clr、clear）。
    Clear,
    /// 未见（nv、no visual）。
    NoVisual,
}

/// 一个术语的种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TermKind {
    /// 星系，关联值是星系 ID。
    System(i64),
    /// 星域，关联值是星域 ID。
    Region(i64),
    /// 舰船，关联值是舰船类型 ID。
    Ship(i64),
    /// 舰船分组，关联值是分组 ID。
    ShipGroup(i64),
    /// 情报用语。
    IntelWord(IntelWord),
}

/// 正文里的一处术语。
#[derive(Debug, Clone, PartialEq)]
pub struct TermMatch {
    /// 在原文里的字节范围，含名称后面的 `*`。
    pub range: Range<usize>,
    /// 种类。
    pub kind: TermKind,
    /// 英文名；情报用语是它的规范写法。
    pub english: String,
    /// 与英文不同的其他语言名称，键是语言代码。
    pub localized: Localized,
}

impl TermMatch {
    /// 某种语言下的名称；没有译名时取英文名。
    pub fn name_in(&self, language: AppLanguage) -> &str {
        self.localized.get(language.raw()).unwrap_or(&self.english)
    }
}

/// 字符键的边界要求（文件头的「字符键的边界」）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Boundary {
    /// 不看边界。
    Free,
    /// 中文情报用语：前面不是否定字，后面不紧跟汉字、假名或谚文。
    IntelWord,
    /// 是日常词的星系与星域的译名：后面紧跟 `*`，或前后都不紧挨汉字、假名或谚文。
    CommonWord,
}

/// 索引里的一个术语。
#[derive(Debug, Clone)]
struct Entry {
    /// 种类。
    kind: TermKind,
    /// 英文名；情报用语是它的规范写法。
    english: String,
    /// 其他语言的名称。
    localized: Localized,
    /// 重名时的先后：舰船 0、舰船分组 1、星域 2、星系 3、情报用语 4，小的优先。
    rank: u8,
    /// 星系是否在已知空间；其他种类为假。
    is_known_space: bool,
    /// 术语的 ID，同种类重名时取小的。
    id: i64,
    /// 这个键来自舰船缩写表；不受扫描第 5 条的限制。
    is_alias: bool,
    /// 作为字符键匹配时的边界要求。
    boundary: Boundary,
}

impl Entry {
    /// 舰船或舰船分组的一项。
    fn ship(ship: &ShipName, is_alias: bool) -> Self {
        let (kind, rank) = match ship.group_id {
            Some(_) => (TermKind::Ship(ship.id), 0),
            None => (TermKind::ShipGroup(ship.id), 1),
        };
        Self {
            kind,
            english: ship.name.clone(),
            localized: ship.localized.clone(),
            rank,
            is_known_space: false,
            id: ship.id,
            is_alias,
            boundary: Boundary::Free,
        }
    }

    /// 是舰船或舰船分组。
    fn is_ship_kind(&self) -> bool {
        matches!(self.kind, TermKind::Ship(_) | TermKind::ShipGroup(_))
    }
}

/// 一个词在原文里的位置（字符下标，左闭右开）。
#[derive(Debug, Clone)]
struct Word {
    /// 起点。
    start: usize,
    /// 终点。
    end: usize,
    /// 小写形式。
    lower: String,
    /// 原文的首字符。
    first: char,
}

/// 一处匹配：字符下标的范围与术语在 entries 里的下标。
type Found = (usize, usize, usize);

/// 至多看几个连续的词。
const MAX_TERM_WORDS: usize = 6;

/// 术语匹配器。由 `EveStaticData` 在解码时建立，之后只读，可在任何线程使用。
#[derive(Debug, Default)]
pub struct TermMatcher {
    /// 全部术语；键里存下标。
    entries: Vec<Entry>,
    /// 字符键（小写）→ 术语下标与这个键的边界要求。
    character_keys: HashMap<String, (usize, Boundary)>,
    /// 字符键的首字符（小写）→ 以它开头的字符键的长度（字符数），从长到短。
    character_key_lengths: HashMap<char, Vec<usize>>,
    /// 词键 → 术语下标。
    word_keys: HashMap<String, usize>,
}

impl TermMatcher {
    /// 用全部星系、星域、舰船与舰船分组建索引，另收舰船缩写与情报用语。
    pub fn new(systems: &[SolarSystem], regions: &[NamedRecord], ships: &[ShipName]) -> Self {
        let mut matcher = Self::default();
        for ship in ships {
            matcher.add(names(&ship.name, &ship.localized), Entry::ship(ship, false));
        }
        for region in regions {
            let localized = region.l.clone().unwrap_or_default();
            let entry = Entry {
                kind: TermKind::Region(region.i),
                english: region.n.clone(),
                localized: localized.clone(),
                rank: 2,
                is_known_space: false,
                id: region.i,
                is_alias: false,
                boundary: Boundary::Free,
            };
            matcher.add(names(&region.n, &localized), entry);
        }
        for system in systems {
            let entry = Entry {
                kind: TermKind::System(system.id),
                english: system.name.clone(),
                localized: system.localized.clone(),
                rank: 3,
                is_known_space: system.kind == SpaceKind::Known,
                id: system.id,
                is_alias: false,
                boundary: Boundary::Free,
            };
            matcher.add(names(&system.name, &system.localized), entry);
        }
        // 缩写与情报用语最后加：重名时按 rank 与 is_alias 决定，不会盖掉真名。
        matcher.add_aliases(ships);
        matcher.add_intel_words();
        // 每个首字符只试存在的键长，从长到短，扫描时不必逐个长度去查。
        let mut lengths: HashMap<char, Vec<usize>> = HashMap::new();
        for key in matcher.character_keys.keys() {
            if let Some(first) = key.chars().next() {
                lengths.entry(first).or_default().push(key.chars().count());
            }
        }
        for list in lengths.values_mut() {
            list.sort_unstable_by(|a, b| b.cmp(a));
            list.dedup();
        }
        matcher.character_key_lengths = lengths;
        matcher
    }

    /// 文字里出现的术语，按位置排序，互不重叠。
    pub fn matches(&self, text: &str) -> Vec<TermMatch> {
        if text.is_empty() || (self.character_keys.is_empty() && self.word_keys.is_empty()) {
            return Vec::new();
        }
        // 按字符扫描；covered 记下已被匹配盖住的字符，两步扫描的结果互不重叠。
        let chars: Vec<char> = text.chars().collect();
        // 字符下标 → 原文的字节下标，多一项是文字的长度。范围都换回原文的下标，翻译按它切原文。
        let offsets: Vec<usize> = text
            .char_indices()
            .map(|(offset, _)| offset)
            .chain(std::iter::once(text.len()))
            .collect();
        let mut covered = vec![false; chars.len()];
        let mut found = Vec::new();
        self.scan_character_keys(&chars, &mut covered, &mut found);
        self.scan_word_keys(&chars, &mut covered, &mut found);
        found.sort_by_key(|f| f.0);
        found
            .into_iter()
            .map(|(start, end, index)| {
                let entry = &self.entries[index];
                TermMatch {
                    range: offsets[start]..offsets[end],
                    kind: entry.kind,
                    english: entry.english.clone(),
                    localized: entry.localized.clone(),
                }
            })
            .collect()
    }

    // MARK: 扫描

    /// 扫描第 1 步：在每个汉字、假名或谚文的位置上试最长的字符键，匹配后跳到匹配的末尾。
    /// 不满足边界要求的键跳过，接着试更短的键；都不行时这个位置不算匹配，也不盖住。
    fn scan_character_keys(&self, chars: &[char], covered: &mut [bool], found: &mut Vec<Found>) {
        let mut index = 0;
        while index < chars.len() {
            let lengths = is_cjk(chars[index])
                .then(|| chars[index].to_lowercase().next())
                .flatten()
                .and_then(|first| self.character_key_lengths.get(&first));
            let Some(lengths) = lengths else {
                index += 1;
                continue;
            };
            let mut matched_end = None;
            for &length in lengths.iter().filter(|&&l| index + l <= chars.len()) {
                let key = chars[index..index + length]
                    .iter()
                    .collect::<String>()
                    .to_lowercase();
                let Some(&(entry, boundary)) = self.character_keys.get(&key) else {
                    continue;
                };
                if !passes_boundary(boundary, chars, index, index + length) {
                    continue;
                }
                let end = extend_over_stars(chars, index + length, covered);
                found.push((index, end, entry));
                matched_end = Some(end);
                break;
            }
            if let Some(end) = matched_end {
                covered[index..end].fill(true);
                index = end;
            } else {
                index += 1;
            }
        }
    }

    /// 扫描第 2～5 步：在没被字符键盖住的文字里取词，从每个词起试连续的 1～6 个词，最长的先试。
    fn scan_word_keys(&self, chars: &[char], covered: &mut [bool], found: &mut Vec<Found>) {
        let words = words(chars, covered);
        if words.is_empty() {
            return;
        }
        // linked[i]：第 i 个词与第 i+1 个词之间只隔一个空格或一个引号。
        let mut linked = vec![false; words.len()];
        for i in 0..words.len() - 1 {
            let gap = words[i + 1].start - words[i].end;
            let between = words[i].end;
            linked[i] = gap == 1 && !covered[between] && is_word_link(chars[between]);
        }
        let mut i = 0;
        while i < words.len() {
            let mut run = 1;
            while run < MAX_TERM_WORDS && i + run < words.len() && linked[i + run - 1] {
                run += 1;
            }
            let mut advanced = false;
            for count in (1..=run).rev() {
                let lower: Vec<&str> = words[i..i + count].iter().map(|w| w.lower.as_str()).collect();
                let Some((entry, key)) = self.lookup(&lower) else {
                    continue;
                };
                if count == 1 && !passes_single_word_rules(&words[i], &key, &self.entries[entry], chars) {
                    continue;
                }
                let end = extend_over_stars(chars, words[i + count - 1].end, covered);
                found.push((words[i].start, end, entry));
                covered[words[i].start..end].fill(true);
                i += count;
                advanced = true;
                break;
            }
            if !advanced {
                i += 1;
            }
        }
    }

    /// 查词键；查不到时把最后一个词末尾的 es 或 s 去掉再查一次（去掉后至少剩 3 个字母）。返回术语下标与命中的键。
    fn lookup(&self, lower: &[&str]) -> Option<(usize, String)> {
        let key = lower.join(" ");
        if let Some(&entry) = self.word_keys.get(&key) {
            return Some((entry, key));
        }
        let (last, head) = lower.split_last()?;
        // 只对最后一个词做复数回退：`vexor navy issues` 回退成 `vexor navy issue`。
        let head: String = head.iter().map(|w| format!("{w} ")).collect();
        for suffix in ["es", "s"] {
            if let Some(stem) = last.strip_suffix(suffix)
                && stem.chars().count() >= 3
            {
                let candidate = format!("{head}{stem}");
                if let Some(&entry) = self.word_keys.get(&candidate) {
                    return Some((entry, candidate));
                }
            }
        }
        None
    }

    // MARK: 建索引

    /// 登记一个术语，并为它的各个名称建键：含汉字、假名或谚文的建字符键（2 个字符以上），其余建词键。
    /// 字符键在 COMMON_WORD_LOCALIZED_NAMES 里、而这一项本来不看边界时，这个键按 CommonWord 匹配。
    fn add(&mut self, names: Vec<String>, entry: Entry) {
        let index = self.entries.len();
        let base = entry.boundary;
        self.entries.push(entry);
        for raw in names {
            let name = raw.trim();
            if name.is_empty() {
                continue;
            }
            if name.chars().any(is_cjk) {
                if name.chars().count() < 2 {
                    continue;
                }
                let boundary = if base == Boundary::Free && COMMON_WORD_LOCALIZED_NAMES.contains(&name) {
                    Boundary::CommonWord
                } else {
                    base
                };
                let key = name.to_lowercase();
                match self.character_keys.get(&key) {
                    Some(&(current, _)) if !prefers(&self.entries[index], &self.entries[current]) => {}
                    _ => {
                        self.character_keys.insert(key, (index, boundary));
                    }
                }
            } else if let Some(key) = word_key(name) {
                match self.word_keys.get(&key) {
                    Some(&current) if !prefers(&self.entries[index], &self.entries[current]) => {}
                    _ => {
                        self.word_keys.insert(key, index);
                    }
                }
            }
        }
    }

    /// 舰船缩写：按右边的英文名找舰船或舰船分组（舰船优先），用左边的词建词键；找不到时不收。
    fn add_aliases(&mut self, ships: &[ShipName]) {
        let mut ordered: Vec<&ShipName> = ships.iter().collect();
        // 舰船在前：同名时舰船优先。
        ordered.sort_by_key(|s| (s.group_id.is_none(), s.id));
        let mut by_name: HashMap<String, &ShipName> = HashMap::new();
        for ship in ordered {
            by_name.entry(ship.name.to_lowercase()).or_insert(ship);
        }
        let aliases: BTreeMap<&str, &str> = SHIP_ALIASES.iter().copied().collect();
        for (alias, target) in aliases {
            if let Some(ship) = by_name.get(&target.to_lowercase()) {
                self.add(vec![alias.to_owned()], Entry::ship(ship, true));
            }
        }
    }

    /// 情报用语：每个词各建一个键，种类是 IntelWord。中文的词作为字符键匹配时看边界。
    fn add_intel_words(&mut self) {
        let groups: [(&[&str], IntelWord, &str); 2] = [
            (&CLEAR_WORDS, IntelWord::Clear, "clear"),
            (&NO_VISUAL_WORDS, IntelWord::NoVisual, "no visual"),
        ];
        for (words, word, english) in groups {
            let mut sorted: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
            sorted.sort();
            let entry = Entry {
                kind: TermKind::IntelWord(word),
                english: english.to_owned(),
                localized: Localized::new(),
                rank: 4,
                is_known_space: false,
                id: 0,
                is_alias: false,
                boundary: Boundary::IntelWord,
            };
            self.add(sorted, entry);
        }
    }
}

/// 一个术语的全部名称：英文名，加按值排序的译名。
fn names(english: &str, localized: &Localized) -> Vec<String> {
    let mut others: Vec<String> = localized.values().cloned().collect();
    others.sort();
    std::iter::once(english.to_owned()).chain(others).collect()
}

/// 同一个键上 candidate 是否比 current 更该留下：种类按先后；同为星系时已知空间优先，再取 ID 小的；
/// 其余同种类重名时取 ID 小的；同一个术语：真名优先于缩写（缩写不替换已有的真名键）。
fn prefers(candidate: &Entry, current: &Entry) -> bool {
    if candidate.rank != current.rank {
        return candidate.rank < current.rank;
    }
    if candidate.is_known_space != current.is_known_space {
        return candidate.is_known_space;
    }
    if candidate.id != current.id {
        return candidate.id < current.id;
    }
    current.is_alias && !candidate.is_alias
}

/// 字符键前后的字符是否满足边界要求。start..end 是键在 chars 里的范围（不含后面的 `*`）。
fn passes_boundary(boundary: Boundary, chars: &[char], start: usize, end: usize) -> bool {
    let before = start.checked_sub(1).map(|i| chars[i]);
    let after = chars.get(end).copied();
    let cjk_before = before.is_some_and(is_cjk);
    let cjk_after = after.is_some_and(is_cjk);
    match boundary {
        Boundary::Free => true,
        Boundary::IntelWord => {
            // 「非常」（很）不是否定：「非常安全」仍算「安全」。
            let look_back: String = chars[start.saturating_sub(CJK_NEGATION_LOOK_BACK)..start]
                .iter()
                .collect::<String>()
                .replace("非常", "");
            !look_back.chars().any(|c| CJK_NEGATIONS.contains(&c)) && !cjk_after
        }
        Boundary::CommonWord => after == Some('*') || (!cjk_before && !cjk_after),
    }
}

/// 只有一个词的匹配的两条限制（6.3 节扫描第 4、5 条）。情报用语不受这两条限制；舰船缩写不受第 5 条限制；
/// 舰船与舰船分组除 CASE_SENSITIVE_SHIP_NAMES 与 AMBIGUOUS_SHORT_NAMES 里的键外也不受第 5 条限制。
fn passes_single_word_rules(word: &Word, key: &str, entry: &Entry, chars: &[char]) -> bool {
    if matches!(entry.kind, TermKind::IntelWord(_)) {
        return true;
    }
    // 第 4 条：虚词、1～2 个字符的词、全是数字的词不算匹配。
    let length = word.lower.chars().count();
    if is_stop_word(&word.lower) || length <= 2 || word.lower.chars().all(char::is_numeric) {
        return false;
    }
    if entry.is_alias {
        return true;
    }
    let followed_by_star = chars.get(word.end) == Some(&'*');
    let capitalized_or_starred = word.first.is_uppercase() || followed_by_star;
    if entry.is_ship_kind() {
        // 按命中的键判断：`sins` 经复数回退命中 `sin`，也要大写或带 `*`。
        if CASE_SENSITIVE_SHIP_NAMES.contains(&key) {
            return capitalized_or_starred;
        }
        if !AMBIGUOUS_SHORT_NAMES.contains(&key) {
            return true;
        }
    }
    // 第 5 条：3 个以内的 ASCII 字母，或也是普通英文词的名称，要首字母大写或后面紧跟 `*`。
    let short_ascii = length <= 3 && word.lower.chars().all(|c| c.is_ascii_alphabetic());
    let ambiguous =
        AMBIGUOUS_SHORT_NAMES.contains(&key) || AMBIGUOUS_SHORT_NAMES.contains(&word.lower.as_str());
    if short_ascii || ambiguous {
        capitalized_or_starred
    } else {
        true
    }
}

/// 取词：连续的字母或数字，中间可以夹 `'`、`’`、`-`。被字符键盖住的位置不算。
fn words(chars: &[char], covered: &[bool]) -> Vec<Word> {
    let usable = |position: usize| !covered[position] && is_word_character(chars[position]);
    let mut words = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        if !usable(index) {
            index += 1;
            continue;
        }
        let mut end = index + 1;
        while end < chars.len() {
            if usable(end) {
                end += 1;
            } else if !covered[end] && is_word_joiner(chars[end]) && end + 1 < chars.len() && usable(end + 1)
            {
                end += 2;
            } else {
                break;
            }
        }
        words.push(Word {
            start: index,
            end,
            lower: chars[index..end].iter().collect::<String>().to_lowercase(),
            first: chars[index],
        });
        index = end;
    }
    words
}

/// 匹配后面紧跟的一个或多个 `*` 并入范围（中文客户端在翻译过的名称后加 `*`）。
fn extend_over_stars(chars: &[char], end: usize, covered: &[bool]) -> usize {
    let mut result = end;
    while result < chars.len() && chars[result] == '*' && !covered[result] {
        result += 1;
    }
    result
}
