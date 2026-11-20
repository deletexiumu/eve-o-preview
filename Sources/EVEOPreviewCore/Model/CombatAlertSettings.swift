// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒的设置（反馈文档 3.1 节、7.7 节、7.8 节）。属于配置方案，JSON 路径是 profiles[].combatAlert。
// 取值范围由 ConfigValidator 夹取；style 用 LenientDecoding 解码，不认识的值取默认值。

import Foundation

/// 战斗提醒闪烁的样式。
public enum CombatAlertStyle: String, Sendable, Codable, CaseIterable {
    /// 只画一圈闪烁的边框。
    case border
    /// 只铺一层闪烁的底色。
    case wash
    /// 边框与底色都画，默认值。
    case both
}

/// 战斗提醒的设置。功能默认关闭，打开后才读游戏日志目录。
public struct CombatAlertSettings: Sendable, Equatable, Codable {
    /// 默认的闪烁颜色。
    public static let defaultColor = "#FF3B30"
    /// 持续时间的范围，单位是秒。
    public static let durationRange: ClosedRange<Double> = 1...10
    /// 最小伤害的范围。
    public static let minimumDamageRange: ClosedRange<Int> = 1...100_000

    /// 是否启用战斗提醒，默认 false。
    public var enabled: Bool
    /// 闪烁颜色，`#RRGGBB`，默认 `#FF3B30`；非法时由校验改回默认值。
    public var color: String
    /// 每次受击后闪烁的持续时间，单位是秒，默认 3.0，范围 1～10。
    public var durationSeconds: Double
    /// 闪烁样式，默认 `both`。
    public var style: CombatAlertStyle
    /// 对方开火但未命中时是否也提醒，默认 true。
    public var includeMisses: Bool
    /// 触发提醒的最小伤害，默认 1，范围 1～100,000。
    public var minimumDamage: Int

    /// 用各字段建战斗提醒设置，默认值见各属性。
    public init(enabled: Bool = false, color: String = CombatAlertSettings.defaultColor,
                durationSeconds: Double = 3.0, style: CombatAlertStyle = .both,
                includeMisses: Bool = true, minimumDamage: Int = 1) {
        self.enabled = enabled
        self.color = color
        self.durationSeconds = durationSeconds
        self.style = style
        self.includeMisses = includeMisses
        self.minimumDamage = minimumDamage
    }

    /// 解码时缺失的键取默认值；`style` 不认识或类型不对时取默认值，不抛错。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CombatAlertSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? d.durationSeconds
        style = LenientDecoding.value(CombatAlertStyle.self, in: c, forKey: .style, default: d.style)
        includeMisses = try c.decodeIfPresent(Bool.self, forKey: .includeMisses) ?? d.includeMisses
        minimumDamage = try c.decodeIfPresent(Int.self, forKey: .minimumDamage) ?? d.minimumDamage
    }
}
