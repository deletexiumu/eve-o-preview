// SPDX-License-Identifier: GPL-3.0-or-later
//
// 星图数据，对应 macOS 的 EVEOPreviewCore/StaticData（docs/macos/design-intel-translate.md 4.2～4.3 节、6.3 节、6.6 节）。
// 数据文件 shared/static/eve-static.json 由 shared/static/build-sde-data.py 从 CCP 的 SDE 生成，两个平台共用。
// - 这里：文件结构（短键 i、n、l、s、r、g）、解码后的数据（星系、星域、舰船与分组的名称，星门邻接表，按名称查星系）。
// - lexicon：人工维护的情报用语、舰船缩写与虚词表，以及分类字符的工具函数。
// - matcher：在聊天正文里找星系、星域、舰船、舰船分组与情报用语。
// - jumps：按星门连接算跳数。
// 数据建一次，在本次运行内不变，可在任何线程读。规则：
// - name_in：localized[语言代码] 有值时取它，否则取英文名。
// - 星系的种类：ID 小于 31,000,000 是已知空间，否则是虫洞空间。
// - system_named 的索引：英文名与每个译名转小写作键。同一个键对应多个星系时取已知空间的，仍有多个时取 ID 最小的。
// - neighbors 的邻接表由 jumps 双向建立。

//! 星图数据：文件结构、解码、名称与邻接表的查询、术语匹配与跳数。

pub mod jumps;
pub mod lexicon;
pub mod matcher;

#[cfg(test)]
pub(crate) mod tests;

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use self::matcher::TermMatcher;
use crate::model::AppLanguage;
use crate::support::StringEnum;

/// 应用认识的文件格式版本。
pub const CURRENT_FORMAT: i64 = 1;
/// 虫洞空间星系 ID 的起点。
const WORMHOLE_ID_START: i64 = 31_000_000;

/// 名称的译名表：语言代码（与 AppLanguage 的原始值相同）→ 与英文不同的名称。
pub type Localized = BTreeMap<String, String>;

/// 带名称的记录：星域与舰船分组。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NamedRecord {
    /// ID。
    pub i: i64,
    /// 英文名。
    pub n: String,
    /// 与英文不同的其他语言名称；没有时为 `None`，编码时省略。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub l: Option<Localized>,
}

/// 文件里的一个星系。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SystemRecord {
    /// 星系 ID。
    pub i: i64,
    /// 英文名。
    pub n: String,
    /// 与英文不同的其他语言名称。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub l: Option<Localized>,
    /// 安全等级，3 位小数；SDE 里缺失时为 `None`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub s: Option<f64>,
    /// 星域 ID；SDE 里缺失时为 `None`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub r: Option<i64>,
}

/// 文件里的一艘舰船（一个已发布的舰船类型）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShipRecord {
    /// 舰船类型 ID。
    pub i: i64,
    /// 舰船分组 ID。
    pub g: i64,
    /// 英文名。
    pub n: String,
    /// 与英文不同的其他语言名称。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub l: Option<Localized>,
}

/// eve-static.json 的顶层结构（4.2 节）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StaticDataFile {
    /// 文件格式的版本，结构变化时加 1。
    pub format: i64,
    /// 生成时用的 SDE 版本号（buildNumber）。
    pub sde_build: i64,
    /// SDE 的发布时刻（ISO 8601）；用 `--build` 生成旧版本时可能缺失。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sde_release_date: Option<String>,
    /// 全部星域。
    pub regions: Vec<NamedRecord>,
    /// 已知空间与虫洞空间的星系。
    pub systems: Vec<SystemRecord>,
    /// 星门连接，每项是两个星系 ID，小的在前。
    pub jumps: Vec<Vec<i64>>,
    /// 已发布的舰船分组。
    pub ship_groups: Vec<NamedRecord>,
    /// 已发布的舰船。
    pub ships: Vec<ShipRecord>,
}

/// 星图数据读不了的原因。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StaticDataError {
    /// JSON 解不开，关联值是解码器给的说明。
    Unreadable(String),
    /// 不认识的文件格式版本。
    UnsupportedFormat(i64),
    /// 没有星系。
    Empty,
}

