// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图叠加层里的「锁定布局」特效绘制（Direct2D），对应 macOS 的 LockEffectLayer：
// - 全部图形都向内缩进 `lock.border_inset`（外圈高亮或中性边框的物理像素宽度），
//   保证缩略图窗口底色露出的外圈活动高亮边框 100% 不被遮挡，两种效果清晰叠加。
// - 包含四层叠加元素，全部用 Direct2D 矩形原语绘制，零路径分配、零额外依赖：
//   1. 内圈 1 DIP 微光边线（开启瞬间脉冲增强后回落为柔和常驻边线）；
//   2. 沿内圈顺时针巡游的青蓝渐变流光弧段（由多段渐隐细条拼出头部亮白、尾部渐隐效果）；
//   3. 开启瞬间自左上向右下扫过的倾斜半透明流光带（裁剪在内圈矩形内）；
//   4. 四角 L 型战术锁扣（开启瞬间从内侧偏移卡紧到四角，常驻期间柔和呼吸）。

//! 缩略图叠加层的锁定布局特效绘制。

use windows::Win32::Graphics::Direct2D::Common::{D2D_RECT_F, D2D1_COLOR_F};
use windows::Win32::Graphics::Direct2D::{
    D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, ID2D1DCRenderTarget, ID2D1SolidColorBrush,
};
use windows::core::Result;

use crate::overlay::OverlayLock;

/// 主色：战术青蓝 `#38BDF8`。
const ACCENT_RGB: u32 = 0x38_BD_F8;
/// 高光色：亮青白 `#BAE6FD`。
const FLASH_RGB: u32 = 0xBA_E6_FD;
/// 流光弧段占整个内圈周长的比例（与 macOS 一致）。
const GLINT_FRACTION: f32 = 0.18;
/// 流光弧段切分的渐变段数：8 段足以在 2 DIP 线宽上呈现平滑的尾迹衰减。
const GLINT_SEGMENTS: usize = 8;

/// 在缩略图叠加层上绘制锁定布局特效，全部内容严格限制在外圈边框内缩之后的内框里。
///
/// 绘制顺序自底向上为：内圈微光边线、巡游流光弧段、开启瞬间对角流光、四角战术锁扣。
/// 外圈 `[0, border_inset)` 区域保持完全透明，留给缩略图窗口底色显示活动高亮边框或中性边框，
/// 因此切换活动窗口或调整高亮颜色与粗细时，两种视觉效果自然叠加、互不覆盖。
pub(crate) fn draw(
    target: &ID2D1DCRenderTarget,
    (width, height): (f32, f32),
    scale: f32,
    lock: &OverlayLock,
) -> Result<()> {
    // 将内缩宽度夹在窗口短边一半以内，避免极小窗口下内框出现负宽高。
    let inset = lock.border_inset.max(0.0).min(width.min(height) / 2.0);
    let inner = D2D_RECT_F {
        left: inset,
        top: inset,
        right: width - inset,
        bottom: height - inset,
    };
    let inner_w = inner.right - inner.left;
    let inner_h = inner.bottom - inner.top;
    // 内框过小时跳过绘制，避免角标与边线挤成色块。
    if inner_w <= 4.0 * scale || inner_h <= 4.0 * scale {
        return Ok(());
    }

    // 1. 内圈 1 DIP 微光边线，紧贴外圈边框内侧。
    draw_hairline(target, inner, scale, lock.hairline_alpha)?;

    // 2. 沿内圈顺时针巡游的流光弧段（减弱动态效果时 glint_phase 为 None）。
    if let Some(phase) = lock.glint_phase {
        draw_perimeter_glint(target, inner, scale, phase)?;
    }

    // 3. 开启瞬间的对角流光扫过（仅在开启后的 0.55 秒内存在）。
    if let Some(progress) = lock.sheen_progress {
        draw_engage_sheen(target, inner, scale, progress)?;
    }

    // 4. 四角 L 型战术锁扣（位于最上层，清晰呈现锁定状态）。
    draw_corner_clamps(target, inner, scale, lock)?;
    Ok(())
}

