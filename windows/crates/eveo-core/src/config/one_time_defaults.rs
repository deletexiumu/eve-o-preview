// SPDX-License-Identifier: GPL-3.0-or-later
//
// 给已有配置补上后来新增的默认值，每一项只补一次，对应 macOS 的 Config/OneTimeDefaults.swift。
// 新建的配置方案经 `Profile::make_new` 直接带上新默认值；已经存在的配置文件里对应的字段早已写成空值，
// 解码时分不清「从没设置过」与「用户清空了」，所以由应用在启动时按项补一次，补过的项记在状态文件里，
// 之后用户删掉也不会再补回来。项的 id 两端相同：从 macOS 导入的状态文件里已补过的项，这里不会重复补。

//! 一次性补上的默认值。

use crate::hotkeys::HotkeySpec;
use crate::model::{AppConfig, DEFAULT_TOGGLE_HIDE_ALL, Profile};

/// 「全部隐藏」的默认热键（`DEFAULT_TOGGLE_HIDE_ALL`），macOS v1.2 新增。
pub const TOGGLE_HIDE_ALL_HOTKEY: &str = "hotkeys.toggleHideAll.ctrlOptCmdH";

/// 「高亮活动客户端」默认打开（`OverlaySettings::highlight_enabled`），macOS v1.2.1 新增。
pub const HIGHLIGHT_ACTIVE_CLIENT: &str = "overlay.highlightEnabled.on";

/// 全部的项，按加入的先后。以后新增的一次性默认值追加在末尾。
pub const ALL: [&str; 2] = [TOGGLE_HIDE_ALL_HOTKEY, HIGHLIGHT_ACTIVE_CLIENT];

/// 还没补过的项，保持 `ALL` 里的顺序。
pub fn pending(applied: &[String]) -> Vec<&'static str> {
    ALL.into_iter()
        .filter(|id| !applied.iter().any(|a| a == id))
        .collect()
}

/// 把 ids 里的各项补到配置的每个配置方案上；不认识的 id 忽略。配置原本就满足时原样返回。
pub fn apply<S: AsRef<str>>(ids: &[S], config: &AppConfig) -> AppConfig {
    let mut result = config.clone();
    for id in ids {
        for profile in &mut result.profiles {
            match id.as_ref() {
                TOGGLE_HIDE_ALL_HOTKEY => add_default_toggle_hide_all(profile),
                // 每个配置方案都打开高亮；颜色与粗细保留用户原来的设置。
                HIGHLIGHT_ACTIVE_CLIENT => profile.overlay.highlight_enabled = true,
                _ => {}
            }
        }
    }
    result
}

/// 「全部隐藏」还没有任何热键、且默认组合没被这个方案的其他动作占用时，绑定默认热键。
///
/// 用户已经给「全部隐藏」设过热键的，尊重用户的选择不再追加；
/// 默认组合已被别的动作占用时不追加，否则会出现「与某某重复」的提示。
fn add_default_toggle_hide_all(profile: &mut Profile) {
    if !profile.hotkeys.toggle_hide_all.is_empty() {
        return;
    }
    let Some(wanted) = HotkeySpec::parse(DEFAULT_TOGGLE_HIDE_ALL).map(|s| s.hotkey) else {
        return;
    };
    let taken =
        all_hotkey_texts(profile).any(|text| HotkeySpec::parse(text).map(|s| s.hotkey) == Some(wanted));
    if !taken {
        profile.hotkeys.toggle_hide_all = vec![DEFAULT_TOGGLE_HIDE_ALL.to_owned()];
    }
}

/// 配置方案里全部热键字符串（全局热键、循环组、角色直达），用于判断某个组合是否已被占用。
fn all_hotkey_texts(profile: &Profile) -> impl Iterator<Item = &String> {
    let hotkeys = &profile.hotkeys;
    hotkeys
        .toggle_hide_all
        .iter()
        .chain(&hotkeys.minimize_all)
        .chain(&hotkeys.cycle_login_clients)
        .chain(
            profile
                .cycle_groups
                .iter()
                .flat_map(|g| g.forward_hotkeys.iter().chain(&g.backward_hotkeys)),
        )
        .chain(profile.character_hotkeys.values().flatten())
}
