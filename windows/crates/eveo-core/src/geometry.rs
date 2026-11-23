// SPDX-License-Identifier: GPL-3.0-or-later
//
// Core 的几何类型，对应 macOS 的 Geometry/ScreenGeometry.swift。
// 全部使用全局屏幕坐标：原点在主屏左上角，y 轴向下。macOS 的单位是点；Windows 的单位是物理像素
// （进程按 Per-Monitor V2 声明 DPI 感知，见架构文档 4.2 节），换算由平台层负责，这里只管数值。

//! 屏幕坐标中的几何类型。

use serde::{Deserialize, Deserializer, Serialize};

/// 全局屏幕坐标中的一个点。
///
/// 原点在主屏左上角，y 轴向下；副屏在主屏左侧或上方时坐标可以是负数。
/// 解码时缺失的键或 null 取 0，保证旧配置或手改的配置能读出来。
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize)]
pub struct ScreenPoint {
    /// 水平坐标。
    pub x: f64,
    /// 垂直坐标，向下为正。
    pub y: f64,
}

impl ScreenPoint {
    /// 用水平、垂直坐标建一个点。
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// 一个尺寸。宽高可以是 0，负数没有意义，由调用方夹取。
///
/// 解码时缺失的键或 null 取 0；越界值由配置校验改正。
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize)]
pub struct ScreenSize {
    /// 宽度。
    pub width: f64,
    /// 高度。
    pub height: f64,
}

impl ScreenSize {
    /// 用宽、高建一个尺寸。
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }

    /// 宽高比（宽 ÷ 高）。高度不大于 0 时返回 `None`，避免除零。
    pub fn aspect_ratio(&self) -> Option<f64> {
        (self.height > 0.0).then(|| self.width / self.height)
    }
}

/// 全局屏幕坐标中的矩形，(x, y) 是左上角。
///
/// JSON 键名固定为 `x`、`y`、`width`、`height`，与 macOS 的配置文件相同；缺失的键或 null 取 0。
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize)]
pub struct ScreenRect {
    /// 左边的 x 坐标。
    pub x: f64,
    /// 上边的 y 坐标（y 轴向下，所以是最小的 y）。
    pub y: f64,
    /// 宽度。
    pub width: f64,
    /// 高度。
    pub height: f64,
}

impl ScreenRect {
    /// 用左上角与宽高建一个矩形。
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    /// 用左上角与尺寸建一个矩形。
    pub const fn from_origin_size(origin: ScreenPoint, size: ScreenSize) -> Self {
        Self::new(origin.x, origin.y, size.width, size.height)
    }

    // ---- 边与派生量 ----

    /// 左边的 x 坐标，同 `x`。
    pub fn min_x(&self) -> f64 {
        self.x
    }

    /// 右边的 x 坐标。
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    /// 上边的 y 坐标，同 `y`。
    pub fn min_y(&self) -> f64 {
        self.y
    }

    /// 下边的 y 坐标（y 轴向下，所以是最大的 y）。
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// 水平中点。
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }

    /// 垂直中点。
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }

    /// 左上角。
    pub fn origin(&self) -> ScreenPoint {
        ScreenPoint::new(self.x, self.y)
    }

    /// 尺寸。
    pub fn size(&self) -> ScreenSize {
        ScreenSize::new(self.width, self.height)
    }

    /// 中心点。
    pub fn center(&self) -> ScreenPoint {
        ScreenPoint::new(self.mid_x(), self.mid_y())
    }

    /// 面积；宽或高不大于 0 时为 0。
    pub fn area(&self) -> f64 {
        self.width.max(0.0) * self.height.max(0.0)
    }

    /// 宽或高不大于 0 时为真。
    pub fn is_empty(&self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }

    // ---- 运算 ----

    /// 两个矩形的交集。不相交或只共享一条边时返回 `None`。
    pub fn intersection(&self, other: &ScreenRect) -> Option<ScreenRect> {
        let left = self.min_x().max(other.min_x());
        let right = self.max_x().min(other.max_x());
        let top = self.min_y().max(other.min_y());
        let bottom = self.max_y().min(other.max_y());
        (right > left && bottom > top).then(|| ScreenRect::new(left, top, right - left, bottom - top))
    }

    /// 两个矩形是否有面积大于 0 的重叠。只共享一条边不算相交。
    pub fn intersects(&self, other: &ScreenRect) -> bool {
        self.intersection(other).is_some()
    }

    /// 点是否落在矩形内。左边、上边算在内，右边、下边不算，与像素网格的惯例一致。
    pub fn contains(&self, point: ScreenPoint) -> bool {
        point.x >= self.min_x() && point.x < self.max_x() && point.y >= self.min_y() && point.y < self.max_y()
    }

    /// 平移后的矩形，尺寸不变。
    pub fn offset_by(&self, dx: f64, dy: f64) -> ScreenRect {
        ScreenRect::new(self.x + dx, self.y + dy, self.width, self.height)
    }

    /// 以给定点为不动点，宽高同时乘以 `factor`。
    ///
    /// - `factor`：放大倍数；小于 1 时为缩小。
    /// - `anchor`：不动点在矩形内的相对位置，(0, 0) 是左上角，(1, 1) 是右下角。
    pub fn scaled(&self, factor: f64, anchor: (f64, f64)) -> ScreenRect {
        let new_width = self.width * factor;
        let new_height = self.height * factor;
        // 不动点的绝对坐标在缩放前后相同，由此反推新的左上角。
        let fixed_x = self.x + self.width * anchor.0;
        let fixed_y = self.y + self.height * anchor.1;
        ScreenRect::new(
            fixed_x - new_width * anchor.0,
            fixed_y - new_height * anchor.1,
            new_width,
            new_height,
        )
    }
}

