// SPDX-License-Identifier: GPL-3.0-or-later
//
// 不带修饰键的左键在缩略图、浮窗边缘拖动缩放，对应 macOS 的 Layout/EdgeGrip.swift（v1.2.1）。
// 右键拖动与修饰键加左键拖动沿用 snap::resize_edges 的 12 点边缘；不带修饰键的左键在缩略图上是「切换」，
// 在浮窗上要留给滚动条，所以只认更窄的边缘带（默认 6）。命中边缘带之后，再按 14 的角区判断是
// 单条边还是角，这样角上的命中范围比边缘带宽一些，更容易抓住。

//! 不带修饰键的左键的边缘判断。

use crate::geometry::{ScreenPoint, ScreenRect};
use crate::layout::snap::{ResizeEdges, resize_edges};

/// 边缘带的宽度：点到某条边的距离不超过它时算抓住边缘。
pub const BAND_WIDTH: f64 = 6.0;
/// 角区沿边的长度：抓住边缘后，离相邻边也在这个距离内时算抓住角。
pub const CORNER_LENGTH: f64 = 14.0;

/// 左键按下时该做什么。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlainPress {
    /// 普通点击：缩略图切换客户端，浮窗交还给面板（滚动条等）。
    Click,
    /// 按在边缘带上：拖动超过阈值后缩放这些边。
    Resize(ResizeEdges),
}

/// 点落在哪些边的边缘带上；不在边缘带内（或不在矩形内）时为空。
///
/// - 边缘带收窄到矩形短边的 1/4 以内、角区收窄到 1/3 以内：很小的矩形中间总留着能点击的区域。
/// - 先判断离最近的边是否不超过 `band`，命中后交给 [`resize_edges`] 按 `corner` 判角。
pub fn edges(point: ScreenPoint, rect: ScreenRect, band: f64, corner: f64) -> ResizeEdges {
    let short_side = rect.width.min(rect.height);
    let inside = point.x >= rect.min_x()
        && point.x <= rect.max_x()
        && point.y >= rect.min_y()
        && point.y <= rect.max_y();
    if !(short_side > 0.0 && inside) {
        return ResizeEdges::NONE;
    }
    let effective_band = band.min(short_side / 4.0);
    // 点到四条边的最短距离。
    let nearest = (point.x - rect.min_x())
        .min(rect.max_x() - point.x)
        .min(point.y - rect.min_y())
        .min(rect.max_y() - point.y);
    if nearest > effective_band {
        return ResizeEdges::NONE;
    }
    // 角区不小于边缘带，否则贴边的点会判不出那条边。
    let effective_corner = effective_band.max(corner.min(short_side / 3.0));
    resize_edges(point, rect, effective_corner)
}

/// 不带修饰键的左键按下时的决定：布局锁定或不允许缩放时总是普通点击；否则按在边缘带上时缩放。
///
/// `allows_resize` 为假表示不允许缩放（登录客户端的缩略图）。
pub fn plain_press(point: ScreenPoint, rect: ScreenRect, allows_resize: bool, is_locked: bool) -> PlainPress {
    if !allows_resize || is_locked {
        return PlainPress::Click;
    }
    let hit = edges(point, rect, BAND_WIDTH, CORNER_LENGTH);
    if hit.is_empty() {
        PlainPress::Click
    } else {
        PlainPress::Resize(hit)
    }
}
