// SPDX-License-Identifier: GPL-3.0-or-later
//
// 锁定布局的视觉特效规则（与 Windows 的 eveo-app-core/src/lock_effect.rs 保持一致）：
// - 锁定特效全部画在缩略图外圈边框（活动高亮或中性边框）之内侧，外圈边框原样保留、不被覆盖，
//   确保「锁定布局」与「活动窗口高亮」两种效果清晰叠加。
// - 开启瞬间（从未锁定切到锁定）播放合拢锁扣 + 内圈脉冲 + 对角流光扫过；
//   锁定期间持续播放轻量呼吸角标与内圈流光巡游；关闭系统动画时静止显示。

import Foundation

/// 锁定布局视觉特效的纯计算规则与参数常量。
public enum LockEffectRules {
    /// 主色：战术青蓝 `#38BDF8`，与默认黄绿高亮、银灰中性边框与红色战斗提醒均区分明显。
    public static let accentHex = "#38BDF8"
    /// 开启瞬间与流光头部的亮青白高光色 `#BAE6FD`。
    public static let flashHex = "#BAE6FD"
    /// 四角 L 型锁扣的线宽（点）。
    public static let clampStrokeWidth: Double = 2.0
    /// 内圈微光边线的线宽（点）。
    public static let hairlineStrokeWidth: Double = 1.0
    /// 四角锁扣距内侧边界的留白（点），使锁扣与外圈活动高亮边框之间有清晰层次。
    public static let clampGap: Double = 2.0
    /// 开启瞬间锁扣向四角卡紧前的初始内缩偏移（点）。
    public static let engageStartOffset: Double = 6.0
    /// 开启瞬间合拢动画时长（秒）。
    public static let engageDuration: Double = 0.45
    /// 开启瞬间对角流光扫过时长（秒）。
    public static let sheenDuration: Double = 0.55
    /// 持续呼吸动画单程时长（秒）：完整周期 3.0 秒。
    public static let breathHalfPeriod: Double = 1.5
    /// 持续呼吸的不透明度区间：低点与高点。
    public static let breathMinOpacity: Double = 0.55
    /// 持续呼吸的不透明度高点。
    public static let breathMaxOpacity: Double = 0.95
    /// 减弱动态效果时的静态锁扣不透明度。
    public static let staticClampOpacity: Double = 0.85
    /// 内圈微光边线在常驻状态下的不透明度。
    public static let steadyHairlineOpacity: Double = 0.24
    /// 减弱动态效果时的静态内圈微光边线不透明度。
    public static let staticHairlineOpacity: Double = 0.30
    /// 内圈流光沿周长巡游一周的周期（秒）。
    public static let glintPeriod: Double = 4.0
    /// 流光弧段占整个内圈周长的比例。
    public static let glintFraction: Double = 0.18

    /// 计算缩略图外圈边框占用的内缩宽度（点），与边框层的取值顺序完全一致：
    /// 1. 活动高亮已开启且颜色有效：取高亮边框粗细；
    /// 2. 否则中性边框已开启且颜色有效：取中性边框粗细；
    /// 3. 否则为 0。
    /// 锁定特效图层整体向内缩进该宽度，保证外圈活动高亮边框完整可见。
    public static func borderInset(for presentation: ThumbnailPresentation) -> Double {
        if let highlight = presentation.highlightColor, HexColor.components(highlight) != nil {
            return max(0, presentation.highlightThickness)
        }
        if let neutral = presentation.borderColor, HexColor.components(neutral) != nil {
            return max(0, presentation.borderThickness)
        }
        return 0
    }

    /// 计算四角 L 型锁扣的臂长（点）：取内框短边的 14%，限制在 10～18 点之间；
    /// 缩略图极小时不超过内框可用宽度的一半，避免相邻角标重叠。
    public static func cornerArmLength(innerWidth: Double, innerHeight: Double) -> Double {
        let shortSide = min(innerWidth, innerHeight)
        guard shortSide > 0 else { return 0 }
        let preferred = min(18.0, max(10.0, shortSide * 0.14))
        let maximumSafe = max(0, shortSide / 2.0 - clampGap - 1.0)
        return min(preferred, maximumSafe)
    }

    /// 判断本次呈现更新是否应触发开启瞬间动画：仅当此前已应用过呈现、且状态从「未锁定」切为「已锁定」时触发。
    /// 应用启动时本来就处于锁定状态，或锁定期间仅切换活动窗口，不重复播放开启瞬间动画。
    public static func shouldTriggerEngage(previousLocked: Bool?, newLocked: Bool) -> Bool {
        previousLocked == false && newLocked
    }
}
