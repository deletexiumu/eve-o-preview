// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的绑定：当前方案的 combatAlert 与全局的 general.eveLogDirectory。与「预览与布局」页一样整页显示、整页读回；
// 颜色只在输入完整的 #RRGGBB 时写回，数值按配置的取值范围与步长取整（越界的值最终还会被配置校验夹回）。

//! 「提醒」页。

use slint::{Color, ComponentHandle};

use eveo_core::model::{CombatAlertStyle, GeneralSettings, Profile};
use eveo_core::support::StringEnum;

use crate::bind::{normalized_hex, swatch};
use crate::{AlertsModel, SettingsWindow};

/// 把战斗提醒设置与日志目录显示到页上。`automatic` 是自动查找时的位置，显示为输入框的提示。
pub fn show_alerts(ui: &SettingsWindow, profile: &Profile, general: &GeneralSettings, automatic: &str) {
    let model = ui.global::<AlertsModel>();
    let alert = &profile.combat_alert;
    model.set_enabled(alert.enabled);
    // 日志目录：没有指定时输入框留空，提示自动查找的位置。正在输入的文字与配置相同时不重写（不打扰光标）。
    let directory = general.eve_log_directory.clone().unwrap_or_default();
    if model.get_log_directory() != directory.as_str() {
        model.set_log_directory(directory.into());
    }
    model.set_automatic_directory(
        eveo_l10n::combat(crate::language())
            .automatic_path(automatic)
            .into(),
    );
    // 颜色：输入框里大小写不同视为相同，不改用户正在输入的文字。
    let text = normalized_hex(&alert.color).unwrap_or_else(|| alert.color.clone());
    if !model.get_color().eq_ignore_ascii_case(&text) {
        model.set_color(text.into());
    }
    // 解析不了时样本用灰色，提示这个值没被采用（同「预览与布局」页）。
    model.set_swatch(swatch(&alert.color).unwrap_or(Color::from_rgb_u8(0x80, 0x80, 0x80)));
    model.set_duration(alert.duration_seconds as f32);
    // 下拉框的顺序与 CombatAlertStyle 的声明顺序相同：边框、底色、两者。
    let style = CombatAlertStyle::ALL
        .iter()
        .position(|&s| s == alert.style)
        .unwrap_or(2);
    model.set_style(style as i32);
    model.set_include_misses(alert.include_misses);
    // 最小伤害在配置里是 i64，范围 1～100,000，放得进 i32。
    model.set_minimum_damage(alert.minimum_damage.clamp(1, 100_000) as i32);
}

/// 从页上读回战斗提醒设置与日志目录。页上没有的字段保持不变。
pub fn read_alerts(ui: &SettingsWindow, profile: &mut Profile, general: &mut GeneralSettings) {
    let model = ui.global::<AlertsModel>();
    let alert = &mut profile.combat_alert;
    alert.enabled = model.get_enabled();
    // 日志目录：去掉首尾空白后为空表示自动查找（与配置校验的规则相同）。
    let directory = model.get_log_directory();
    let trimmed = directory.trim();
    general.eve_log_directory = (!trimmed.is_empty()).then(|| trimmed.to_owned());
    // 颜色输入到一半时保留原值。
    if let Some(hex) = normalized_hex(&model.get_color()) {
        alert.color = hex;
    }
    // 步长 0.5 秒：滑块拖动时可能停在中间值，这里取最近的半秒。
    alert.duration_seconds = (f64::from(model.get_duration()) * 2.0).round() / 2.0;
    // 下拉框没有选中项（-1）时保留原来的样式。
    if let Some(&style) = usize::try_from(model.get_style())
        .ok()
        .and_then(|i| CombatAlertStyle::ALL.get(i))
    {
        alert.style = style;
    }
    alert.include_misses = model.get_include_misses();
    alert.minimum_damage = i64::from(model.get_minimum_damage());
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// 页面内容：显示再读回不变；用户的改动按规则写回。由 bind 的 Slint 用例调用。
    pub(crate) fn check_page(ui: &SettingsWindow) {
        let mut profile = Profile::make_new("p", "P");
        profile.combat_alert.enabled = true;
        profile.combat_alert.style = CombatAlertStyle::Wash;
        profile.combat_alert.minimum_damage = 250;
        let general = GeneralSettings {
            eve_log_directory: Some("D:\\EVE\\logs".to_owned()),
            ..GeneralSettings::default()
        };
        show_alerts(ui, &profile, &general, "C:\\Docs\\EVE\\logs");
        let model = ui.global::<AlertsModel>();
        assert_eq!(model.get_style(), 1);
        assert_eq!(model.get_log_directory(), "D:\\EVE\\logs");
        let (mut read_profile, mut read_general) = (profile.clone(), general.clone());
        read_alerts(ui, &mut read_profile, &mut read_general);
        assert_eq!((read_profile, read_general), (profile.clone(), general.clone()));

        // 清空目录（回到自动查找）、小写颜色、滑块停在中间值、选「两者」。
        model.set_log_directory("   ".into());
        model.set_color("#00ff00".into());
        model.set_duration(4.3);
        model.set_style(2);
        let (mut edited, mut edited_general) = (profile.clone(), general.clone());
        read_alerts(ui, &mut edited, &mut edited_general);
        assert_eq!(edited_general.eve_log_directory, None);
        assert_eq!(edited.combat_alert.color, "#00FF00");
        assert_eq!(edited.combat_alert.duration_seconds, 4.5);
        assert_eq!(edited.combat_alert.style, CombatAlertStyle::Both);

        // 颜色输到一半：不写回。
        model.set_color("#12".into());
        let mut partial = profile.clone();
        read_alerts(ui, &mut partial, &mut general.clone());
        assert_eq!(partial.combat_alert.color, profile.combat_alert.color);
    }
}