impl StaticDataError {
    /// 写进日志的名字：只有种类与格式版本，不含 Unreadable 的说明（说明可能含文件路径）。
    pub fn log_name(&self) -> String {
        match self {
            StaticDataError::Unreadable(_) => "unreadable".into(),
            StaticDataError::UnsupportedFormat(found) => format!("unsupportedFormat({found})"),
            StaticDataError::Empty => "empty".into(),
        }
    }
}

/// 星系所在的空间。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpaceKind {
    /// 已知空间（ID 小于 31,000,000）。
    Known,
    /// 虫洞空间。
    Wormhole,
}

/// 一个星系。
#[derive(Debug, Clone, PartialEq)]
pub struct SolarSystem {
    /// 星系 ID。
    pub id: i64,
    /// 英文名。
    pub name: String,
    /// 与英文不同的其他语言名称，键是语言代码。
    pub localized: Localized,
    /// 安全等级（3 位小数）；没有时为 `None`。
    pub security: Option<f64>,
    /// 星域 ID。
    pub region_id: Option<i64>,
    /// 已知空间或虫洞空间。
    pub kind: SpaceKind,
}

impl SolarSystem {
    /// 只有 ID 与英文名的星系，种类由 ID 决定（测试与夹具用）。
    pub fn new(id: i64, name: &str) -> Self {
        Self {
            id,
            name: name.to_owned(),
            localized: Localized::new(),
            security: None,
            region_id: None,
            kind: space_kind(id),
        }
    }

    /// 某种语言下的名称；没有译名时取英文名。
    pub fn name_in(&self, language: AppLanguage) -> &str {
        self.localized.get(language.raw()).unwrap_or(&self.name)
    }

    /// 游戏里显示的安全等级：大于 0 且小于 0.05 时显示 0.1，其余四舍五入到一位小数（-0.0 写成 0.0）。
    pub fn display_security(&self) -> Option<f64> {
        let security = self.security?;
        if security > 0.0 && security < 0.05 {
            return Some(0.1);
        }
        let rounded = (security * 10.0).round() / 10.0;
        Some(if rounded == 0.0 { 0.0 } else { rounded })
    }
}

/// 一艘舰船或一个舰船分组的名称。
#[derive(Debug, Clone, PartialEq)]
pub struct ShipName {
    /// 舰船类型 ID，或舰船分组 ID（`group_id` 为 `None` 时）。
    pub id: i64,
    /// 舰船所属的分组 ID；`None` 表示这一项本身是一个舰船分组。
    pub group_id: Option<i64>,
    /// 英文名。
    pub name: String,
    /// 与英文不同的其他语言名称。
    pub localized: Localized,
}

impl ShipName {
    /// 只有英文名的一项（测试用）。
    pub fn new(id: i64, group_id: Option<i64>, name: &str) -> Self {
        Self {
            id,
            group_id,
            name: name.to_owned(),
            localized: Localized::new(),
        }
    }

    /// 某种语言下的名称；没有译名时取英文名。
    pub fn name_in(&self, language: AppLanguage) -> &str {
        self.localized.get(language.raw()).unwrap_or(&self.name)
    }
}

/// 解码后的星图数据。
#[derive(Debug)]
pub struct EveStaticData {
    /// 生成数据时用的 SDE 版本号。
    pub sde_build: i64,
    /// 全部星系，按 ID 排序。
    pub systems: Vec<SolarSystem>,
    /// 舰船与舰船分组，先舰船后分组，各按 ID 排序。
    pub ships: Vec<ShipName>,
    /// 术语匹配器，用全部星系、星域、舰船与舰船分组建立（6.3 节）。
    pub matcher: TermMatcher,
    /// 星系 ID → 在 systems 里的下标。
    system_index: HashMap<i64, usize>,
    /// 小写的名称（任一语言）→ 星系 ID。
    systems_by_name: HashMap<String, i64>,
    /// 星域 ID → 星域。
    regions: HashMap<i64, NamedRecord>,
    /// 舰船类型 ID → 在 ships 里的下标。
    ships_by_id: HashMap<i64, usize>,
    /// 舰船分组 ID → 在 ships 里的下标。
    groups_by_id: HashMap<i64, usize>,
    /// 星系 ID → 相邻的星系 ID（升序）。
    adjacency: HashMap<i64, Vec<i64>>,
}

