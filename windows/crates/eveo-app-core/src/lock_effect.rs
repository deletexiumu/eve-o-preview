// SPDX-License-Identifier: GPL-3.0-or-later
//
// 锁定布局特效的动画曲线与几何参数，对应 macOS 的 LockEffectRules 与 LockEffectLayer：
// - 开启瞬间（从 false 切到 true）：四角锁扣从内侧偏移向四角卡紧锁定（0.45 秒缓出）、内圈脉冲高光、
//   对角流光自左上向右下扫过（0.55 秒）。
// - 锁定常驻期间：四角战术锁扣按 3.0 秒周期柔和呼吸（不透明度 0.55～0.95），
//   一条青蓝流光按 4.0 秒周期沿内圈周长顺时针巡游。
// - 全部图形都绘制在缩略图外圈边框（活动高亮或中性边框）之内侧，外圈活动高亮效果原样保留、
//   与锁定特效叠加共存。
// - 系统关掉界面动画效果时返回固定的静态帧 `LockFrame::STATIC`，不触发逐帧重绘。

//! 锁定布局特效的动画曲线。

use std::f64::consts::PI;

/// 主色：战术青蓝 `#38BDF8`，与黄绿活动高亮、银灰中性边框与红色战斗提醒均区分明显。
pub const ACCENT_RGB: u32 = 0x38_BD_F8;
/// 开启瞬间与流光头部的亮青白高光色 `#BAE6FD`。
pub const FLASH_RGB: u32 = 0xBA_E6_FD;
/// 开启瞬间锁扣向四角卡紧前的初始内缩偏移（DIP）。
pub const ENGAGE_START_OFFSET: f64 = 6.0;
/// 开启瞬间锁扣合拢与脉冲时长（秒）。
pub const ENGAGE_DURATION: f64 = 0.45;
/// 开启瞬间对角流光扫过时长（秒）。
pub const SHEEN_DURATION: f64 = 0.55;
/// 呼吸动画单程时长（秒）：完整周期 3.0 秒。
pub const BREATH_HALF_PERIOD: f64 = 1.5;
/// 呼吸不透明度低点。
pub const BREATH_MIN_ALPHA: f64 = 0.55;
/// 呼吸不透明度高点。
pub const BREATH_MAX_ALPHA: f64 = 0.95;
/// 内圈微光边线在常驻状态下的不透明度。
pub const STEADY_HAIRLINE_ALPHA: f64 = 0.24;
/// 内圈微光边线在开启瞬间的峰值不透明度。
pub const ENGAGE_HAIRLINE_ALPHA: f64 = 0.85;
/// 内圈流光巡游一周的周期（秒）。
pub const GLINT_PERIOD: f64 = 4.0;
/// 流光弧段占整个内圈周长的比例。
pub const GLINT_FRACTION: f64 = 0.18;

/// 某一时刻锁定布局特效的动画采样帧。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LockFrame {
    /// 四角锁扣相对稳态位置向内展开的额外偏移（DIP，0 表示已合拢就位）。
    pub clamp_offset: f32,
    /// 四角锁扣的不透明度（0～1）。
    pub clamp_alpha: f32,
    /// 内圈微光边线的不透明度（0～1）。
    pub hairline_alpha: f32,
    /// 高光混色比例（0 = 纯主色 `#38BDF8`，1 = 亮青白 `#BAE6FD`）。
    pub flash_mix: f32,
    /// 内圈巡游流光的相位（0～1，按顺时针绕周长一圈）；减弱动态效果时为 `None`。
    pub glint_phase: Option<f32>,
    /// 开启瞬间对角流光扫过的进度（0～1）；扫过结束后或减弱动态效果时为 `None`。
    pub sheen_progress: Option<f32>,
}

impl LockFrame {
    /// 系统关闭动画效果时的静态帧：锁扣就位、无流光与扫光，平台层因此只在状态变化时画一次。
    pub const STATIC: Self = Self {
        clamp_offset: 0.0,
        clamp_alpha: 0.85,
        hairline_alpha: 0.30,
        flash_mix: 0.0,
        glint_phase: None,
        sheen_progress: None,
    };
}

