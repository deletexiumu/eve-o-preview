// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」与「关于」两页的绑定。「通用」页的值都在配置的 general 里，与「预览与布局」页一样整页显示、整页读回；
// 「关于」页只有版本号与两条固定的链接。
// 链接由应用用默认浏览器打开，打开前用 is_about_link 核对，只认这里列出的地址。

//! 「通用」页与「关于」页。

use eveo_l10n::SettingsStrings;
use slint::ComponentHandle;

use eveo_core::frame_cap::{FrameCapSettings, FrameCapStatus, Vendor};
use eveo_core::logging::LogLevel;
use eveo_core::model::{AppLanguage, GeneralSettings, LanguagePreference};
use eveo_core::support::StringEnum;

use crate::{AboutModel, GeneralModel, SettingsWindow};

/// 「关于」页上的链接：上游项目与 GPL-3.0 全文。about.slint 里的地址必须与这里一致。
pub const ABOUT_LINKS: [&str; 2] = [
    "https://github.com/EveOPlus/eve-o-preview",
    "https://www.gnu.org/licenses/gpl-3.0.html",
];

/// 是否是「关于」页上的链接。应用只打开这些地址。
pub fn is_about_link(url: &str) -> bool {
    ABOUT_LINKS.contains(&url)
}

/// 把 general 显示到「通用」页。`log_path` 是日志文件夹的完整路径。
pub fn show_general(ui: &SettingsWindow, general: &GeneralSettings, log_path: &str) {
    let model = ui.global::<GeneralModel>();
    // 下拉框的顺序与 LanguagePreference 的声明顺序相同；找不到（不应出现）时显示「跟随系统」。
    let index = LanguagePreference::ALL
        .iter()
        .position(|&l| l == general.language)
        .unwrap_or(LanguagePreference::ALL.len() - 1);
    model.set_language(index as i32);
    model.set_check_updates(general.check_for_updates);
    model.set_auto_install(general.auto_install_updates);
    model.set_verbose_log(general.log_level == LogLevel::Debug);
    model.set_log_path(log_path.into());
    // 没有设置过限帧时按默认值显示（关闭、60 帧）。
    let frame_cap = general.frame_cap.clone().unwrap_or_default();
    model.set_frame_cap_enabled(frame_cap.enabled);
    model.set_frame_cap_fps(i32::try_from(frame_cap.fps).unwrap_or(60));
}

/// 「游戏帧率」一组的状态：能不能拨开关、开关下方的说明、AMD 的红字警告，以及 AMD、Intel 的「尚未实测」脚注。
/// 说明按 [`FrameCapStatus`]、显卡厂商与界面语言拼出。
pub fn show_frame_cap_status(
    ui: &SettingsWindow,
    status: FrameCapStatus,
    vendor: Option<Vendor>,
    language: AppLanguage,
) {
    let view = frame_cap_view(eveo_l10n::settings(language), status, vendor);
    let model = ui.global::<GeneralModel>();
    model.set_frame_cap_available(status.is_available());
    model.set_frame_cap_note(view.note.into());
    model.set_frame_cap_warning(view.warning.into());
    model.set_frame_cap_untested(view.untested);
}

/// 「游戏帧率」一组要显示的文字。
#[derive(Debug, PartialEq, Eq)]
struct FrameCapView {
    /// 开关下方的说明。
    note: String,
    /// 红字警告（AMD 是全局限帧）；没有时为空串。
    warning: String,
    /// 是否显示「AMD、Intel 尚未实测」的脚注。
    untested: bool,
}

/// 按状态与厂商求出要显示的文字。没有限帧时显示这家的默认说明（做法与关闭时还原）。
fn frame_cap_view(
    text: &dyn SettingsStrings,
    status: FrameCapStatus,
    vendor: Option<Vendor>,
) -> FrameCapView {
    let name = match vendor {
        Some(Vendor::Nvidia) | None => "NVIDIA",
        Some(Vendor::Amd) => "AMD",
        Some(Vendor::Intel) => "Intel",
    };
    let note = match (status, vendor) {
        (FrameCapStatus::Checking, _) => text.frame_cap_checking().to_owned(),
        (FrameCapStatus::Unsupported, _) => text.frame_cap_unsupported().to_owned(),
        (FrameCapStatus::Ready, Some(Vendor::Amd)) => text.frame_cap_help_amd().to_owned(),
        (FrameCapStatus::Ready, Some(Vendor::Intel)) => text.frame_cap_help_intel().to_owned(),
        (FrameCapStatus::Ready, _) => text.frame_cap_help().to_owned(),
        (FrameCapStatus::Applied(fps), Some(Vendor::Amd)) => text.frame_cap_applied_amd(i64::from(fps)),
        (FrameCapStatus::Applied(fps), _) => text.frame_cap_applied(i64::from(fps), name),
        (FrameCapStatus::NeedsAdmin, _) => text.frame_cap_needs_admin(name),
        // 不知道是哪家（子进程异常结束）：不提厂商名。
        (FrameCapStatus::Failed(code), None) => text.frame_cap_failed_unknown(i64::from(code)),
        (FrameCapStatus::Failed(code), Some(_)) => text.frame_cap_failed(i64::from(code), name),
    };
    let amd = vendor == Some(Vendor::Amd);
    FrameCapView {
        note,
        warning: if amd {
            text.frame_cap_amd_warning().to_owned()
        } else {
            String::new()
        },
        // 检测失败但不知道厂商时也提示：没有 NVIDIA 才会走到 AMD、Intel 的检测。
        untested: amd
            || vendor == Some(Vendor::Intel)
            || matches!((status, vendor), (FrameCapStatus::Failed(_), None)),
    }
}

