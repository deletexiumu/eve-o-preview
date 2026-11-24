// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图右键菜单、浮窗右键菜单与托盘菜单的内容，对应 macOS 的 ThumbnailContextMenu、OverlayContextMenu
// 与菜单栏菜单。
// 菜单项编号与动作一一对应；托盘菜单里的配置方案从 PROFILE_BASE 起按配置里的顺序编号。
// 文字按界面语言取自 eveo-l10n，与 macOS 的菜单栏菜单、缩略图右键菜单同一份文案。

use eveo_app_core::{ContextMenuAction, ContextMenuModel, OverlayMenuAction, TrayAction, TrayModel};
use eveo_core::model::AppLanguage;
use eveo_core::overlay::{OverlayLine, OverlayLink};
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

/// 浮窗菜单「滚动到最新」。
const OVERLAY_SCROLL: u32 = 201;
/// 浮窗菜单「复制这一条」。
const OVERLAY_COPY: u32 = 202;
/// 浮窗菜单「清空列表」。
const OVERLAY_CLEAR: u32 = 203;
/// 浮窗菜单「锁定布局」。
const OVERLAY_LOCK: u32 = 204;
/// 浮窗菜单「恢复默认位置与尺寸」。
const OVERLAY_RESET: u32 = 205;
/// 浮窗菜单「隐藏此浮窗」。
const OVERLAY_HIDE: u32 = 206;
/// 浮窗菜单「打开设置…」。
const OVERLAY_SETTINGS: u32 = 207;
/// 浮窗菜单「在浏览器中打开」子菜单里第一个链接的编号，其余按链接的顺序往后排。
const OVERLAY_LINK_BASE: u32 = 300;

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

/// 浮窗菜单选中的一项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OverlayChoice {
    /// 滚到底部，由浮窗自己处理。
    ScrollToLatest,
    /// 把这段文字放进剪贴板。
    Copy(String),
    /// 用默认浏览器打开这个地址（已检查是 https）。
    Open(String),
    /// 清空活动角色的列表，由聊天功能的总控处理。
    Clear,
    /// 改配置的动作，交给协调器。
    Coordinator(OverlayMenuAction),
}

/// 浮窗的右键菜单（设计文档 8.7 节的表）。line 是光标下的那一行：没有时「复制这一条」置灰；
/// 那一行没有链接时不显示「在浏览器中打开」，地址不是 https 的链接置灰。
pub fn overlay_menu(locked: bool, line: Option<&OverlayLine>, language: AppLanguage) -> Vec<MenuEntry> {
    let text = eveo_l10n::overlay(language);
    // 顺序与 macOS 相同：先是对列表的操作，再是对浮窗本身的操作，最后是设置。
    let mut entries = vec![
        MenuEntry::item(OVERLAY_SCROLL, text.menu_scroll_to_latest()),
        MenuEntry::Item {
            id: OVERLAY_COPY,
            text: text.menu_copy_line().to_owned(),
            enabled: line.is_some(),
            checked: false,
        },
    ];
    // 链接的编号按顺序从 OVERLAY_LINK_BASE 往后排，选中后按同一行的链接列表换回地址。
    if let Some(line) = line.filter(|l| !l.links.is_empty()) {
        let links = line
            .links
            .iter()
            .enumerate()
            .map(|(index, link)| MenuEntry::Item {
                id: OVERLAY_LINK_BASE + index as u32,
                text: link.title.clone(),
                enabled: browser_url(link).is_some(),
                checked: false,
            })
            .collect();
        entries.push(MenuEntry::Submenu {
            text: text.menu_open_in_browser().to_owned(),
            entries: links,
        });
    }
    entries.extend([
        MenuEntry::Separator,
        MenuEntry::item(OVERLAY_CLEAR, text.menu_clear()),
        MenuEntry::Item {
            id: OVERLAY_LOCK,
            text: text.menu_lock_layout().to_owned(),
            enabled: true,
            checked: locked,
        },
        MenuEntry::item(OVERLAY_RESET, text.menu_reset_frame()),
        MenuEntry::item(OVERLAY_HIDE, text.menu_hide()),
        MenuEntry::Separator,
        MenuEntry::item(OVERLAY_SETTINGS, text.menu_open_settings()),
    ]);
    entries
}