/// 按当前单调时钟 `now`（秒）、最近一次由未锁定切为锁定的时刻 `locked_since` 与系统是否开启动画，
/// 采样当前帧的锁定特效参数。
///
/// 采样结果由三个相互独立的时间轨道合成：
/// 1. 开启瞬间轨道（`0..ENGAGE_DURATION`）：锁扣从 `ENGAGE_START_OFFSET` 缓出合拢到 0，高光混色与内圈脉冲同步回落；
/// 2. 对角扫光轨道（`0..SHEEN_DURATION`）：二次缓出推动倾斜光带横扫内框，结束后返回 `None`；
/// 3. 常驻循环轨道：余弦呼吸驱动四角锁扣不透明度，线性相位驱动内圈巡游流光，所有缩略图共享同一时钟以保持同步。
pub fn sample(now: f64, locked_since: Option<f64>, animated: bool) -> LockFrame {
    if !animated {
        return LockFrame::STATIC;
    }
    // 开启瞬间的合拢、高光混色与内圈脉冲（0～ENGAGE_DURATION 秒）。
    let engage_elapsed = locked_since.map(|since| now - since);
    let (clamp_offset, flash_mix, hairline_boost, clamp_boost) = match engage_elapsed {
        Some(elapsed) if (0.0..ENGAGE_DURATION).contains(&elapsed) => {
            let t = elapsed / ENGAGE_DURATION;
            // 三次缓出：起手迅捷合拢，末端轻柔落位。
            let remain = (1.0 - t).powi(3);
            (
                ENGAGE_START_OFFSET * remain,
                remain,
                (ENGAGE_HAIRLINE_ALPHA - STEADY_HAIRLINE_ALPHA) * remain,
                remain,
            )
        }
        _ => (0.0, 0.0, 0.0, 0.0),
    };
    // 开启瞬间的对角流光扫过（0～SHEEN_DURATION 秒）。
    let sheen_progress = match engage_elapsed {
        Some(elapsed) if (0.0..SHEEN_DURATION).contains(&elapsed) => {
            let t = elapsed / SHEEN_DURATION;
            // 二次缓出，让光带切入干脆、尾部轻散。
            let eased = 1.0 - (1.0 - t).powi(2);
            Some(eased as f32)
        }
        _ => None,
    };
    // 常驻呼吸曲线：用统一单调时钟，所有锁定缩略图步调一致。
    let breath_period = 2.0 * BREATH_HALF_PERIOD;
    let breath_t = now.rem_euclid(breath_period);
    let wave = 0.5 - 0.5 * (2.0 * PI * breath_t / breath_period).cos();
    let steady_clamp = BREATH_MIN_ALPHA + wave * (BREATH_MAX_ALPHA - BREATH_MIN_ALPHA);
    // 开启瞬间把锁扣亮度抬到 1.0，再平滑回落到呼吸曲线。
    let clamp_alpha = steady_clamp + (1.0 - steady_clamp) * clamp_boost;
    let hairline_alpha = STEADY_HAIRLINE_ALPHA + hairline_boost;
    // 内圈巡游流光的相位：以开启时刻或时钟零点为基准顺时针循环。
    let origin = locked_since.unwrap_or(0.0);
    let glint_phase = ((now - origin).rem_euclid(GLINT_PERIOD) / GLINT_PERIOD) as f32;
    LockFrame {
        clamp_offset: clamp_offset as f32,
        clamp_alpha: clamp_alpha.clamp(0.0, 1.0) as f32,
        hairline_alpha: hairline_alpha.clamp(0.0, 1.0) as f32,
        flash_mix: flash_mix.clamp(0.0, 1.0) as f32,
        glint_phase: Some(glint_phase),
        sheen_progress,
    }
}

/// 仅当此前已完成过初始化且状态从未锁定切为锁定时，触发开启瞬间动画。
pub fn should_trigger_engage(has_applied: bool, was_locked: bool, is_locked: bool) -> bool {
    has_applied && !was_locked && is_locked
}