/// 几何类型解码用的影子结构：每个分量都可以缺失或为 null，缺失时取 0（与 macOS 的 decodeIfPresent 相同）。
#[derive(Deserialize)]
struct RawComponents {
    /// 水平坐标。
    x: Option<f64>,
    /// 垂直坐标。
    y: Option<f64>,
    /// 宽度。
    width: Option<f64>,
    /// 高度。
    height: Option<f64>,
}

impl RawComponents {
    /// 读一个 JSON 对象；多余的键忽略。
    fn read<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::deserialize(deserializer)
    }
}

impl<'de> Deserialize<'de> for ScreenPoint {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = RawComponents::read(deserializer)?;
        Ok(Self::new(raw.x.unwrap_or(0.0), raw.y.unwrap_or(0.0)))
    }
}

impl<'de> Deserialize<'de> for ScreenSize {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = RawComponents::read(deserializer)?;
        Ok(Self::new(raw.width.unwrap_or(0.0), raw.height.unwrap_or(0.0)))
    }
}

impl<'de> Deserialize<'de> for ScreenRect {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = RawComponents::read(deserializer)?;
        Ok(Self::new(
            raw.x.unwrap_or(0.0),
            raw.y.unwrap_or(0.0),
            raw.width.unwrap_or(0.0),
            raw.height.unwrap_or(0.0),
        ))
    }
}

/// 归一化矩形，各分量在 0～1 之间，表示源画面中要显示的部分。
///
/// 约定：原点在画面左上角，y 轴向下，与屏幕坐标同向。Windows 上换算成 DWM 缩略图的 `rcSource`。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UnitRect {
    /// 左边，0 表示画面左边缘。
    pub x: f64,
    /// 上边，0 表示画面上边缘。
    pub y: f64,
    /// 宽度占画面宽度的比例。
    pub width: f64,
    /// 高度占画面高度的比例。
    pub height: f64,
}

impl UnitRect {
    /// 整个画面：(0, 0, 1, 1)。
    pub const FULL: UnitRect = UnitRect {
        x: 0.0,
        y: 0.0,
        width: 1.0,
        height: 1.0,
    };

    /// 用归一化的左上角与宽高建一个矩形。
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
}

/// 一块显示器的几何信息，坐标是全局屏幕坐标。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScreenInfo {
    /// 整块屏幕的范围。
    pub frame: ScreenRect,
    /// 去掉任务栏（macOS 是菜单栏与程序坞）后的可用范围。
    pub visible_frame: ScreenRect,
    /// 缩放系数：macOS 是每点的像素数，Windows 是 DPI ÷ 96。
    pub scale: f64,
    /// 是否为主屏（原点所在的屏幕）。
    pub is_main: bool,
}

/// 主屏；没有标记为主屏的屏幕时取第一块，空切片返回 `None`。
pub fn main_screen(screens: &[ScreenInfo]) -> Option<&ScreenInfo> {
    screens.iter().find(|s| s.is_main).or_else(|| screens.first())
}