/// 画内圈 1 DIP 微光边线。
///
/// Direct2D 描边以矩形边为中线，因此向内缩半个线宽，确保描边完整落在内框里面，不越界到外圈高亮。
fn draw_hairline(target: &ID2D1DCRenderTarget, inner: D2D_RECT_F, scale: f32, alpha: f32) -> Result<()> {
    let stroke = 1.0 * scale;
    let half = stroke / 2.0;
    let rect = D2D_RECT_F {
        left: inner.left + half,
        top: inner.top + half,
        right: inner.right - half,
        bottom: inner.bottom - half,
    };
    if rect.right <= rect.left || rect.bottom <= rect.top {
        return Ok(());
    }
    let brush = make_brush(target, rgba(ACCENT_RGB, alpha))?;
    // SAFETY: 矩形与画刷在调用期间有效。
    unsafe { target.DrawRectangle(&rect, &brush, stroke, None) };
    Ok(())
}

/// 画沿内圈周长顺时针巡游的渐隐流光弧段。
///
/// 弧段沿内框向内缩 1 DIP 的闭合路径前进，拆成 `GLINT_SEGMENTS` 段，从尾到头按二次曲线抬升亮度与混色，
/// 呈现头部亮青白、尾部自然淡出的光束效果。
fn draw_perimeter_glint(
    target: &ID2D1DCRenderTarget,
    inner: D2D_RECT_F,
    scale: f32,
    phase: f32,
) -> Result<()> {
    // 2 DIP 线宽需要 1 DIP 内缩，保证流光条完全不侵占外圈边框像素。
    let pad = 1.0 * scale;
    let rect = D2D_RECT_F {
        left: inner.left + pad,
        top: inner.top + pad,
        right: inner.right - pad,
        bottom: inner.bottom - pad,
    };
    let w = rect.right - rect.left;
    let h = rect.bottom - rect.top;
    if w <= 2.0 || h <= 2.0 {
        return Ok(());
    }
    // 周长与弧段总长：最短 14 DIP，最长不超过周长的 45%，兼顾小缩略图与宽屏缩略图。
    let perimeter = 2.0 * (w + h);
    let glint_len = (perimeter * GLINT_FRACTION)
        .max(14.0 * scale)
        .min(perimeter * 0.45);
    let head = phase.rem_euclid(1.0) * perimeter;
    let stroke = 2.0 * scale;
    let step = glint_len / GLINT_SEGMENTS as f32;

    // 从尾到头画各段：尾部淡青透明，头部亮青白高光。
    for index in 0..GLINT_SEGMENTS {
        let ratio = (index as f32 + 0.5) / GLINT_SEGMENTS as f32;
        let tail_start = head - glint_len + index as f32 * step;
        let tail_end = tail_start + step;
        let color = blend_rgb(ACCENT_RGB, FLASH_RGB, ratio * ratio);
        let alpha = 0.08 + 0.87 * ratio * ratio;
        let brush = make_brush(target, rgba(color, alpha))?;
        draw_perimeter_arc(target, rect, perimeter, tail_start, tail_end, &brush, stroke);
    }
    Ok(())
}

/// 把周长区间 `[start, end]` 拆成不跨拐角的水平/垂直矩形条绘制在矩形边上。
///
/// 每条边上的矩形条以边线为中线向外各扩半个线宽，拐角自然衔接且无需构造几何路径。
/// 对极小负数做归零保护并限制最大迭代次数，避免 `f32::rem_euclid` 舍入到 `perimeter` 造成死循环。
fn draw_perimeter_arc(
    target: &ID2D1DCRenderTarget,
    rect: D2D_RECT_F,
    perimeter: f32,
    start: f32,
    end: f32,
    brush: &ID2D1SolidColorBrush,
    stroke: f32,
) {
    let w = rect.right - rect.left;
    let h = rect.bottom - rect.top;
    if !(w > 0.0 && h > 0.0 && perimeter.is_finite() && start.is_finite() && end.is_finite()) {
        return;
    }
    let half = stroke / 2.0;
    let corners = [0.0, w, w + h, 2.0 * w + h, perimeter];
    let mut cursor = start;
    for _ in 0..8 {
        if cursor >= end - 1e-3 {
            break;
        }
        // `f32::rem_euclid` 对极小负数加 perimeter 可能舍入成精确等于 perimeter，归零防停滞。
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
        let seg_end = local + advance;
        // 按所在边把 `[local, seg_end]` 映射成轴对齐细矩形，拐角两端各补半个线宽。
        let bar = if seg_end <= w + 1e-3 {
            D2D_RECT_F {
                left: rect.left + local - half,
                top: rect.top - half,
                right: rect.left + seg_end + half,
                bottom: rect.top + half,
            }
        } else if seg_end <= w + h + 1e-3 {
            D2D_RECT_F {
                left: rect.right - half,
                top: rect.top + (local - w) - half,
                right: rect.right + half,
                bottom: rect.top + (seg_end - w) + half,
            }
        } else if seg_end <= 2.0 * w + h + 1e-3 {
            D2D_RECT_F {
                left: rect.right - (seg_end - w - h) - half,
                top: rect.bottom - half,
                right: rect.right - (local - w - h) + half,
                bottom: rect.bottom + half,
            }
        } else {
            D2D_RECT_F {
                left: rect.left - half,
                top: rect.bottom - (seg_end - 2.0 * w - h).min(h) - half,
                right: rect.left + half,
                bottom: rect.bottom - (local - 2.0 * w - h).min(h) + half,
            }
        };
        // SAFETY: 矩形与画刷在调用期间有效。
        unsafe { target.FillRectangle(&bar, brush) };
        cursor += advance;
    }
}

