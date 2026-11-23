// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒的闪烁曲线，对应 macOS 的 AlertFlashLayer（反馈文档 7.8 节）。
// macOS 把闪烁交给 Core Animation：不透明度在 1.0 与 0.15 之间来回，单程 0.25 秒，自动反向，缓入缓出。
// Windows 的叠加层没有这样的动画服务，由应用的定时器逐帧取这条曲线的值、重画提醒层。
// 频率固定为每秒 2 次（低于 WCAG 2.3.1 的每秒 3 次），不做成配置项；系统关掉动画时调用方取 1.0 静止显示。

//! 战斗提醒的闪烁曲线。

/// 闪烁时不透明度的低点。
pub const DIM: f64 = 0.15;
/// 单程时长（秒）：一个来回 0.5 秒，每秒闪 2 次。
pub const HALF_PERIOD: f64 = 0.25;

/// 时刻 `now`（秒，任意起点的单调时钟）的提醒强度，在 `DIM`～1.0 之间。
///
/// 每个周期从 1.0 开始，前半程缓入缓出地降到 `DIM`，后半程再升回 1.0。
/// 所有缩略图共用同一个时钟，同时提醒的几个缩略图步调一致。
pub fn intensity(now: f64) -> f64 {
    let period = 2.0 * HALF_PERIOD;
    let t = now.rem_euclid(period);
    // 0 → 1 → 0 的三角波，再套上缓入缓出（半个余弦）。
    let progress = if t < HALF_PERIOD {
        t / HALF_PERIOD
    } else {
        (period - t) / HALF_PERIOD
    };
    let eased = (1.0 - (std::f64::consts::PI * progress).cos()) / 2.0;
    1.0 - eased * (1.0 - DIM)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个数在 1e-9 以内视为相等。
    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    /// 周期的起点是最亮，半周期处最暗，整周期回到最亮。
    #[test]
    fn peaks_and_trough() {
        assert!(close(intensity(0.0), 1.0));
        assert!(close(intensity(HALF_PERIOD), DIM));
        assert!(close(intensity(2.0 * HALF_PERIOD), 1.0));
        assert!(close(intensity(10.0 + HALF_PERIOD), DIM));
    }

    /// 曲线对半周期对称（自动反向），四分之一处正好在中点（缓入缓出的对称性）。
    #[test]
    fn symmetric_and_eased() {
        for step in 0..=25 {
            let t = f64::from(step) / 100.0;
            assert!(close(intensity(t), intensity(2.0 * HALF_PERIOD - t)));
        }
        assert!(close(intensity(HALF_PERIOD / 2.0), (1.0 + DIM) / 2.0));
        // 缓入：起点附近变化很慢。
        assert!(intensity(0.01) > 0.99);
    }

    /// 取值始终在 DIM～1.0 之间，负的时刻也一样。
    #[test]
    fn stays_in_range() {
        for step in -100..=100 {
            let value = intensity(f64::from(step) * 0.037);
            assert!((DIM - 1e-9..=1.0 + 1e-9).contains(&value), "{value}");
        }
    }
}
