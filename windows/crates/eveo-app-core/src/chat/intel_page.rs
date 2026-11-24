// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页的运行时状态，对应 macOS 的 SettingsViewModel+Intel.swift 里读控制器的那几项：
// - 我的位置：每个在线角色一行，「星系（来源，多久以前）」或「未知」；有记录时「清除」可点。
//   角色名先原样比较、再不区分大小写比较（与 macOS 的 CharacterNameMatch 相同）。
// - 参考星系：填了、星图数据已读入、却查不到时为真（输入框下提示「找不到这个星系」）。
// - 人名核对：状态文字（功能关着时没有）与人名缓存的条数（缓存文件还没读完时没有）。
// - 星图数据：SDE 版本、缺失或无效时的说明，还没读时是「—」。
// 这些都只读总控，不改任何东西；应用层每次定时器算一份，与上一次不同才交给界面。

//! 「预警」页的运行时状态。

use eveo_core::chat_log::coverage::match_name;
use eveo_core::chat_log::tracker::LocationSource;
use eveo_core::intel::pilots::PilotLookupStatus;
use eveo_core::intel::presenter::IntelLineFormatting;
use eveo_core::model::{AppConfig, AppLanguage};

use super::features::ChatFeatures;
use super::{IntelFormatter, whole_seconds};

/// 「我的位置」的一行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocationRow {
    /// 角色名（客户端窗口标题里的写法）。
    pub name: String,
    /// 位置文字：「星系（来源，多久以前）」或「未知」。
    pub text: String,
    /// 有没有位置记录（「清除」按钮只在有记录时可点）。
    pub has_location: bool,
}

/// 「预警」页的运行时状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntelPageState {
    /// 在线角色的位置，按名字排序。
    pub locations: Vec<LocationRow>,
    /// 参考星系填了却查不到。
    pub reference_not_found: bool,
    /// 人名核对的状态文字；功能关着时为 None。
    pub pilot_status: Option<String>,
    /// 人名缓存的条数文字；缓存文件还没读完时为 None。
    pub pilot_cache: Option<String>,
    /// 星图数据一行的文字。
    pub static_data: String,
}

impl ChatFeatures {
    /// 算一份「预警」页的状态。characters 是在线角色（顺序不限，这里排序并去重）。
    pub fn intel_page(&self, characters: &[String], now: f64) -> IntelPageState {
        let language = self.language();
        let text = eveo_l10n::intel(language);
        let formatter = IntelFormatter { language };
        let locations_by_name = self.intel().locations();
        // 名字排序不区分大小写，与 macOS 的 localizedStandardCompare 接近；同名（只差大小写）的只留一个。
        let mut names: Vec<&String> = characters.iter().collect();
        names.sort_by_key(|name| (name.to_lowercase(), (*name).clone()));
        names.dedup_by(|a, b| a.to_lowercase() == b.to_lowercase());
        let locations = names
            .into_iter()
            .map(|name| {
                let found = match_name(name, locations_by_name.keys().map(String::as_str))
                    .and_then(|key| locations_by_name.get(key));
                let Some(location) = found else {
                    return LocationRow {
                        name: name.clone(),
                        text: text.location_unknown().to_owned(),
                        has_location: false,
                    };
                };
                // 星图数据没读完时用星系 ID 代替名字（与 macOS 相同），记录本身照常显示。
                let system = self
                    .static_data()
                    .and_then(|data| data.system(location.system_id))
                    .map_or_else(
                        || location.system_id.to_string(),
                        |s| s.name_in(language).to_owned(),
                    );
                let source = match location.source {
                    LocationSource::GameLog => text.source_game_log(),
                    LocationSource::LocalChannel => text.source_local(),
                    LocationSource::Manual => text.source_manual(),
                };
                let age = formatter.age(whole_seconds(now - location.time));
                LocationRow {
                    name: name.clone(),
                    text: text.location_value(&system, source, &age),
                    has_location: true,
                }
            })
            .collect();
        let (cached, cache_loaded) = self.intel().pilot_cache();
        // 条数在文字里是 i64（复数规则按整数取）；缓存不会大到溢出，万一溢出就按上限显示。
        let cached = i64::try_from(cached).unwrap_or(i64::MAX);
        IntelPageState {
            locations,
            reference_not_found: self.reference_not_found(),
            pilot_status: pilot_status_text(self.intel().pilot_lookup_status(), cached, language, now),
            pilot_cache: cache_loaded.then(|| text.pilot_cache_count(cached)),
            static_data: static_data_text(self.static_data_state(), language),
        }
    }

    /// 参考星系填了、星图数据已读入、却查不到。
    fn reference_not_found(&self) -> bool {
        let reference = self
            .config()
            .and_then(AppConfig::active_profile)
            .and_then(|p| p.intel.reference_system.as_deref())
            .map(str::trim)
            .filter(|name| !name.is_empty());
        match (reference, self.static_data()) {
            (Some(name), Some(data)) => data.system_named(name).is_none(),
            _ => false,
        }
    }
}

/// 人名核对的状态文字；Off 时为 None。等待的时刻已过时显示成就绪（下一次定时器就会再发）。
pub fn pilot_status_text(
    status: PilotLookupStatus,
    cached: i64,
    language: AppLanguage,
    now: f64,
) -> Option<String> {
    let text = eveo_l10n::intel(language);
    match status {
        PilotLookupStatus::Off => None,
        PilotLookupStatus::Idle => Some(text.pilot_lookup_idle(cached)),
        PilotLookupStatus::Resolving => Some(text.pilot_lookup_resolving().to_owned()),
        PilotLookupStatus::Waiting(until) => {
            let seconds = whole_seconds((until - now).ceil());
            Some(if seconds > 0 {
                text.pilot_lookup_waiting(seconds)
            } else {
                text.pilot_lookup_idle(cached)
            })
        }
    }
}

/// 星图数据一行的文字：`build-<版本>` 显示版本，missing 与 invalid 显示缺失的说明，其余（还没读）是「—」。
pub fn static_data_text(state: &str, language: AppLanguage) -> String {
    let text = eveo_l10n::intel(language);
    if let Some(build) = state.strip_prefix("build-").and_then(|b| b.parse::<i64>().ok()) {
        return text.static_data_build(build);
    }
    match state {
        "missing" | "invalid" => text.static_data_missing().to_owned(),
        _ => "—".to_owned(),
    }
}