impl EveStaticData {
    /// 由文件结构建数据。format 不认识时返回 `UnsupportedFormat`，没有星系时返回 `Empty`。
    pub fn from_file(file: StaticDataFile) -> Result<Self, StaticDataError> {
        if file.format != CURRENT_FORMAT {
            return Err(StaticDataError::UnsupportedFormat(file.format));
        }
        if file.systems.is_empty() {
            return Err(StaticDataError::Empty);
        }
        // 星系：换成带种类的值，按 ID 排序，再建 ID 与名称两个索引。
        let mut systems: Vec<SolarSystem> = file
            .systems
            .into_iter()
            .map(|r| SolarSystem {
                kind: space_kind(r.i),
                id: r.i,
                name: r.n,
                localized: r.l.unwrap_or_default(),
                security: r.s,
                region_id: r.r,
            })
            .collect();
        systems.sort_by_key(|s| s.id);
        let system_index = systems.iter().enumerate().map(|(i, s)| (s.id, i)).collect();
        let systems_by_name = name_index(&systems);
        // 舰船与分组：各按 ID 排序后接成一个列表（先舰船后分组），术语匹配按这个顺序建键。
        let mut ships: Vec<ShipName> = file
            .ships
            .into_iter()
            .map(|r| ShipName {
                id: r.i,
                group_id: Some(r.g),
                name: r.n,
                localized: r.l.unwrap_or_default(),
            })
            .collect();
        ships.sort_by_key(|s| s.id);
        let mut groups: Vec<ShipName> = file
            .ship_groups
            .into_iter()
            .map(|r| ShipName {
                id: r.i,
                group_id: None,
                name: r.n,
                localized: r.l.unwrap_or_default(),
            })
            .collect();
        groups.sort_by_key(|s| s.id);
        ships.extend(groups);
        // 同一个 ID 出现多次时取第一个（与 macOS 的 uniquingKeysWith 相同）。
        let mut ships_by_id = HashMap::new();
        let mut groups_by_id = HashMap::new();
        for (index, ship) in ships.iter().enumerate() {
            let table = if ship.group_id.is_some() {
                &mut ships_by_id
            } else {
                &mut groups_by_id
            };
            table.entry(ship.id).or_insert(index);
        }
        // 星域：按 ID 排序后交给术语匹配；查名称用的表同 ID 取第一个。
        let mut regions_sorted = file.regions;
        regions_sorted.sort_by_key(|r| r.i);
        let mut regions = HashMap::new();
        for region in &regions_sorted {
            regions.entry(region.i).or_insert_with(|| region.clone());
        }
        // 星门：每条连接双向登记；长度不是 2 或连到自己的记录跳过。
        let mut neighbors: HashMap<i64, BTreeSet<i64>> = HashMap::new();
        for pair in file.jumps.iter().filter(|p| p.len() == 2 && p[0] != p[1]) {
            neighbors.entry(pair[0]).or_default().insert(pair[1]);
            neighbors.entry(pair[1]).or_default().insert(pair[0]);
        }
        let adjacency = neighbors
            .into_iter()
            .map(|(id, set)| (id, set.into_iter().collect()))
            .collect();
        // 术语匹配器最后建：它要用到排好序的星系、星域与舰船。
        let matcher = TermMatcher::new(&systems, &regions_sorted, &ships);
        Ok(Self {
            sde_build: file.sde_build,
            systems,
            ships,
            matcher,
            system_index,
            systems_by_name,
            regions,
            ships_by_id,
            groups_by_id,
            adjacency,
        })
    }

    /// 解码 eve-static.json 的内容。先只读 format，不认识时返回 `UnsupportedFormat`，不去解后面可能已变的结构。
    pub fn decode(json: &str) -> Result<Self, StaticDataError> {
        /// 只含 format 的外壳。
        #[derive(Deserialize)]
        struct Header {
            /// 文件格式的版本。
            format: Option<i64>,
        }
        let unreadable = |error: serde_json::Error| StaticDataError::Unreadable(error.to_string());
        // 第一遍只取 format：版本不对时不解其余部分，报 UnsupportedFormat 而不是 Unreadable。
        let header: Header = serde_json::from_str(json).map_err(unreadable)?;
        let format = header
            .format
            .ok_or_else(|| StaticDataError::Unreadable("missing format".into()))?;
        if format != CURRENT_FORMAT {
            return Err(StaticDataError::UnsupportedFormat(format));
        }
        Self::from_file(serde_json::from_str(json).map_err(unreadable)?)
    }

    // MARK: 查询

