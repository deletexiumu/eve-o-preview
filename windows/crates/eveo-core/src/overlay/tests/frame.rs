// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗位置与尺寸：默认位置、收进屏幕、设置页手工填写，以及 Windows 按屏幕缩放换算尺寸。

use super::{left_screen, main_screen, scaled_screen};
use crate::geometry::{ScreenPoint, ScreenRect};
use crate::overlay::OverlayKind;
use crate::overlay::planner::{FrameField, clamped_frame, default_frame, edited_frame, resolved_frame};

/// 默认位置在主屏可见区域的右上角，两个浮窗上下排列、不重叠，间隔 12。
#[test]
fn default_frames() {
    // 左屏排在前面，但默认位置仍在主屏上：主屏按 is_main 找，不按顺序。
    let screens = [left_screen(), main_screen()];
    let intel = default_frame(OverlayKind::Intel, &screens);
    let translation = default_frame(OverlayKind::Translation, &screens);
    assert_eq!(
        intel,
        ScreenRect::new(1728.0 - 20.0 - 380.0, 33.0 + 60.0, 380.0, 260.0)
    );
    assert!(!intel.intersects(&translation));
    assert_eq!(translation.min_y() - intel.max_y(), 12.0);
    assert_eq!(translation.x, intel.x);
}

/// 尺寸夹到上下限；在屏幕内的位置不动。
#[test]
fn clamped_frame_size() {
    let screens = [main_screen()];
    let small = clamped_frame(ScreenRect::new(100.0, 100.0, 10.0, 10.0), &screens);
    assert_eq!(small, ScreenRect::new(100.0, 100.0, 220.0, 120.0));
    let large = clamped_frame(ScreenRect::new(100.0, 100.0, 5000.0, 5000.0), &screens);
    assert_eq!((large.width, large.height), (900.0, 900.0));
    assert_eq!(large.origin(), ScreenPoint::new(100.0, 100.0));
}

/// 屏幕外的 frame 被拉回，至少 40 留在可见区域内；只露出 10 也算不够。
#[test]
fn clamped_frame_pulls_back() {
    let screens = [main_screen()];
    let far_right = clamped_frame(ScreenRect::new(5000.0, 300.0, 300.0, 200.0), &screens);
    assert_eq!((far_right.x, far_right.y), (1728.0 - 40.0, 300.0));
    // 拉到可见区域顶边以上，只留 40 露在可见区域里（顶部 33 被占用）。
    let far_up = clamped_frame(ScreenRect::new(100.0, -900.0, 300.0, 200.0), &screens);
    assert_eq!((far_up.x, far_up.y), (100.0, 33.0 - 200.0 + 40.0));
    // 左边只露出 10，按最近的边拉回到露出 40。
    let sliver = clamped_frame(ScreenRect::new(-290.0, 300.0, 300.0, 200.0), &screens);
    assert_eq!(sliver.x, -260.0);
}

/// 多屏时留在副屏上的 frame 不被拉到主屏；更左边的拉回左屏；没有屏幕时只夹尺寸。
#[test]
fn clamped_frame_multiple_screens() {
    let screens = [main_screen(), left_screen()];
    // 用户把浮窗放在副屏上：位置合法，不能因为它不在主屏就挪走。
    let on_left = ScreenRect::new(-1500.0, 400.0, 300.0, 200.0);
    assert_eq!(clamped_frame(on_left, &screens), on_left);
    let beyond_left = clamped_frame(ScreenRect::new(-4000.0, 400.0, 300.0, 200.0), &screens);
    assert_eq!(beyond_left.x, -1920.0 - 300.0 + 40.0);
    // 没有屏幕（显示器全断开的瞬间）时不知道往哪拉，只夹尺寸，等屏幕回来再重算。
    let none = clamped_frame(ScreenRect::new(9000.0, 9000.0, 1.0, 1.0), &[]);
    assert_eq!(none, ScreenRect::new(9000.0, 9000.0, 220.0, 120.0));
}