/// 「通用」页更新一组的状态：当前版本、上次检查的时刻、一行状态、「立即检查」能否点。
/// 由应用层每秒调用一次；值没变时 Slint 不重画。
pub fn show_update_status(
    ui: &SettingsWindow,
    version: &str,
    last_checked: &str,
    status: &str,
    can_check: bool,
) {
    let model = ui.global::<GeneralModel>();
    model.set_update_version(version.into());
    model.set_update_last_checked(last_checked.into());
    model.set_update_status(status.into());
    model.set_update_can_check(can_check);
}

/// 「登录 Windows 时启动」的开关与说明。开关的状态来自注册表（不在配置里），note 为空串时显示默认说明。
pub fn show_launch_at_login(ui: &SettingsWindow, on: bool, note: &str) {
    let model = ui.global::<GeneralModel>();
    model.set_launch_at_login(on);
    model.set_launch_at_login_note(note.into());
}

/// 从「通用」页读回 general。没有出现在页上的字段（轮询间隔、日志目录等）保持不变。
pub fn read_general(ui: &SettingsWindow, general: &mut GeneralSettings) {
    let model = ui.global::<GeneralModel>();
    // 下标越界（不应出现）时不改语言。
    if let Some(&language) = usize::try_from(model.get_language())
        .ok()
        .and_then(|i| LanguagePreference::ALL.get(i))
    {
        general.language = language;
    }
    general.check_for_updates = model.get_check_updates();
    general.auto_install_updates = model.get_auto_install();
    // 开关只在 info 与 debug 之间切换（同 macOS）：打开是 debug；关上时只把 debug 改回 info。
    if model.get_verbose_log() {
        general.log_level = LogLevel::Debug;
    } else if general.log_level == LogLevel::Debug {
        general.log_level = LogLevel::Info;
    }
    // 限帧：页上的值与默认值相同且配置里本来没有这个键时保持 `None`，不往配置文件里多写一个键。
    let frame_cap = FrameCapSettings {
        enabled: model.get_frame_cap_enabled(),
        fps: i64::from(model.get_frame_cap_fps()),
    };
    if general.frame_cap.is_some() || frame_cap != FrameCapSettings::default() {
        general.frame_cap = Some(frame_cap);
    }
}

/// 填「关于」页：版本号取工作区的版本（各 crate 共用一个版本号）。
pub fn show_about(ui: &SettingsWindow) {
    ui.global::<AboutModel>()
        .set_version(env!("CARGO_PKG_VERSION").into());
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// 页面内容：显示再读回不变；用户的改动写回 general，页上没有的字段不动。由 bind 的 Slint 用例调用。
    pub(crate) fn check_page(ui: &SettingsWindow) {
        let original = GeneralSettings {
            language: LanguagePreference::Ja,
            check_for_updates: false,
            log_level: LogLevel::Debug,
            poll_interval_ms: 700,
            ..GeneralSettings::default()
        };
        show_general(ui, &original, "C:\\logs");
        let model = ui.global::<GeneralModel>();
        assert_eq!(model.get_language(), 3);
        assert!(model.get_verbose_log());
        assert_eq!(model.get_log_path(), "C:\\logs");
        let mut read = original.clone();
        read_general(ui, &mut read);
        assert_eq!(read, original);

        // 选「跟随系统」、关掉详细日志、打开自动检查。
        model.set_language(8);
        model.set_verbose_log(false);
        model.set_check_updates(true);
        let mut edited = original.clone();
        read_general(ui, &mut edited);
        assert_eq!(edited.language, LanguagePreference::System);
        assert_eq!(edited.log_level, LogLevel::Info);
        assert!(edited.check_for_updates);
        assert_eq!(edited.poll_interval_ms, 700);

        // 限帧：没设置过时读回仍是 None；打开开关、改帧数后写进配置。
        assert_eq!(edited.frame_cap, None);
        assert!(!model.get_frame_cap_enabled());
        assert_eq!(model.get_frame_cap_fps(), 60);
        model.set_frame_cap_enabled(true);
        model.set_frame_cap_fps(75);
        read_general(ui, &mut edited);
        assert_eq!(
            edited.frame_cap,
            Some(FrameCapSettings {
                enabled: true,
                fps: 75
            })
        );
        // 状态：不支持时开关不能拨；AMD 时有红字警告与「尚未实测」脚注，NVIDIA 没有。
        show_frame_cap_status(ui, FrameCapStatus::Unsupported, None, AppLanguage::En);
        assert!(!model.get_frame_cap_available());
        assert!(model.get_frame_cap_warning().is_empty());
        show_frame_cap_status(
            ui,
            FrameCapStatus::Applied(75),
            Some(Vendor::Amd),
            AppLanguage::En,
        );
        assert!(model.get_frame_cap_available());
        assert!(!model.get_frame_cap_warning().is_empty());
        assert!(model.get_frame_cap_untested());
        assert!(model.get_frame_cap_note().contains("75"));
        show_frame_cap_status(
            ui,
            FrameCapStatus::Applied(75),
            Some(Vendor::Nvidia),
            AppLanguage::En,
        );
        assert!(model.get_frame_cap_warning().is_empty());
        assert!(!model.get_frame_cap_untested());

        // 「关于」页：版本号非空；只认列出的链接。
        show_about(ui);
        assert!(!ui.global::<AboutModel>().get_version().is_empty());
        assert!(is_about_link(ABOUT_LINKS[0]));
        assert!(!is_about_link("https://example.com"));
    }

    /// about.slint 里写的链接与 ABOUT_LINKS 一致：改了一边忘了另一边时，链接会打不开。
    #[test]
    fn about_links_match_page() {
        let page = include_str!("../ui/about.slint");
        for link in ABOUT_LINKS {
            assert!(page.contains(&format!("url: \"{link}\";")), "{link}");
        }
    }
}
