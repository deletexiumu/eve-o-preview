// SPDX-License-Identifier: GPL-3.0-or-later
//
// 角色位置的记录，对应 macOS 的 LocationTracker.swift（设计文档 6.2 节）。位置有两个自动来源（Local 聊天日志的
// 系统消息、游戏日志的跳跃与离站记录）与手动设置；不知道角色位置时，跳数从参考星系算。
//
// apply 的规则：
// 1. 按线索的来源用 location 的句式取星系名，再用 EveStaticData::system_named 查星系。
// 2. 取不到或查不到时兜底：对正文做术语匹配，按正文里的星系个数决定（应对表以外语言的句式）：
//    - 正好 2 个：取后一个，不看后面还有什么。跳跃句「从 A 到 B」与离开 NPC 空间站的句子（空间站名以星系名
//      开头）都是 2 个；日文、韩文的动词在句末，目的星系后面还有字。
//    - 正好 1 个：只对 Local 的线索，且这个星系后面只剩空白或标点时才用。游戏日志的 (None) 行只有 1 个星系时
//      不用：「从 A 跳到 <认不出的名字>」不应记成出发的 A，「设置目的地为 X」一类的行也不是位置。
//    - 0 个或 3 个以上：不用。
// 3. 仍没有结果时不改任何记录。
// 4. 角色的键先原样比较，没有时再不区分大小写比较（coverage::match_name）。
// 5. 补读的线索只在没有记录、或时间晚于记录时写入；运行中的线索直接写入，不比较时间
//    （日志时间来自游戏，手动设置的时间来自本机时钟，两者可能差几秒）。
// 6. 写入（星系，线索的时间，来源）；星系与来源都没变时返回假（时间仍更新）。

//! 各角色的位置记录与跳数的出发点。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::coverage::match_name;
use super::{LocationHint, LocationHintSource, location};
use crate::static_data::matcher::TermKind;
use crate::static_data::{EveStaticData, lexicon};

/// 位置记录的来源。原始值与 macOS 的 state.json 相同。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LocationSource {
    /// `Local` 聊天日志的系统消息。
    LocalChannel,
    /// 游戏日志的跳跃与离站记录。
    GameLog,
    /// 用户在「预警」页手动设置。
    Manual,
}

/// 一个角色所在的星系，以及这条记录的时间与来源。手动设置的记录存进 state.json。
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct CharacterLocation {
    /// 星系 ID。
    #[serde(rename = "systemID")]
    pub system_id: i64,
    /// 记录的时间，UTC，1970 年以来的秒数。
    pub time: f64,
    /// 来源。
    pub source: LocationSource,
}

/// 跳数的出发点。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LocationOrigin {
    /// 角色有位置记录。
    Character(CharacterLocation),
    /// 角色没有位置，用参考星系（关联值是星系 ID）。
    Reference(i64),
    /// 都没有。
    Unknown,
}

impl LocationOrigin {
    /// 出发星系的 ID；Unknown 时为 `None`。
    pub fn system_id(&self) -> Option<i64> {
        match self {
            LocationOrigin::Character(location) => Some(location.system_id),
            LocationOrigin::Reference(id) => Some(*id),
            LocationOrigin::Unknown => None,
        }
    }
}

/// 各角色的位置记录。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LocationTracker {
    /// 角色名 → 位置。
    locations: BTreeMap<String, CharacterLocation>,
    /// 参考星系；不知道角色位置时跳数从它算。
    pub reference_system_id: Option<i64>,
}

impl LocationTracker {
    /// 用 state.json 里的手动位置与参考星系建记录。
    pub fn new(manual: BTreeMap<String, CharacterLocation>, reference_system_id: Option<i64>) -> Self {
        Self {
            locations: manual,
            reference_system_id,
        }
    }

    /// 全部记录。
    pub fn locations(&self) -> &BTreeMap<String, CharacterLocation> {
        &self.locations
    }