/// 画开启瞬间的对角半透明流光带，裁剪在内框内以免溢出到外圈活动高亮边框。
///
/// 用高密度薄水平切片拼出倾斜光带（每片约 2 DIP 高），配合 `PushAxisAlignedClip` 裁在内框内，
/// 兼顾顺滑的倾斜光感与零路径分配开销。
fn draw_engage_sheen(
    target: &ID2D1DCRenderTarget,
    inner: D2D_RECT_F,
    scale: f32,
    progress: f32,
) -> Result<()> {
    let p = progress.clamp(0.0, 1.0);
    // 淡入后平滑淡出：两端透明度接近 0，中段清亮；显式拦截非有限值。
    let envelope = (p * std::f32::consts::PI).sin();
    if !envelope.is_finite() || envelope <= 0.01 {
        return Ok(());
    }
    let w = inner.right - inner.left;
    let h = inner.bottom - inner.top;
    let skew = h * 0.35;
    let outer_band = (w * 0.28).max(28.0 * scale);
    let core_band = outer_band * 0.42;
    let travel = w + skew + outer_band * 2.0;
    let center_x = inner.left - outer_band - skew * 0.5 + travel * p;
    let strips = (h / (2.0 * scale)).round().clamp(16.0, 64.0) as usize;
    let outer_brush = make_brush(target, rgba(ACCENT_RGB, 0.16 * envelope))?;
    let core_brush = make_brush(target, rgba(FLASH_RGB, 0.32 * envelope))?;

    // SAFETY: PushAxisAlignedClip 与 PopAxisAlignedClip 成对出现，保证光带不越出内框。
    unsafe { target.PushAxisAlignedClip(&inner, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE) };
    let strip_h = h / strips as f32;
    for index in 0..strips {
        let top = inner.top + index as f32 * strip_h;
        // 向下倾斜：顶部靠右、底部靠左，形成自左上向右下扫过的光束倾角。
        let y_ratio = (index as f32 + 0.5) / strips as f32;
        let x = center_x + skew * (0.5 - y_ratio);
        let outer_rect = D2D_RECT_F {
            left: x - outer_band / 2.0,
            top,
            right: x + outer_band / 2.0,
            bottom: top + strip_h + 0.5,
        };
        let core_rect = D2D_RECT_F {
            left: x - core_band / 2.0,
            top,
            right: x + core_band / 2.0,
            bottom: top + strip_h + 0.5,
        };
        // SAFETY: 矩形与画刷在调用期间有效。
        unsafe {
            target.FillRectangle(&outer_rect, &outer_brush);
            target.FillRectangle(&core_rect, &core_brush);
        }
    }
    // SAFETY: 与上面的 PushAxisAlignedClip 配对。
    unsafe { target.PopAxisAlignedClip() };
    Ok(())
}

