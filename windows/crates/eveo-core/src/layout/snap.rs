// SPDX-License-Identifier: GPL-3.0-or-later
//
// 拖动与缩放时的吸附，对应 macOS 的 Layout/SnapEngine.swift（架构文档 5.4 节）。
// proposed 由「拖动起点的 frame + 鼠标的原始位移」算出，不由上一次吸附结果累加，
// 所以鼠标移出阈值后缩略图自然脱离，不需要额外状态。

//! 吸附计算。

use std::ops::{BitOr, BitOrAssign};

use crate::geometry::{ScreenInfo, ScreenPoint, ScreenRect, ScreenSize};
use crate::layout::clamp_loose;

/// 默认吸附阈值。
pub const DEFAULT_THRESHOLD: f64 = 8.0;

/// 吸附目标：其他缩略图与屏幕。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SnapTargets {
    /// 其他可见缩略图的 frame（不含正在拖动的这一个）。
    pub neighbors: Vec<ScreenRect>,
    /// 每块屏幕的 frame 与可用范围，各作为一个矩形。
    pub screens: Vec<ScreenRect>,
}

impl SnapTargets {
    /// 没有任何目标。按住 Shift 绕过吸附、但仍要应用尺寸约束时传它。
    pub fn none() -> Self {
        Self::default()
    }

    /// 由屏幕列表生成目标：每块屏幕贡献 frame 与可用范围两个矩形。
    pub fn from_screens(neighbors: Vec<ScreenRect>, screens: &[ScreenInfo]) -> Self {
        Self {
            neighbors,
            screens: screens.iter().flat_map(|s| [s.frame, s.visible_frame]).collect(),
        }
    }
}

/// 缩放时被拖动的边，按位组合。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ResizeEdges(u8);

impl ResizeEdges {
    /// 没有边。
    pub const NONE: ResizeEdges = ResizeEdges(0);
    /// 左边。
    pub const LEFT: ResizeEdges = ResizeEdges(1);
    /// 右边。
    pub const RIGHT: ResizeEdges = ResizeEdges(2);
    /// 上边。
    pub const TOP: ResizeEdges = ResizeEdges(4);
    /// 下边。
    pub const BOTTOM: ResizeEdges = ResizeEdges(8);

    /// 是否包含 `other` 的全部边。
    pub fn contains(self, other: ResizeEdges) -> bool {
        self.0 & other.0 == other.0
    }

    /// 与 `other` 没有共同的边。
    pub fn is_disjoint(self, other: ResizeEdges) -> bool {
        self.0 & other.0 == 0
    }

    /// 没有任何边。
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

impl BitOr for ResizeEdges {
    type Output = ResizeEdges;

