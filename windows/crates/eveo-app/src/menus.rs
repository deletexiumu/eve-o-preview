// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图右键菜单、浮窗右键菜单与托盘菜单的内容，对应 macOS 的 ThumbnailContextMenu、OverlayContextMenu
// 与菜单栏菜单。
// 菜单项编号与动作一一对应；托盘菜单里的配置方案从 PROFILE_BASE 起按配置里的顺序编号。
// 文字按界面语言取自 eveo-l10n，与 macOS 的菜单栏菜单、缩略图右键菜单同一份文案。

use eveo_app_core::update::machine::MenuHint;
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
/// 托盘菜单「报告问题…」。
const TRAY_REPORT: u32 = 105;
/// 托盘菜单顶部的崩溃提示项。
const TRAY_CRASH: u32 = 106;
/// 托盘菜单顶部的更新提示项（「有可用更新…」或「重新启动以更新」）。
const TRAY_UPDATE_HINT: u32 = 107;
/// 托盘菜单「检查更新…」。
const TRAY_CHECK_UPDATES: u32 = 108;
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

/// 托盘菜单里随应用状态出现的项（协调器不知道的那部分）。
#[derive(Debug, Clone, PartialEq)]
pub struct TrayExtras {
    /// 上次崩溃且还没报告或选「不报告」。
    pub crash_pending: bool,
    /// 更新的提示项。
    pub update: MenuHint,
    /// 是否显示「检查更新…」（更新功能停用的构建没有这一项）。
    pub check_updates: bool,
}

/// 托盘菜单：（上次崩溃时的提示项、更新的提示项、）全部隐藏、最小化全部、配置方案（单选）、设置、
/// 报告问题、（检查更新、）退出。
pub fn tray_menu(model: &TrayModel, extras: &TrayExtras, language: AppLanguage) -> Vec<MenuEntry> {
    let text = eveo_l10n::menu(language);
    let diagnostics = eveo_l10n::diagnostics(language);
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
    // 上次崩溃且还没报告或选「不报告」时，菜单顶部多一项提示，与 macOS 的菜单栏菜单相同。
    // 顶部的提示项按紧急程度排：崩溃提示在前（用户可能想先报告），更新提示在后。
    // 两者都是「有事要你处理」的项，与常规项之间只放一条分隔线。
    let updates = eveo_l10n::updates(language);
    let mut entries = Vec::new();
    if extras.crash_pending {
        entries.push(MenuEntry::item(TRAY_CRASH, diagnostics.menu_crash_pending()));
    }
    // 有新版本时顶部多一项，与 macOS 的菜单栏菜单相同：已下载好时点了立即重新启动，否则显示更新窗口。
    match &extras.update {
        MenuHint::Available(version) => entries.push(MenuEntry::item(
            TRAY_UPDATE_HINT,
            updates.menu_update_available(version),
        )),
        MenuHint::Ready(version) => entries.push(MenuEntry::item(
            TRAY_UPDATE_HINT,
            updates.menu_restart_to_update(version),
        )),
        MenuHint::None => {}
    }
    // 提示项与常规项之间用一条分隔线隔开。
    if !entries.is_empty() {
        entries.push(MenuEntry::Separator);
    }
    // 其余各项与之前相同；「报告问题…」放在「设置」之后，与 macOS 的菜单栏菜单顺序一致。
    entries.extend([
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
        MenuEntry::item(TRAY_REPORT, diagnostics.menu_report_problem()),
    ]);
    // 「检查更新…」放在「报告问题…」之后、「退出」之前，与 macOS 菜单栏菜单的位置一致；
    // 更新功能停用的构建（没有检查地址）不显示，免得点了没有反应。
    if extras.check_updates {
        entries.push(MenuEntry::item(
            TRAY_CHECK_UPDATES,
            updates.menu_check_for_updates(),
        ));
    }
    entries.extend([MenuEntry::Separator, MenuEntry::item(TRAY_QUIT, text.quit())]);
    entries
}

/// 托盘菜单选中的项：交给协调器的动作，或由应用自己处理的报告窗口与更新。
#[derive(Debug, Clone, PartialEq)]
pub enum TrayChoice {
    /// 交给协调器。
    Coordinator(TrayAction),
    /// 打开报告窗口；crash 为真时是崩溃情境。
    Report {
        /// 是否为崩溃情境。
        crash: bool,
    },
    /// 更新的提示项：ready 为真时是「重新启动以更新」，否则是「有可用更新…」。
    UpdateHint {
        /// 新版是否已下载好。
        ready: bool,
    },
    /// 「检查更新…」。
    CheckUpdates,
}

