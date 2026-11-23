// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的几何计算，对应 macOS 的 Layout/（架构文档 5.4 节）：基准位置、吸附、边缘缩放、悬停放大与画面裁剪。
// 坐标都是全局屏幕坐标（原点在主屏左上角，y 轴向下）。
// macOS 的 CaptureMath.spec（ScreenCaptureKit 的捕获分辨率）在 Windows 上不需要：DWM 缩略图由系统合成。

//! 缩略图的几何计算。

pub mod edge_grip;
pub mod resolver;
pub mod snap;

use crate::geometry::{ScreenRect, ScreenSize, UnitRect};
use crate::model::ZoomAnchor;

pub use resolver::ResolvedLayout;
pub use snap::{ResizeEdges, SnapResult, SnapTargets};

/// 悬停放大：宽高乘以 `factor`，`anchor` 指定的那个点保持不动。
///
/// 放大后的尺寸不受最大尺寸限制，也不拉回屏幕内（放大是临时的）。`factor` 不大于 1 时原样返回。
pub fn zoomed_frame(base: ScreenRect, factor: i64, anchor: ZoomAnchor) -> ScreenRect {
    if factor <= 1 {
        return base;
    }
    base.scaled(factor as f64, anchor.unit_position())
}

/// 从画面顶部裁掉 `title_bar_crop_height` 后的显示范围（原点在画面左上角、y 轴向下）。
///
/// 裁剪高度不是正数、源高度无效，或裁剪高度不小于源高度时返回整个画面。
/// 「全屏窗口不裁」由调用方判断后传 0。Windows 上换算成 DWM 缩略图的 `rcSource`。
pub fn contents_rect(source_size: ScreenSize, title_bar_crop_height: f64) -> UnitRect {
    if !(title_bar_crop_height > 0.0
        && source_size.height > 0.0
        && title_bar_crop_height < source_size.height)
    {
        return UnitRect::FULL;
    }
    let top = title_bar_crop_height / source_size.height;
    UnitRect::new(0.0, top, 1.0, 1.0 - top)
}

/// 夹到 [lower, upper]；upper 小于 lower 时以 lower 为准（与 macOS 的 `min(max(v, lo), max(hi, lo))` 相同）。
pub(crate) fn clamp_loose(value: f64, lower: f64, upper: f64) -> f64 {
    value.max(lower).min(upper.max(lower))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 放大：左上角、中心、右下角不动；倍数不大于 1 时不变。
    #[test]
    fn zoom() {
        let base = ScreenRect::new(100.0, 100.0, 200.0, 100.0);
        assert_eq!(
            zoomed_frame(base, 2, ZoomAnchor::Nw),
            ScreenRect::new(100.0, 100.0, 400.0, 200.0)
        );
        assert_eq!(
            zoomed_frame(base, 2, ZoomAnchor::Center),
            ScreenRect::new(0.0, 50.0, 400.0, 200.0)
        );
        assert_eq!(
            zoomed_frame(base, 2, ZoomAnchor::Se),
            ScreenRect::new(-100.0, 0.0, 400.0, 200.0)
        );
        assert_eq!(zoomed_frame(base, 1, ZoomAnchor::Se), base);
    }

    /// 裁剪：正常裁剪与各种不裁的情况。
    #[test]
    fn crop() {
        let r = contents_rect(ScreenSize::new(1000.0, 100.0), 25.0);
        assert_eq!(r, UnitRect::new(0.0, 0.25, 1.0, 0.75));
        assert_eq!(contents_rect(ScreenSize::new(1000.0, 100.0), 0.0), UnitRect::FULL);
        assert_eq!(contents_rect(ScreenSize::new(1000.0, 0.0), 10.0), UnitRect::FULL);
        assert_eq!(
            contents_rect(ScreenSize::new(1000.0, 100.0), 100.0),
            UnitRect::FULL
        );
    }

    /// 宽松夹取：上限小于下限时取下限。
    #[test]
    fn loose_clamp() {
        assert_eq!(clamp_loose(5.0, 1.0, 10.0), 5.0);
        assert_eq!(clamp_loose(50.0, 10.0, 1.0), 10.0);
        assert_eq!(clamp_loose(-5.0, 10.0, 1.0), 10.0);
    }
}