/// 浮窗菜单的编号换回选项。line 必须是弹菜单时用的同一行（菜单是模态的，期间不会变）。
pub fn overlay_choice(id: u32, line: Option<&OverlayLine>) -> Option<OverlayChoice> {
    Some(match id {
        OVERLAY_SCROLL => OverlayChoice::ScrollToLatest,
        OVERLAY_COPY => OverlayChoice::Copy(line?.copy_text.clone()),
        OVERLAY_CLEAR => OverlayChoice::Clear,
        OVERLAY_LOCK => OverlayChoice::Coordinator(OverlayMenuAction::ToggleLock),
        OVERLAY_RESET => OverlayChoice::Coordinator(OverlayMenuAction::ResetFrame),
        OVERLAY_HIDE => OverlayChoice::Coordinator(OverlayMenuAction::Hide),
        OVERLAY_SETTINGS => OverlayChoice::Coordinator(OverlayMenuAction::OpenSettings),
        _ => {
            let index = id.checked_sub(OVERLAY_LINK_BASE)? as usize;
            OverlayChoice::Open(browser_url(line?.links.get(index)?)?)
        }
    })
}

/// 链接的地址：去掉首尾空白后协议是 https（不分大小写）、主机名非空且整个地址不含空白时返回它，
/// 否则返回 None（不打开）。与 macOS 的 browserURL 一样只放行 https：浮窗里的链接由程序生成，
/// 这里再把一道关，免得任何别的协议（file:、自定义协议）经 ShellExecute 启动本地程序。
pub fn browser_url(link: &OverlayLink) -> Option<String> {
    let url = link.url.trim();
    let scheme = url.get(..8)?;
    if !scheme.eq_ignore_ascii_case("https://") || url.chars().any(char::is_whitespace) {
        return None;
    }
    // 主机名是协议之后、第一个 /、? 或 # 之前的部分；为空的地址（https:///…）不是有效的网址。
    let host = url[8..].split(['/', '?', '#']).next().unwrap_or("");
    (!host.is_empty()).then(|| url.to_owned())
}

#[cfg(test)]
mod tests {
    //! 浮窗菜单的链接检查与编号换回。

    use super::*;

    /// 只放行 https 且有主机名的地址。
    #[test]
    fn browser_url_accepts_https_only() {
        let link = |url: &str| OverlayLink {
            title: "zKillboard".to_owned(),
            url: url.to_owned(),
        };
        assert_eq!(
            browser_url(&link(" https://zkillboard.com/character/1/ ")).as_deref(),
            Some("https://zkillboard.com/character/1/")
        );
        assert!(browser_url(&link("HTTPS://evewho.com/")).is_some());
        assert!(browser_url(&link("http://zkillboard.com/")).is_none());
        assert!(browser_url(&link("file:///C:/Windows/notepad.exe")).is_none());
        assert!(browser_url(&link("https:///path")).is_none());
        assert!(browser_url(&link("https://a b.com/")).is_none());
    }

    /// 编号换回选项：复制与链接要有那一行。
    #[test]
    fn overlay_choice_needs_the_line() {
        assert_eq!(overlay_choice(OVERLAY_COPY, None), None);
        assert_eq!(overlay_choice(OVERLAY_LINK_BASE, None), None);
        assert_eq!(
            overlay_choice(OVERLAY_HIDE, None),
            Some(OverlayChoice::Coordinator(OverlayMenuAction::Hide))
        );
        assert_eq!(overlay_choice(9999, None), None);
    }
}