    /// 把一条位置线索解析成星系并记下，返回位置（星系或来源）是否变了。
    pub fn apply(&mut self, hint: &LocationHint, data: &EveStaticData) -> bool {
        let Some(system_id) = resolve_system(hint, data) else {
            return false;
        };
        let source = match hint.source {
            LocationHintSource::LocalChannel => LocationSource::LocalChannel,
            LocationHintSource::GameLog => LocationSource::GameLog,
        };
        let key = self
            .key(&hint.character)
            .unwrap_or_else(|| hint.character.clone());
        let current = self.locations.get(&key).copied();
        if hint.is_backfill && current.is_some_and(|c| hint.time <= c.time) {
            return false;
        }
        let record = CharacterLocation {
            system_id,
            time: hint.time,
            source,
        };
        self.locations.insert(key, record);
        current.is_none_or(|c| c.system_id != system_id || c.source != source)
    }

    /// 手动设置位置：system_id 为 `None` 时删掉这个角色的记录；否则写入（星系，now，手动）。返回记录是否变了。
    pub fn set_manual(&mut self, character: &str, system_id: Option<i64>, now: f64) -> bool {
        let key = self.key(character);
        let Some(system_id) = system_id else {
            return key.is_some_and(|key| self.locations.remove(&key).is_some());
        };
        let current = key.as_ref().and_then(|k| self.locations.get(k)).copied();
        let record = CharacterLocation {
            system_id,
            time: now,
            source: LocationSource::Manual,
        };
        self.locations
            .insert(key.unwrap_or_else(|| character.to_owned()), record);
        current.is_none_or(|c| c.system_id != system_id || c.source != LocationSource::Manual)
    }

    /// 跳数的出发点：角色有记录时是它的位置；否则有参考星系时是参考星系；都没有时是 Unknown。
    pub fn origin(&self, character: Option<&str>) -> LocationOrigin {
        if let Some(location) = character
            .and_then(|c| self.key(c))
            .and_then(|key| self.locations.get(&key))
        {
            return LocationOrigin::Character(*location);
        }
        self.reference_system_id
            .map_or(LocationOrigin::Unknown, LocationOrigin::Reference)
    }

    /// 要写进 state.json 的手动位置：来源是 Manual 的记录。
    pub fn manual_locations(&self) -> BTreeMap<String, CharacterLocation> {
        self.locations
            .iter()
            .filter(|(_, l)| l.source == LocationSource::Manual)
            .map(|(k, l)| (k.clone(), *l))
            .collect()
    }

    /// 记录里与角色名对应的键：先原样相等，再不区分大小写相等。
    fn key(&self, character: &str) -> Option<String> {
        match_name(character, self.locations.keys().map(String::as_str)).map(str::to_owned)
    }
}

/// 线索里的星系：先按句式取名称再查星系；取不到时按文件头第 2 条兜底，不满足时为 `None`。
pub(crate) fn resolve_system(hint: &LocationHint, data: &EveStaticData) -> Option<i64> {
    let name = match hint.source {
        LocationHintSource::LocalChannel => location::system_name_from_local(&hint.text),
        LocationHintSource::GameLog => location::system_name_from_game_note(&hint.text),
    };
    if let Some(system) = name.and_then(|n| data.system_named(&n)) {
        return Some(system.id);
    }
    let systems: Vec<_> = data
        .matcher
        .matches(&hint.text)
        .into_iter()
        .filter(|m| matches!(m.kind, TermKind::System(_)))
        .collect();
    let last = systems.last()?;
    let TermKind::System(id) = last.kind else {
        return None;
    };
    match systems.len() {
        2 => Some(id),
        1 if hint.source == LocationHintSource::LocalChannel => {
            let tail = &hint.text[last.range.end..];
            tail.chars().all(is_space_or_punctuation).then_some(id)
        }
        _ => None,
    }
}

/// 空白或标点。标准库没有 Unicode 的标点分类，这里把「不是字母、数字，也不是汉字、假名、谚文」都算作标点：
/// 全角的「！」「。」也在内；与 macOS 的 isPunctuation 相比多算了符号（+、$ 等），在句末出现时同样不影响判断。
fn is_space_or_punctuation(c: char) -> bool {
    c.is_whitespace() || (!c.is_alphanumeric() && !lexicon::is_cjk(c))
}
