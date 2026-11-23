// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图基准 frame 的计算，对应 macOS 的 Layout/LayoutResolver.swift（架构文档 5.4 节）：
// 有记录用记录，没有记录自动排位，登录客户端从 loginPosition 层叠；最后都拉回屏幕内，
// 显示器拔掉后缩略图不会留在屏幕外。

//! 缩略图布局计算。

use crate::geometry::{ScreenInfo, ScreenPoint, ScreenRect, ScreenSize, main_screen};
use crate::layout::clamp_loose;
use crate::model::{ClientIdentity, EveClient, Profile, ThumbnailSettings};

/// 自动排位时距可用区域边缘的距离。
pub const AUTO_PLACE_MARGIN: f64 = 16.0;
/// 自动排位时相邻缩略图的间距。
pub const AUTO_PLACE_SPACING: f64 = 8.0;
/// 登录客户端每个序号的层叠偏移（x、y 各加这么多）。
pub const LOGIN_CASCADE_OFFSET: f64 = 24.0;
/// 缩略图在任何屏幕上至少要露出的边长。
pub const MINIMUM_VISIBLE: f64 = 32.0;

/// [`frame`] 的结果。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResolvedLayout {
    /// 缩略图的基准 frame（不含悬停放大），全局屏幕坐标。
    pub frame: ScreenRect,
    /// 是否为自动排出的位置。为真时规划器把它写进要保存的布局，以后位置固定。
    pub is_auto_placed: bool,
}

/// 取客户端缩略图的基准 frame（不含悬停放大）。`occupied` 是本轮已分配的 frame。
///
/// 1. 角色在 `profile.layouts` 里有记录：用记录的位置；宽高为 `None` 时用默认尺寸；尺寸经 [`clamp_size`]。
/// 2. 角色没有记录：在主屏可用范围内从左上角起向下排，边距 16，间距 8，排满换下一列，
///    跳过与 `occupied` 相交的格子；全部格子都被占用时取第一个格子。
/// 3. 登录或未知的客户端：`loginPosition` 加 `(24 × login_index, 24 × login_index)`，尺寸用默认尺寸。
/// 4. 结果都经过 [`clamp_to_screens`]（至少露出 32）。
///
/// `login_index` 是该客户端在登录与未知客户端里按 PID 升序的序号，从 0 起；角色客户端忽略它。
pub fn frame(
    client: &EveClient,
    login_index: usize,
    profile: &Profile,
    screens: &[ScreenInfo],
    occupied: &[ScreenRect],
) -> ResolvedLayout {
    let settings = &profile.thumbnail;
    let default_size = clamp_size(settings.default_size, settings, None);
    let raw = match &client.identity {
        ClientIdentity::Character(name) => match profile.layouts.get(name) {
            Some(layout) => {
                let wanted = ScreenSize::new(
                    layout.width.unwrap_or(default_size.width),
                    layout.height.unwrap_or(default_size.height),
                );
                let size = clamp_size(wanted, settings, None);
                ResolvedLayout {
                    frame: ScreenRect::new(layout.x, layout.y, size.width, size.height),
                    is_auto_placed: false,
                }
            }
            None => ResolvedLayout {
                frame: auto_place(default_size, screens, occupied),
                is_auto_placed: true,
            },
        },
        ClientIdentity::Login | ClientIdentity::Unknown => {
            let offset = LOGIN_CASCADE_OFFSET * login_index as f64;
            let origin = ScreenPoint::new(
                profile.login_position.x + offset,
                profile.login_position.y + offset,
            );
            ResolvedLayout {
                frame: ScreenRect::from_origin_size(origin, default_size),
                is_auto_placed: false,
            }
        }
    };
    ResolvedLayout {
        frame: clamp_to_screens(raw.frame, screens, MINIMUM_VISIBLE),
        ..raw
    }
}