    fn bitor(self, rhs: Self) -> Self {
        ResizeEdges(self.0 | rhs.0)
    }
}

impl BitOrAssign for ResizeEdges {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

/// 吸附结果。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SnapResult {
    /// 吸附与约束后的 frame。
    pub rect: ScreenRect,
    /// 对齐到的竖直边的 x 坐标；没有对齐时为 `None`。供以后画参考线。
    pub snapped_x: Option<f64>,
    /// 对齐到的水平边的 y 坐标；没有对齐时为 `None`。
    pub snapped_y: Option<f64>,
}

/// 移动时的吸附。x 轴与 y 轴各自独立，在阈值内取最近的目标边。
///
/// 可对齐的组合：左对左、左对右、右对左、右对右，y 轴同理。邻居只在另一轴上与 `proposed`
/// 有重叠或间隔不超过阈值时参与；屏幕的 4 条边始终参与。距离相同时取先找到的目标。
pub fn snap_move(proposed: ScreenRect, targets: &SnapTargets, threshold: f64) -> SnapResult {
    let x_hit = nearest_line(
        &[proposed.min_x(), proposed.max_x()],
        &vertical_lines(proposed, targets, threshold),
        threshold,
    );
    let y_hit = nearest_line(
        &[proposed.min_y(), proposed.max_y()],
        &horizontal_lines(proposed, targets, threshold),
        threshold,
    );
    let rect = proposed.offset_by(x_hit.map_or(0.0, |h| h.delta), y_hit.map_or(0.0, |h| h.delta));
    SnapResult {
        rect,
        snapped_x: x_hit.map(|h| h.line),
        snapped_y: y_hit.map(|h| h.line),
    }
}

/// 缩放时的吸附。只移动 `moving_edges` 里的边，对边不动。
///
/// 先吸附，再按 `minimum`、`maximum` 与 `aspect_ratio` 约束，约束优先于吸附：约束改动了被吸附的边时，
/// 对应的 `snapped_x` 或 `snapped_y` 置为 `None`。约束改变尺寸时，固定边保持原位、由它反推原点。
/// 只拖左右边时以宽算高，只拖上下边时以高算宽，拖角时以宽为准，但只有竖直方向吸附成功时以高为准。
///
/// `aspect_ratio` 是宽 ÷ 高；锁定比例或按住 Shift 时传拖动开始时的比例，否则 `None`。
pub fn snap_resize(
    proposed: ScreenRect,
    moving_edges: ResizeEdges,
    targets: &SnapTargets,
    threshold: f64,
    minimum: ScreenSize,
    maximum: ScreenSize,
    aspect_ratio: Option<f64>,
) -> SnapResult {
    let snapped = snap_moving_edges(proposed, moving_edges, targets, threshold);
    let horizontal = ResizeEdges::LEFT | ResizeEdges::RIGHT;
    let vertical = ResizeEdges::TOP | ResizeEdges::BOTTOM;
    let drive_by_height = moving_edges.is_disjoint(horizontal)
        || (snapped.snapped_y.is_some()
            && snapped.snapped_x.is_none()
            && !moving_edges.is_disjoint(vertical));
    let size = constrained_size(
        snapped.max_x - snapped.min_x,
        snapped.max_y - snapped.min_y,
        drive_by_height,
        minimum,
        maximum,
        aspect_ratio,
    );
    // 只拖左边时右边固定、由它反推左边；其余情况左边固定。竖直方向同理。
    let min_x = if moving_edges.contains(ResizeEdges::LEFT) && !moving_edges.contains(ResizeEdges::RIGHT) {
        snapped.max_x - size.width
    } else {
        snapped.min_x
    };
    let min_y = if moving_edges.contains(ResizeEdges::TOP) && !moving_edges.contains(ResizeEdges::BOTTOM) {
        snapped.max_y - size.height
    } else {
        snapped.min_y
    };
    let rect = ScreenRect::new(min_x, min_y, size.width, size.height);
    SnapResult {
        rect,
        snapped_x: snapped
            .snapped_x
            .filter(|&v| is_edge(v, &[rect.min_x(), rect.max_x()])),
        snapped_y: snapped
            .snapped_y
            .filter(|&v| is_edge(v, &[rect.min_y(), rect.max_y()])),
    }
}

/// 鼠标按下的位置落在哪些边的 `margin` 范围内，用来决定缩放哪条边或哪个角。
///
/// 点在矩形外时返回空集合。矩形太窄、点同时靠近左右两边时，取更近的那条边；上下同理。
pub fn resize_edges(point: ScreenPoint, rect: ScreenRect, margin: f64) -> ResizeEdges {
    if !(point.x >= rect.min_x()
        && point.x <= rect.max_x()
        && point.y >= rect.min_y()
        && point.y <= rect.max_y())
    {
        return ResizeEdges::NONE;
    }
    let mut edges = ResizeEdges::NONE;
    let (left, right) = (point.x - rect.min_x(), rect.max_x() - point.x);
    let (top, bottom) = (point.y - rect.min_y(), rect.max_y() - point.y);
    if left <= margin || right <= margin {
        edges |= if left <= right {
            ResizeEdges::LEFT
        } else {
            ResizeEdges::RIGHT
        };
    }
    if top <= margin || bottom <= margin {
        edges |= if top <= bottom {
            ResizeEdges::TOP
        } else {
            ResizeEdges::BOTTOM
        };
    }
    edges
}

// ---- 目标边 ----

/// 一次命中：目标线的坐标与需要的位移。
#[derive(Clone, Copy)]
struct Hit {
    /// 目标线的坐标。
    line: f64,
    /// 从被吸附的边到目标线的位移。
    delta: f64,
}

/// 参与 x 方向吸附的竖直线：在 y 方向与 proposed 重叠或接近的邻居的左右边，以及全部屏幕的左右边。
fn vertical_lines(proposed: ScreenRect, targets: &SnapTargets, threshold: f64) -> Vec<f64> {
    targets
        .neighbors
        .iter()
        .filter(|n| n.min_y() <= proposed.max_y() + threshold && n.max_y() >= proposed.min_y() - threshold)
        .chain(targets.screens.iter())
        .flat_map(|r| [r.min_x(), r.max_x()])
        .collect()
}

/// 参与 y 方向吸附的水平线：在 x 方向与 proposed 重叠或接近的邻居的上下边，以及全部屏幕的上下边。
fn horizontal_lines(proposed: ScreenRect, targets: &SnapTargets, threshold: f64) -> Vec<f64> {
    targets
        .neighbors
        .iter()
        .filter(|n| n.min_x() <= proposed.max_x() + threshold && n.max_x() >= proposed.min_x() - threshold)
        .chain(targets.screens.iter())
        .flat_map(|r| [r.min_y(), r.max_y()])
        .collect()
}

/// 在阈值内找离任一条边最近的目标线。距离相同时保留先找到的。
fn nearest_line(edges: &[f64], lines: &[f64], threshold: f64) -> Option<Hit> {
    let mut best: Option<Hit> = None;
    for &edge in edges {
        for &line in lines {
            let delta = line - edge;
            if delta.abs() > threshold {
                continue;
            }
            if best.is_none_or(|b| delta.abs() < b.delta.abs()) {
                best = Some(Hit { line, delta });
            }
        }
    }
    best
}

/// 只对被拖动的边做吸附后的四条边与对齐线。
struct SnappedEdges {
    /// 左边。
    min_x: f64,
    /// 右边。
    max_x: f64,
    /// 上边。
    min_y: f64,
    /// 下边。
    max_y: f64,
    /// 竖直方向对齐到的线。
    snapped_x: Option<f64>,
    /// 水平方向对齐到的线。
    snapped_y: Option<f64>,
}

/// 只对被拖动的边做吸附，返回四条边的新坐标与对齐线。
fn snap_moving_edges(
    proposed: ScreenRect,
    moving: ResizeEdges,
    targets: &SnapTargets,
    threshold: f64,
) -> SnappedEdges {
    let x_lines = vertical_lines(proposed, targets, threshold);
    let y_lines = horizontal_lines(proposed, targets, threshold);
    let mut s = SnappedEdges {
        min_x: proposed.min_x(),
        max_x: proposed.max_x(),
        min_y: proposed.min_y(),
        max_y: proposed.max_y(),
        snapped_x: None,
        snapped_y: None,
    };
    let left_hit = moving
        .contains(ResizeEdges::LEFT)
        .then(|| nearest_line(&[s.min_x], &x_lines, threshold))
        .flatten();
    if let Some(hit) = left_hit {
        s.min_x = hit.line;
        s.snapped_x = Some(hit.line);
    } else if let Some(hit) = moving
        .contains(ResizeEdges::RIGHT)
        .then(|| nearest_line(&[s.max_x], &x_lines, threshold))
        .flatten()
    {
        s.max_x = hit.line;
        s.snapped_x = Some(hit.line);
    }
    let top_hit = moving
        .contains(ResizeEdges::TOP)
        .then(|| nearest_line(&[s.min_y], &y_lines, threshold))
        .flatten();
    if let Some(hit) = top_hit {
        s.min_y = hit.line;
        s.snapped_y = Some(hit.line);
    } else if let Some(hit) = moving
        .contains(ResizeEdges::BOTTOM)
        .then(|| nearest_line(&[s.max_y], &y_lines, threshold))
        .flatten()
    {
        s.max_y = hit.line;
        s.snapped_y = Some(hit.line);
    }
    s
}

// ---- 约束 ----

/// 按最小、最大尺寸与宽高比约束尺寸。比例与范围冲突时范围优先。
fn constrained_size(
    width: f64,
    height: f64,
    drive_by_height: bool,
    minimum: ScreenSize,
    maximum: ScreenSize,
    aspect_ratio: Option<f64>,
) -> ScreenSize {
    let mut w = clamp_loose(width, minimum.width, maximum.width);
    let mut h = clamp_loose(height, minimum.height, maximum.height);
    let Some(ratio) = aspect_ratio.filter(|r| r.is_finite() && *r > 0.0) else {
        return ScreenSize::new(w, h);
    };
    if drive_by_height {
        w = clamp_loose(h * ratio, minimum.width, maximum.width);
        h = clamp_loose(w / ratio, minimum.height, maximum.height);
    } else {
        h = clamp_loose(w / ratio, minimum.height, maximum.height);
        w = clamp_loose(h * ratio, minimum.width, maximum.width);
    }
    ScreenSize::new(w, h)
}

/// `value` 与 `edges` 中某一条边重合（容差 1e-9）时为真。
fn is_edge(value: f64, edges: &[f64]) -> bool {
    edges.iter().any(|e| (e - value).abs() < 1e-9)
}