/// 包含该点的屏幕；点不在任何屏幕内时返回 `None`。
pub fn screen_containing(screens: &[ScreenInfo], point: ScreenPoint) -> Option<&ScreenInfo> {
    screens.iter().find(|s| s.frame.contains(point))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 缺失的键取 0，与 macOS 的解码规则相同。
    #[test]
    fn missing_keys_decode_as_zero() {
        let rect: ScreenRect = serde_json::from_str(r#"{"x": 5, "width": 10}"#).unwrap();
        assert_eq!(rect, ScreenRect::new(5.0, 0.0, 10.0, 0.0));
        let size: ScreenSize = serde_json::from_str("{}").unwrap();
        assert_eq!(size, ScreenSize::default());
        let point: ScreenPoint = serde_json::from_str(r#"{"x": null, "y": 3}"#).unwrap();
        assert_eq!(point, ScreenPoint::new(0.0, 3.0));
    }

    /// 编码后的键名与 macOS 的配置文件一致。
    #[test]
    fn encodes_flat_keys() {
        let json = serde_json::to_value(ScreenRect::new(1.0, 2.0, 3.0, 4.0)).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0})
        );
    }

    /// 高度不大于 0 时没有宽高比。
    #[test]
    fn aspect_ratio_guards_zero_height() {
        assert_eq!(ScreenSize::new(16.0, 9.0).aspect_ratio(), Some(16.0 / 9.0));
        assert_eq!(ScreenSize::new(16.0, 0.0).aspect_ratio(), None);
        assert_eq!(ScreenSize::new(16.0, -1.0).aspect_ratio(), None);
    }

    /// 派生量：边、中点、负宽高的面积。
    #[test]
    fn derived_values() {
        let r = ScreenRect::new(10.0, 20.0, 100.0, 50.0);
        assert_eq!(
            (r.max_x(), r.max_y(), r.mid_x(), r.mid_y()),
            (110.0, 70.0, 60.0, 45.0)
        );
        assert_eq!(r.center(), ScreenPoint::new(60.0, 45.0));
        assert_eq!(r.area(), 5000.0);
        assert_eq!(ScreenRect::new(0.0, 0.0, -5.0, 10.0).area(), 0.0);
        assert!(ScreenRect::new(0.0, 0.0, 0.0, 10.0).is_empty());
        assert!(!r.is_empty());
    }

    /// 交集：重叠、只共享一条边、完全分开。
    #[test]
    fn intersection_rules() {
        let a = ScreenRect::new(0.0, 0.0, 100.0, 100.0);
        let b = ScreenRect::new(50.0, 50.0, 100.0, 100.0);
        assert_eq!(a.intersection(&b), Some(ScreenRect::new(50.0, 50.0, 50.0, 50.0)));
        let touching = ScreenRect::new(100.0, 0.0, 10.0, 10.0);
        assert_eq!(a.intersection(&touching), None);
        assert!(!a.intersects(&touching));
        assert!(!a.intersects(&ScreenRect::new(500.0, 500.0, 1.0, 1.0)));
    }

    /// 包含判断是半开区间：左上边在内，右下边不在。
    #[test]
    fn contains_is_half_open() {
        let r = ScreenRect::new(0.0, 0.0, 10.0, 10.0);
        assert!(r.contains(ScreenPoint::new(0.0, 0.0)));
        assert!(r.contains(ScreenPoint::new(9.999, 9.999)));
        assert!(!r.contains(ScreenPoint::new(10.0, 5.0)));
        assert!(!r.contains(ScreenPoint::new(5.0, 10.0)));
    }

    /// 平移与按不动点缩放。
    #[test]
    fn offset_and_scale() {
        let r = ScreenRect::new(100.0, 100.0, 200.0, 100.0);
        assert_eq!(
            r.offset_by(-10.0, 5.0),
            ScreenRect::new(90.0, 105.0, 200.0, 100.0)
        );
        assert_eq!(
            r.scaled(2.0, (0.0, 0.0)),
            ScreenRect::new(100.0, 100.0, 400.0, 200.0)
        );
        assert_eq!(
            r.scaled(2.0, (0.5, 0.5)),
            ScreenRect::new(0.0, 50.0, 400.0, 200.0)
        );
        assert_eq!(
            r.scaled(0.5, (1.0, 1.0)),
            ScreenRect::new(200.0, 150.0, 100.0, 50.0)
        );
    }

    /// 主屏与按点找屏幕。
    #[test]
    fn screen_lookup() {
        let left = ScreenInfo {
            frame: ScreenRect::new(-1920.0, 0.0, 1920.0, 1080.0),
            visible_frame: ScreenRect::new(-1920.0, 0.0, 1920.0, 1040.0),
            scale: 1.0,
            is_main: false,
        };
        let main = ScreenInfo {
            frame: ScreenRect::new(0.0, 0.0, 2560.0, 1440.0),
            visible_frame: ScreenRect::new(0.0, 0.0, 2560.0, 1392.0),
            scale: 1.5,
            is_main: true,
        };
        let screens = [left, main];
        assert_eq!(main_screen(&screens), Some(&main));
        assert_eq!(main_screen(&[left]), Some(&left));
        assert_eq!(main_screen(&[]), None);
        assert_eq!(
            screen_containing(&screens, ScreenPoint::new(-5.0, 10.0)),
            Some(&left)
        );
        assert_eq!(screen_containing(&screens, ScreenPoint::new(5000.0, 10.0)), None);
    }
}