/// 把尺寸夹到最小与最大尺寸之间。
///
/// `aspect_ratio`（宽 ÷ 高）有值时先按宽算高，高越界时改按高的边界算宽，再把宽夹一次；
/// 最小与最大尺寸无法同时满足比例时，范围优先于比例。
pub fn clamp_size(size: ScreenSize, settings: &ThumbnailSettings, aspect_ratio: Option<f64>) -> ScreenSize {
    let (min, max) = (settings.minimum_size, settings.maximum_size);
    let mut width = clamp_loose(size.width, min.width, max.width);
    let mut height = clamp_loose(size.height, min.height, max.height);
    if let Some(ratio) = aspect_ratio.filter(|r| r.is_finite() && *r > 0.0) {
        height = width / ratio;
        let upper = max.height.max(min.height);
        if height < min.height {
            height = min.height;
            width = height * ratio;
        } else if height > upper {
            height = upper;
            width = height * ratio;
        }
        width = clamp_loose(width, min.width, max.width);
    }
    ScreenSize::new(width, height)
}

/// 缩略图在任何屏幕上的可见部分不足 `minimum_visible` 时，把它移回最近的屏幕内。
///
/// 「可见」指与某块屏幕 frame 的交集宽高都不小于 `minimum_visible`（缩略图本身更小时以其边长为准）。
/// 移回时选中心点距离最近的屏幕，把缩略图整体放进该屏幕的可用范围；放不下时左上角对齐。
/// 没有屏幕信息时原样返回。尺寸不变。
pub fn clamp_to_screens(rect: ScreenRect, screens: &[ScreenInfo], minimum_visible: f64) -> ScreenRect {
    if screens.is_empty() {
        return rect;
    }
    let need_width = minimum_visible.min(rect.width);
    let need_height = minimum_visible.min(rect.height);
    let visible_somewhere = screens.iter().any(|screen| {
        rect.intersection(&screen.frame)
            .is_some_and(|v| v.width >= need_width && v.height >= need_height)
    });
    if visible_somewhere {
        return rect;
    }
    let center = rect.center();
    // 距离相同时取靠前的屏幕，与 macOS 的 min(by:) 相同。
    let target = screens
        .iter()
        .reduce(|best, s| {
            if distance(center, &s.frame) < distance(center, &best.frame) {
                s
            } else {
                best
            }
        })
        .expect("屏幕列表非空");
    let area = if target.visible_frame.is_empty() {
        target.frame
    } else {
        target.visible_frame
    };
    let x = clamp_loose(rect.x, area.min_x(), area.max_x() - rect.width);
    let y = clamp_loose(rect.y, area.min_y(), area.max_y() - rect.height);
    ScreenRect::new(x, y, rect.width, rect.height)
}

/// 自动排位：在主屏可用范围里按列从上到下找第一个不与 `occupied` 相交的格子。
fn auto_place(size: ScreenSize, screens: &[ScreenInfo], occupied: &[ScreenRect]) -> ScreenRect {
    let Some(main) = main_screen(screens) else {
        return ScreenRect::new(AUTO_PLACE_MARGIN, AUTO_PLACE_MARGIN, size.width, size.height);
    };
    let area = if main.visible_frame.is_empty() {
        main.frame
    } else {
        main.visible_frame
    };
    let first = ScreenRect::new(
        area.min_x() + AUTO_PLACE_MARGIN,
        area.min_y() + AUTO_PLACE_MARGIN,
        size.width,
        size.height,
    );
    if !(size.width > 0.0 && size.height > 0.0) {
        return first;
    }
    let mut x = first.x;
    while x + size.width <= area.max_x() - AUTO_PLACE_MARGIN {
        let mut y = first.y;
        while y + size.height <= area.max_y() - AUTO_PLACE_MARGIN {
            let cell = ScreenRect::new(x, y, size.width, size.height);
            if !occupied.iter().any(|o| o.intersects(&cell)) {
                return cell;
            }
            y += size.height + AUTO_PLACE_SPACING;
        }
        x += size.width + AUTO_PLACE_SPACING;
    }
    // 屏幕已排满（或缩略图比屏幕大）：叠放在第一个格子，用户可再拖开。
    first
}

/// 点到矩形的距离；点在矩形内时为 0。
fn distance(point: ScreenPoint, rect: &ScreenRect) -> f64 {
    let dx = (rect.min_x() - point.x).max(0.0).max(point.x - rect.max_x());
    let dy = (rect.min_y() - point.y).max(0.0).max(point.y - rect.max_y());
    (dx * dx + dy * dy).sqrt()
}