/// 托盘菜单的编号换回动作。配置方案按弹出菜单时的列表换回 id。
pub fn tray_action(id: u32, model: &TrayModel, extras: &TrayExtras) -> Option<TrayChoice> {
    // 报告窗口与更新由应用自己处理，不经协调器：它们不改配置，也不影响缩略图。
    let action = match id {
        // 提示项的编号只有一个，含义取决于弹菜单时的提示：菜单是模态的，弹出期间提示不会变，
        // 但为了稳妥仍按同一份 extras 换回，没有提示时什么都不做。
        TRAY_UPDATE_HINT => {
            return match extras.update {
                MenuHint::Available(_) => Some(TrayChoice::UpdateHint { ready: false }),
                MenuHint::Ready(_) => Some(TrayChoice::UpdateHint { ready: true }),
                MenuHint::None => None,
            };
        }
        TRAY_CHECK_UPDATES => return Some(TrayChoice::CheckUpdates),
        TRAY_REPORT => return Some(TrayChoice::Report { crash: false }),
        TRAY_CRASH => return Some(TrayChoice::Report { crash: true }),
        TRAY_HIDE_ALL => TrayAction::ToggleHideAll,
        TRAY_MINIMIZE_ALL => TrayAction::MinimizeAll,
        TRAY_SETTINGS => TrayAction::OpenSettings,
        TRAY_QUIT => TrayAction::Quit,
        _ => {
            let index = id.checked_sub(PROFILE_BASE)? as usize;
            TrayAction::SwitchProfile(model.profiles.get(index)?.0.clone())
        }
    };
    Some(TrayChoice::Coordinator(action))
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
    //! 浮窗菜单的链接检查与编号换回；托盘菜单的崩溃提示项与报告项。

    use super::*;

    /// 托盘菜单：有待报告的崩溃时顶部多一项提示与分隔线；报告项与提示项换回报告窗口的两种情境，
    /// 其余项仍交给协调器。
    #[test]
    fn tray_report_items() {
        let model = TrayModel {
            profiles: Vec::new(),
            active_profile_id: String::new(),
            hide_all: false,
            client_count: 0,
        };
        let plain_extras = plain_extras();
        // 没有崩溃：第一项是「隐藏全部缩略图」。
        let plain = tray_menu(&model, &plain_extras, AppLanguage::En);
        assert!(matches!(
            plain[0],
            MenuEntry::Item {
                id: TRAY_HIDE_ALL,
                ..
            }
        ));
        // 有崩溃：提示项在最前，后面跟一条分隔线，其余项整体后移两格。
        let crash = extras(true, MenuHint::None, false);
        let pending = tray_menu(&model, &crash, AppLanguage::En);
        assert!(matches!(pending[0], MenuEntry::Item { id: TRAY_CRASH, .. }));
        assert!(matches!(pending[1], MenuEntry::Separator));
        assert_eq!(pending.len(), plain.len() + 2);
        // 编号换回：两种报告情境，以及交给协调器的「退出」。
        assert_eq!(
            tray_action(TRAY_CRASH, &model, &crash),
            Some(TrayChoice::Report { crash: true })
        );
        assert_eq!(
            tray_action(TRAY_REPORT, &model, &plain_extras),
            Some(TrayChoice::Report { crash: false })
        );
        assert_eq!(
            tray_action(TRAY_QUIT, &model, &plain_extras),
            Some(TrayChoice::Coordinator(TrayAction::Quit))
        );
        // 没有配置方案时，配置方案的编号换不回任何动作。
        assert_eq!(tray_action(PROFILE_BASE, &model, &plain_extras), None);
    }

    /// 托盘菜单的更新项：提示项在最前（崩溃提示之后），两种提示换回不同的操作；
    /// 「检查更新…」只在更新功能可用时出现，排在「报告问题…」之后。
    #[test]
    fn tray_update_items() {
        let model = TrayModel {
            profiles: Vec::new(),
            active_profile_id: String::new(),
            hide_all: false,
            client_count: 0,
        };
        let plain = tray_menu(&model, &extras(false, MenuHint::None, false), AppLanguage::En);
        // 有可用更新且能检查：多提示项、分隔线与「检查更新…」三项。
        let available = extras(false, MenuHint::Available("1.0.0".into()), true);
        let entries = tray_menu(&model, &available, AppLanguage::En);
        assert_eq!(entries.len(), plain.len() + 3);
        assert!(
            matches!(&entries[0], MenuEntry::Item { id: TRAY_UPDATE_HINT, text, .. } if text.contains("1.0.0"))
        );
        let check = entries.iter().position(|e| {
            matches!(
                e,
                MenuEntry::Item {
                    id: TRAY_CHECK_UPDATES,
                    ..
                }
            )
        });
        let report = entries
            .iter()
            .position(|e| matches!(e, MenuEntry::Item { id: TRAY_REPORT, .. }));
        assert_eq!(check, report.map(|index| index + 1));
        assert_eq!(
            tray_action(TRAY_UPDATE_HINT, &model, &available),
            Some(TrayChoice::UpdateHint { ready: false })
        );
        // 已下载好：同一编号换回「重新启动以更新」。
        let ready = extras(true, MenuHint::Ready("1.0.0".into()), true);
        let entries = tray_menu(&model, &ready, AppLanguage::En);
        assert!(matches!(entries[0], MenuEntry::Item { id: TRAY_CRASH, .. }));
        assert!(matches!(
            entries[1],
            MenuEntry::Item {
                id: TRAY_UPDATE_HINT,
                ..
            }
        ));
        assert!(matches!(entries[2], MenuEntry::Separator));
        assert_eq!(
            tray_action(TRAY_UPDATE_HINT, &model, &ready),
            Some(TrayChoice::UpdateHint { ready: true })
        );
        // 菜单弹出后提示消失（例如检查结果刚好到达）：编号换不回任何操作。
        assert_eq!(tray_action(TRAY_UPDATE_HINT, &model, &plain_extras()), None);
        assert_eq!(
            tray_action(TRAY_CHECK_UPDATES, &model, &available),
            Some(TrayChoice::CheckUpdates)
        );
    }

    /// 托盘菜单的附加项。
    fn extras(crash_pending: bool, update: MenuHint, check_updates: bool) -> TrayExtras {
        TrayExtras {
            crash_pending,
            update,
            check_updates,
        }
    }

    /// 没有任何附加项。
    fn plain_extras() -> TrayExtras {
        extras(false, MenuHint::None, false)
    }

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