/// 画四角 L 型战术锁扣。
///
/// 每只角由一横一竖两条实心矩形臂组成，向内缩 `2 DIP + clamp_offset`，
/// 始终与外圈活动高亮边框保持清晰间隙。
fn draw_corner_clamps(
    target: &ID2D1DCRenderTarget,
    inner: D2D_RECT_F,
    scale: f32,
    lock: &OverlayLock,
) -> Result<()> {
    let inner_w = inner.right - inner.left;
    let inner_h = inner.bottom - inner.top;
    let short_dip = inner_w.min(inner_h) / scale;
    let preferred_dip = (short_dip * 0.14).clamp(10.0, 18.0);
    let safe_max_dip = (short_dip / 2.0 - 3.0).max(0.0);
    let arm = preferred_dip.min(safe_max_dip) * scale;
    if arm <= 1.0 {
        return Ok(());
    }
    let stroke = 2.0 * scale;
    let base_inset = 2.0 * scale;
    let max_extra = (inner_w.min(inner_h) / 2.0 - base_inset - arm).max(0.0);
    let inset = base_inset + (lock.clamp_offset.max(0.0) * scale).min(max_extra);
    let min_x = inner.left + inset;
    let max_x = inner.right - inset;
    let min_y = inner.top + inset;
    let max_y = inner.bottom - inset;
    if max_x <= min_x || max_y <= min_y {
        return Ok(());
    }

    let rgb = blend_rgb(ACCENT_RGB, FLASH_RGB, lock.flash_mix);
    let brush = make_brush(target, rgba(rgb, lock.clamp_alpha))?;
    // 竖臂从横臂内侧边缘起画（互不重叠），避免半透明呼吸期间角顶点二次混色产生亮斑。
    let v_arm = (arm - stroke).max(0.0);
    let bars = [
        // 左上角。
        D2D_RECT_F {
            left: min_x,
            top: min_y,
            right: min_x + arm,
            bottom: min_y + stroke,
        },
        D2D_RECT_F {
            left: min_x,
            top: min_y + stroke,
            right: min_x + stroke,
            bottom: min_y + stroke + v_arm,
        },
        // 右上角。
        D2D_RECT_F {
            left: max_x - arm,
            top: min_y,
            right: max_x,
            bottom: min_y + stroke,
        },
        D2D_RECT_F {
            left: max_x - stroke,
            top: min_y + stroke,
            right: max_x,
            bottom: min_y + stroke + v_arm,
        },
        // 右下角。
        D2D_RECT_F {
            left: max_x - arm,
            top: max_y - stroke,
            right: max_x,
            bottom: max_y,
        },
        D2D_RECT_F {
            left: max_x - stroke,
            top: max_y - stroke - v_arm,
            right: max_x,
            bottom: max_y - stroke,
        },
        // 左下角。
        D2D_RECT_F {
            left: min_x,
            top: max_y - stroke,
            right: min_x + arm,
            bottom: max_y,
        },
        D2D_RECT_F {
            left: min_x,
            top: max_y - stroke - v_arm,
            right: min_x + stroke,
            bottom: max_y - stroke,
        },
    ];
    // SAFETY: 画刷与矩形在调用期间有效。
    unsafe {
        for bar in &bars {
            if bar.right > bar.left && bar.bottom > bar.top {
                target.FillRectangle(bar, &brush);
            }
        }
    }
    Ok(())
}

/// 在两个 `0xRRGGBB` 颜色之间线性插值，`mix` 范围 0～1。
fn blend_rgb(a: u32, b: u32, mix: f32) -> u32 {
    let t = mix.clamp(0.0, 1.0);
    let lerp = |shift: u32| -> u32 {
        let ca = ((a >> shift) & 0xFF) as f32;
        let cb = ((b >> shift) & 0xFF) as f32;
        (ca + (cb - ca) * t).round().clamp(0.0, 255.0) as u32
    };
    (lerp(16) << 16) | (lerp(8) << 8) | lerp(0)
}

/// `0xRRGGBB` 与不透明度转为 Direct2D 颜色。
fn rgba(rgb: u32, alpha: f32) -> D2D1_COLOR_F {
    let ch = |shift: u32| ((rgb >> shift) & 0xFF) as f32 / 255.0;
    D2D1_COLOR_F {
        r: ch(16),
        g: ch(8),
        b: ch(0),
        a: alpha.clamp(0.0, 1.0),
    }
}

/// 建一个纯色画刷。
fn make_brush(target: &ID2D1DCRenderTarget, fill: D2D1_COLOR_F) -> Result<ID2D1SolidColorBrush> {
    // SAFETY: 颜色结构在调用期间有效。
    unsafe { target.CreateSolidColorBrush(&fill, None) }
}