/// 矩形周长上的一段不跨拐角的子区间：`[local_start, local_end]` 位于同一条边内（顺时针）。
///
/// 与平台层 `eveo-platform-win/src/overlay_lock.rs` 的 `draw_perimeter_arc` 使用同一切分算法，
/// 便于在非 Windows 宿主上通过单元测试覆盖负起点靠近 0 时的 IEEE-754 `f32::rem_euclid` 舍入边界。
pub fn perimeter_spans(w: f32, h: f32, start: f32, end: f32) -> Vec<(f32, f32)> {
    let mut spans = Vec::new();
    let perimeter = 2.0 * (w + h);
    if !(w > 0.0 && h > 0.0 && perimeter.is_finite() && start.is_finite() && end.is_finite()) {
        return spans;
    }
    let corners = [0.0, w, w + h, 2.0 * w + h, perimeter];
    let mut cursor = start;
    // 单条流光弧段长度短于整圈周长，最多跨过 4 个拐角；设 8 次硬上限保证任何浮点舍入下都不可能死循环。
    for _ in 0..8 {
        if cursor >= end - 1e-3 {
            break;
        }
        // `f32::rem_euclid` 对极小负数（如 -1e-5）加 perimeter 可能舍入成精确等于 perimeter，归零防停滞。
        let raw = cursor.rem_euclid(perimeter);
        let local = if raw >= perimeter - 1e-3 { 0.0 } else { raw };
        let next_corner = corners
            .iter()
            .copied()
            .find(|&c| c > local + 1e-3)
            .unwrap_or(perimeter);
        let advance = (next_corner - local).min(end - cursor);
        if !advance.is_finite() || advance <= 1e-5 {
            break;
        }
        spans.push((local, local + advance));
        cursor += advance;
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个浮点在容差内视为相等。
    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-4
    }

    /// 关闭动画时返回固定静态帧，不带流光与扫光。
    #[test]
    fn reduced_motion_returns_static_frame() {
        let frame = sample(10.1, Some(10.0), false);
        assert_eq!(frame, LockFrame::STATIC);
        assert_eq!(frame.glint_phase, None);
        assert_eq!(frame.sheen_progress, None);
        assert_eq!(frame.clamp_offset, 0.0);
    }

    /// 开启瞬间：t=0 时偏移最大、高光全亮、对角扫光启动；结束后回到稳态呼吸与流光。
    #[test]
    fn engage_burst_settles_into_steady_animation() {
        let start = sample(10.0, Some(10.0), true);
        assert!(close(start.clamp_offset, ENGAGE_START_OFFSET as f32));
        assert!(close(start.clamp_alpha, 1.0));
        assert!(close(start.hairline_alpha, ENGAGE_HAIRLINE_ALPHA as f32));
        assert!(close(start.flash_mix, 1.0));
        assert_eq!(start.sheen_progress, Some(0.0));
        assert!(start.glint_phase.is_some());

        let mid = sample(10.225, Some(10.0), true);
        assert!(mid.clamp_offset > 0.0 && mid.clamp_offset < ENGAGE_START_OFFSET as f32);
        assert!(mid.sheen_progress.is_some_and(|p| p > 0.0 && p < 1.0));

        let settled = sample(11.0, Some(10.0), true);
        assert!(close(settled.clamp_offset, 0.0));
        assert!(close(settled.flash_mix, 0.0));
        assert!(close(settled.hairline_alpha, STEADY_HAIRLINE_ALPHA as f32));
        assert_eq!(settled.sheen_progress, None);
        assert!(
            (BREATH_MIN_ALPHA as f32 - 1e-4..=BREATH_MAX_ALPHA as f32 + 1e-4).contains(&settled.clamp_alpha)
        );
    }

    /// 呼吸曲线在整周期内平滑往返，巡游流光相位始终在 [0, 1) 内循环。
    #[test]
    fn ambient_breath_and_glint_stay_bounded() {
        let trough = sample(0.0, None, true);
        let peak = sample(BREATH_HALF_PERIOD, None, true);
        assert!(close(trough.clamp_alpha, BREATH_MIN_ALPHA as f32));
        assert!(close(peak.clamp_alpha, BREATH_MAX_ALPHA as f32));
        for step in 0..=80 {
            let now = f64::from(step) * 0.13;
            let frame = sample(now, Some(1.0), true);
            assert!((0.0..=1.0).contains(&frame.clamp_alpha));
            assert!((0.0..=1.0).contains(&frame.hairline_alpha));
            let phase = frame.glint_phase.expect("开启动画时应有流光相位");
            assert!((0.0..1.0).contains(&phase), "{phase}");
        }
    }

    /// 仅在已初始化后由未锁定变为锁定时触发开启瞬间动画。
    #[test]
    fn engage_trigger_only_on_false_to_true() {
        assert!(should_trigger_engage(true, false, true));
        assert!(!should_trigger_engage(false, false, true));
        assert!(!should_trigger_engage(true, true, true));
        assert!(!should_trigger_engage(true, true, false));
        assert!(!should_trigger_engage(true, false, false));
    }

    /// 极小负数起点（`rem_euclid` 会舍入到等于 `perimeter`）与跨零绕圈区间都能有限次收敛并覆盖正确总长。
    #[test]
    fn perimeter_spans_handles_tiny_negative_and_wraparound() {
        // 384×216 扣边框后的典型内框（周长 1160.0）：-1e-5_f32.rem_euclid(1160.0) == 1160.0。
        let spans = perimeter_spans(374.0, 206.0, -1e-5_f32, 20.0_f32);
        assert!(!spans.is_empty());
        let total: f32 = spans.iter().map(|(a, b)| b - a).sum();
        assert!((total - 20.0).abs() < 1e-2, "total={total}, spans={spans:?}");

        // 跨越右下/左下/左上角并绕回顶边的区间，每段都不跨拐角且总长守恒。
        let wrapped = perimeter_spans(374.0, 206.0, -50.0, 40.0);
        assert_eq!(wrapped.len(), 2);
        assert!((wrapped[0].0 - 1110.0).abs() < 1e-2 && (wrapped[0].1 - 1160.0).abs() < 1e-2);
        assert!((wrapped[1].0 - 0.0).abs() < 1e-2 && (wrapped[1].1 - 40.0).abs() < 1e-2);

        // 非法或 NaN 输入直接返回空，不 panic 不死循环。
        assert!(perimeter_spans(0.0, 100.0, 0.0, 10.0).is_empty());
        assert!(perimeter_spans(100.0, 100.0, f32::NAN, 10.0).is_empty());
    }
}