/// 不是有限值的坐标按 0、尺寸按默认值处理，不让一份坏配置把浮窗放到算不出的位置。
#[test]
fn clamped_frame_non_finite() {
    let value = clamped_frame(
        ScreenRect::new(f64::NAN, f64::INFINITY, f64::NAN, 200.0),
        &[main_screen()],
    );
    assert_eq!(value, ScreenRect::new(0.0, 0.0, 380.0, 200.0));
}

/// Windows 的 150% 屏幕：默认尺寸、边距与上下限都乘 1.5（看起来与 100% 屏幕上一样大）。
#[test]
fn scaled_screen_sizes() {
    // 右边距 20×1.5=30，顶边距 60×1.5=90，尺寸 380×260 乘 1.5。
    let screens = [scaled_screen()];
    let intel = default_frame(OverlayKind::Intel, &screens);
    assert_eq!(intel, ScreenRect::new(2560.0 - 30.0 - 570.0, 90.0, 570.0, 390.0));
    let translation = default_frame(OverlayKind::Translation, &screens);
    assert_eq!(translation.min_y() - intel.max_y(), 18.0);
    let small = clamped_frame(ScreenRect::new(100.0, 100.0, 10.0, 10.0), &screens);
    assert_eq!((small.width, small.height), (330.0, 180.0));
    let large = clamped_frame(ScreenRect::new(100.0, 100.0, 5000.0, 5000.0), &screens);
    assert_eq!((large.width, large.height), (1350.0, 1350.0));
    // 拉回时留下的长度也乘 1.5。
    let far_right = clamped_frame(ScreenRect::new(9000.0, 300.0, 600.0, 400.0), &screens);
    assert_eq!(far_right.x, 2560.0 - 60.0);
}

/// 没保存过时显示默认位置；保存过时显示收进屏幕后的 frame，与规划器一致。
#[test]
fn resolved_frame_matches_planner() {
    let screens = [main_screen()];
    assert_eq!(
        resolved_frame(None, OverlayKind::Intel, &screens),
        default_frame(OverlayKind::Intel, &screens)
    );
    let saved = ScreenRect::new(5000.0, 300.0, 300.0, 200.0);
    assert_eq!(
        resolved_frame(Some(saved), OverlayKind::Translation, &screens),
        clamped_frame(saved, &screens)
    );
}

/// 从默认位置改一个字段：只改这个字段，其余保持默认位置的值；数值取整。
#[test]
fn edit_keeps_other_fields() {
    let screens = [main_screen()];
    let base = default_frame(OverlayKind::Intel, &screens);
    // 设置页的数字框可能给出小数（输入或拖动），保存前取整。
    let edited = edited_frame(base, FrameField::X, 200.4, &screens).unwrap();
    assert_eq!(edited, ScreenRect::new(200.0, base.y, base.width, base.height));
    let taller = edited_frame(base, FrameField::Height, 400.0, &screens).unwrap();
    assert_eq!(taller, ScreenRect::new(base.x, base.y, base.width, 400.0));
}

/// 尺寸夹到 220×120～900×900。
#[test]
fn edit_clamps_size() {
    let screens = [main_screen()];
    let base = ScreenRect::new(100.0, 100.0, 300.0, 200.0);
    let width = |value: f64| {
        edited_frame(base, FrameField::Width, value, &screens)
            .unwrap()
            .width
    };
    assert_eq!(width(50.0), 220.0);
    assert_eq!(width(5000.0), 900.0);
    let height = edited_frame(base, FrameField::Height, 10.0, &screens)
        .unwrap()
        .height;
    assert_eq!(height, 120.0);
}

/// 移出屏幕的位置被拉回；不是有限值时返回 None，不写配置。
#[test]
fn edit_pulls_back_and_rejects_non_finite() {
    let screens = [main_screen()];
    let base = ScreenRect::new(100.0, 100.0, 300.0, 200.0);
    assert_eq!(
        edited_frame(base, FrameField::X, 9000.0, &screens).unwrap().x,
        1728.0 - 40.0
    );
    // 清空数字框时得到的是 NaN：不改配置。
    assert_eq!(edited_frame(base, FrameField::Y, f64::NAN, &screens), None);
    assert_eq!(
        edited_frame(base, FrameField::Width, f64::INFINITY, &screens),
        None
    );
}
