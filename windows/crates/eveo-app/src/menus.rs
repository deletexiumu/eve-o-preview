// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图右键菜单与托盘菜单的内容，对应 macOS 的 ThumbnailContextMenu 与菜单栏菜单。
// 菜单项编号与动作一一对应；托盘菜单里的配置方案从 PROFILE_BASE 起按配置里的顺序编号。
// 文字按界面语言取自 eveo-l10n，与 macOS 的菜单栏菜单、缩略图右键菜单同一份文案。

use eveo_app_core::{ContextMenuAction, ContextMenuModel, TrayAction, TrayModel};
use eveo_core::model::AppLanguage;
use eveo_platform_win::menu::MenuEntry;

/// 右键菜单「最小化」。
const MINIMIZE: u32 = 1;
/// 右键菜单「最小化全部」。
const MINIMIZE_ALL: u32 = 2;
/// 右键菜单「跳过循环」。
const TOGGLE_SKIP: u32 = 3;
/// 右键菜单「隐藏此角色」。
const HIDE: u32 = 4;
/// 右键菜单「恢复默认尺寸」。
const RESET_SIZE: u32 = 5;
/// 右键菜单「设置」。
const OPEN_SETTINGS: u32 = 6;

/// 托盘菜单「隐藏全部缩略图」。
const TRAY_HIDE_ALL: u32 = 101;
/// 托盘菜单「最小化全部客户端」。
const TRAY_MINIMIZE_ALL: u32 = 102;
/// 托盘菜单「设置」。
const TRAY_SETTINGS: u32 = 103;
/// 托盘菜单「退出」。
const TRAY_QUIT: u32 = 104;
/// 托盘菜单里第一个配置方案的编号。
const PROFILE_BASE: u32 = 1000;

/// 缩略图的右键菜单。按角色的项对登录客户端置灰。
pub fn context_menu(model: &ContextMenuModel, language: AppLanguage) -> Vec<MenuEntry> {
    let text = eveo_l10n::thumbnail(language);
    // 登录界面的客户端没有角色名：跳过、隐藏与尺寸都按角色名保存，对它没有意义。
    let is_character = model.character_name.is_some();
    vec![
        MenuEntry::item(MINIMIZE, text.minimize()),
        MenuEntry::item(MINIMIZE_ALL, text.minimize_all()),
        MenuEntry::Separator,
        MenuEntry::Item {
            id: TOGGLE_SKIP,
            text: text.skip_cycle().to_owned(),
            enabled: is_character,
            checked: model.is_skipped,
        },
        MenuEntry::Item {
            id: HIDE,
            text: text.hide().to_owned(),
            enabled: is_character,
            checked: false,
        },
        MenuEntry::Item {
            id: RESET_SIZE,
            text: text.reset_size().to_owned(),
            enabled: is_character && model.has_custom_size,
            checked: false,
        },
        MenuEntry::Separator,
        MenuEntry::item(OPEN_SETTINGS, text.settings()),
    ]
}

/// 右键菜单的编号换回动作。
pub fn context_action(id: u32) -> Option<ContextMenuAction> {
    Some(match id {
        MINIMIZE => ContextMenuAction::Minimize,
        MINIMIZE_ALL => ContextMenuAction::MinimizeAll,
        TOGGLE_SKIP => ContextMenuAction::ToggleSkip,
        HIDE => ContextMenuAction::Hide,
        RESET_SIZE => ContextMenuAction::ResetSize,
        OPEN_SETTINGS => ContextMenuAction::OpenSettings,
        _ => return None,
    })
}

/// 托盘菜单：全部隐藏、最小化全部、配置方案（单选）、设置、退出。
pub fn tray_menu(model: &TrayModel, language: AppLanguage) -> Vec<MenuEntry> {
    let text = eveo_l10n::menu(language);
    // 配置方案的编号按列表下标给，选中后再按同一份列表换回 id；弹菜单期间配置不会变（菜单是模态的）。
    let profiles = model
        .profiles
        .iter()
        .enumerate()
        .map(|(index, (id, name))| MenuEntry::Item {
            id: PROFILE_BASE + index as u32,
            text: name.clone(),
            enabled: true,
            checked: *id == model.active_profile_id,
        })
        .collect();
    vec![
        MenuEntry::Item {
            id: TRAY_HIDE_ALL,
            text: text.hide_all().to_owned(),
            enabled: true,
            checked: model.hide_all,
        },
        MenuEntry::item(TRAY_MINIMIZE_ALL, text.minimize_all()),
        MenuEntry::Separator,
        MenuEntry::Submenu {
            text: text.profiles().to_owned(),
            entries: profiles,
        },
        MenuEntry::item(TRAY_SETTINGS, text.settings()),
        MenuEntry::Separator,
        MenuEntry::item(TRAY_QUIT, text.quit()),
    ]
}

/// 托盘菜单的编号换回动作。配置方案按弹出菜单时的列表换回 id。
pub fn tray_action(id: u32, model: &TrayModel) -> Option<TrayAction> {
    Some(match id {
        TRAY_HIDE_ALL => TrayAction::ToggleHideAll,
        TRAY_MINIMIZE_ALL => TrayAction::MinimizeAll,
        TRAY_SETTINGS => TrayAction::OpenSettings,
        TRAY_QUIT => TrayAction::Quit,
        _ => {
            let index = id.checked_sub(PROFILE_BASE)? as usize;
            TrayAction::SwitchProfile(model.profiles.get(index)?.0.clone())
        }
    })
}

/// 托盘图标的提示文字。
pub fn tray_tooltip(model: &TrayModel, language: AppLanguage) -> String {
    let count = eveo_l10n::menu(language).client_count(model.client_count as i64);
    format!("EVE-O Preview · {count}")
}