    /// 按 ID 找星系。
    pub fn system(&self, id: i64) -> Option<&SolarSystem> {
        self.system_index.get(&id).map(|&i| &self.systems[i])
    }

    /// 按任一语言的名称找星系。先去掉首尾空白与末尾的 `*`，比较不区分大小写。
    pub fn system_named(&self, name: &str) -> Option<&SolarSystem> {
        let key = lookup_key(name);
        if key.is_empty() {
            return None;
        }
        self.system(*self.systems_by_name.get(&key)?)
    }

    /// 名称（任一语言）以 prefix 开头的星系，至多 limit 个；给设置界面的星系输入框用。
    ///
    /// 比较不区分大小写。排序：名称与 prefix 完全相同的在最前，其余按匹配到的名称从短到长、再按英文名、再按 ID。
    pub fn search_systems(&self, prefix: &str, limit: usize) -> Vec<&SolarSystem> {
        let key = lookup_key(prefix);
        if key.is_empty() || limit == 0 {
            return Vec::new();
        }
        let mut found: Vec<(&SolarSystem, bool, usize)> = Vec::new();
        for system in &self.systems {
            let hits: Vec<String> = std::iter::once(&system.name)
                .chain(system.localized.values())
                .map(|name| name.to_lowercase())
                .filter(|name| name.starts_with(&key))
                .collect();
            let Some(shortest) = hits.iter().map(|hit| hit.chars().count()).min() else {
                continue;
            };
            found.push((system, hits.contains(&key), shortest));
        }
        // 完全相同的在前（true 排在 false 前），再按匹配到的名称长度、英文名、ID。
        found.sort_by(|a, b| {
            b.1.cmp(&a.1)
                .then(a.2.cmp(&b.2))
                .then_with(|| a.0.name.cmp(&b.0.name))
                .then(a.0.id.cmp(&b.0.id))
        });
        found.into_iter().take(limit).map(|f| f.0).collect()
    }

    /// 星域在某种语言下的名称；没有这个星域时返回 `None`。
    pub fn region_name(&self, id: i64, language: AppLanguage) -> Option<&str> {
        let region = self.regions.get(&id)?;
        let localized = region.l.as_ref().and_then(|l| l.get(language.raw()));
        Some(localized.unwrap_or(&region.n))
    }

    /// 按舰船类型 ID 找舰船。
    pub fn ship(&self, id: i64) -> Option<&ShipName> {
        self.ships_by_id.get(&id).map(|&i| &self.ships[i])
    }

    /// 按舰船分组 ID 找分组。
    pub fn ship_group(&self, id: i64) -> Option<&ShipName> {
        self.groups_by_id.get(&id).map(|&i| &self.ships[i])
    }

    /// 与某个星系有星门相连的星系 ID，升序；没有星门时为空。
    pub fn neighbors(&self, system_id: i64) -> &[i64] {
        self.adjacency.get(&system_id).map_or(&[], Vec::as_slice)
    }
}

/// 星系 ID 所在的空间。
fn space_kind(id: i64) -> SpaceKind {
    if id < WORMHOLE_ID_START {
        SpaceKind::Known
    } else {
        SpaceKind::Wormhole
    }
}

/// 查名称用的键：去掉首尾空白与末尾的 `*`（中文客户端在译名后加 `*`），转小写。
pub(crate) fn lookup_key(name: &str) -> String {
    name.trim().trim_end_matches('*').trim().to_lowercase()
}

/// 建名称索引：同一个键对应多个星系时，已知空间优先，再取 ID 小的。
fn name_index(systems: &[SolarSystem]) -> HashMap<String, i64> {
    let mut index: HashMap<String, &SolarSystem> = HashMap::new();
    for system in systems {
        for name in std::iter::once(&system.name).chain(system.localized.values()) {
            let key = name.to_lowercase();
            if key.is_empty() {
                continue;
            }
            match index.get(&key) {
                Some(current) if !prefers(system, current) => {}
                _ => {
                    index.insert(key, system);
                }
            }
        }
    }
    index.into_iter().map(|(key, s)| (key, s.id)).collect()
}

/// 重名时 candidate 是否比 current 更该留下：已知空间优先，同种空间取 ID 小的。
fn prefers(candidate: &SolarSystem, current: &SolarSystem) -> bool {
    if candidate.kind != current.kind {
        return candidate.kind == SpaceKind::Known;
    }
    candidate.id < current.id
}
