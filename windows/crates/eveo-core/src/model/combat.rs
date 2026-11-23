// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒的设置，对应 macOS 的 Model/CombatAlertSettings.swift。属于配置方案，JSON 路径是 profiles[].combatAlert。
// 取值范围由配置校验夹取；style 用宽松解码，不认识的值取默认值。

string_enum! {
    /// 战斗提醒闪烁的样式。
    pub enum CombatAlertStyle {
        /// 只画一圈闪烁的边框。
        Border => "border",
        /// 只铺一层闪烁的底色。
        Wash => "wash",
        /// 边框与底色都画，默认值。
        Both => "both",
    }
}

/// 默认的闪烁颜色。
pub const COMBAT_ALERT_DEFAULT_COLOR: &str = "#FF3B30";
/// 持续时间的范围，单位是秒。
pub const COMBAT_ALERT_DURATION_RANGE: (f64, f64) = (1.0, 10.0);
/// 最小伤害的范围。
pub const COMBAT_ALERT_MINIMUM_DAMAGE_RANGE: (i64, i64) = (1, 100_000);

config_struct! {
    /// 战斗提醒的设置。功能默认关闭，打开后才读游戏日志目录。
    pub struct CombatAlertSettings via CombatAlertSettingsRaw {
        /// 是否启用战斗提醒，默认 false。
        req enabled: bool = false, "enabled";
        /// 闪烁颜色，`#RRGGBB`，默认 `#FF3B30`；非法时由校验改回默认值。
        req color: String = COMBAT_ALERT_DEFAULT_COLOR.to_owned(), "color";
        /// 每次受击后闪烁的持续时间，单位是秒，默认 3.0，范围 1～10。
        req duration_seconds: f64 = 3.0, "durationSeconds";
        /// 闪烁样式，默认 `both`。
        lenient style: CombatAlertStyle = CombatAlertStyle::Both, "style";
        /// 对方开火但未命中时是否也提醒，默认 true。
        req include_misses: bool = true, "includeMisses";
        /// 触发提醒的最小伤害，默认 1，范围 1～100,000。
        req minimum_damage: i64 = 1, "minimumDamage";
    }
}
