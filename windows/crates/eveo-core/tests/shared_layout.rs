// SPDX-License-Identifier: GPL-3.0-or-later
//
// 布局的一致性测试：读 shared/fixtures/layout/cases.json，逐组断言（架构文档 5.4 节）。
// macOS 端的对应测试是 SharedLayoutFixtureTests.swift。用例里矩形写成 [x, y, 宽, 高]，尺寸 [宽, 高]，点 [x, y]。

//! 与 macOS 共用的布局用例。

use std::path::PathBuf;

use eveo_core::geometry::{ScreenInfo, ScreenPoint, ScreenRect, ScreenSize};
use eveo_core::layout::{self, ResizeEdges, SnapTargets, edge_grip, resolver, snap};
use eveo_core::model::{
    ClientIdentity, EveClient, Profile, ThumbnailLayout, ThumbnailSettings, WindowId, ZoomAnchor,
};
use eveo_core::support::StringEnum;
use serde_json::Value;

/// 读用例文件。crate 在 windows/crates/eveo-core，往上三级是仓库根目录。
fn load() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures/layout/cases.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}：{e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{} 格式不对：{e}", path.display()))
}

/// 读一组用例。
fn group<'a>(all: &'a Value, key: &str) -> &'a Vec<Value> {
    let cases = all[key].as_array().unwrap_or_else(|| panic!("缺少 {key}"));
    assert!(!cases.is_empty(), "{key} 为空");
    cases
}

/// 数字数组。
fn nums(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("期望数组")
        .iter()
        .map(|n| n.as_f64().expect("期望数字"))
        .collect()
}

/// [x, y, 宽, 高] → 矩形。
fn rect(v: &Value) -> ScreenRect {
    let n = nums(v);
    ScreenRect::new(n[0], n[1], n[2], n[3])
}

/// [宽, 高] → 尺寸。
fn size(v: &Value) -> ScreenSize {
    let n = nums(v);
    ScreenSize::new(n[0], n[1])
}

/// [x, y] → 点。
fn point(v: &Value) -> ScreenPoint {
    let n = nums(v);
    ScreenPoint::new(n[0], n[1])
}

/// 屏幕列表。
fn screens(v: &Value) -> Vec<ScreenInfo> {
    v.as_array()
        .expect("期望数组")
        .iter()
        .map(|s| ScreenInfo {
            frame: rect(&s["frame"]),
            visible_frame: rect(&s["visibleFrame"]),
            scale: s["scale"].as_f64().unwrap(),
            // 共用用例来自 macOS，全局坐标是点，尺寸不换算。
            size_scale: 1.0,
            is_main: s["isMain"].as_bool().unwrap(),
        })
        .collect()
}

/// 吸附目标。
fn targets(v: &Value) -> SnapTargets {
    let list = |key: &str| v[key].as_array().unwrap().iter().map(rect).collect();
    SnapTargets {
        neighbors: list("neighbors"),
        screens: list("screens"),
    }
}

/// 边的名字列表 → 边集合。
fn edges(v: &Value) -> ResizeEdges {
    v.as_array().unwrap().iter().fold(ResizeEdges::NONE, |acc, name| {
        acc | match name.as_str().unwrap() {
            "left" => ResizeEdges::LEFT,
            "right" => ResizeEdges::RIGHT,
            "top" => ResizeEdges::TOP,
            "bottom" => ResizeEdges::BOTTOM,
            other => panic!("不认识的边 {other}"),
        }
    })
}

/// 用例名。
fn name(case: &Value) -> &str {
    case["name"].as_str().unwrap_or("?")
}

/// 移动吸附与缩放吸附的结果。
fn check_snap(case: &Value, result: snap::SnapResult) {
    let expected = &case["expected"];
    assert_eq!(result.rect, rect(&expected["rect"]), "{}", name(case));
    assert_eq!(
        result.snapped_x,
        expected["snappedX"].as_f64(),
        "{}：snappedX",
        name(case)
    );
    assert_eq!(
        result.snapped_y,
        expected["snappedY"].as_f64(),
        "{}：snappedY",
        name(case)
    );
}

/// 吸附、边缘判断、尺寸夹取、拉回屏幕、放大与裁剪。
#[test]
fn geometry_cases() {
    let all = load();
    for case in group(&all, "snapMove") {
        let threshold = case["threshold"].as_f64().unwrap();
        check_snap(
            case,
            snap::snap_move(rect(&case["proposed"]), &targets(&case["targets"]), threshold),
        );
    }
    for case in group(&all, "snapResize") {
        let result = snap::snap_resize(
            rect(&case["proposed"]),
            edges(&case["movingEdges"]),
            &targets(&case["targets"]),
            case["threshold"].as_f64().unwrap(),
            size(&case["minimum"]),
            size(&case["maximum"]),
            case["aspectRatio"].as_f64(),
        );
        check_snap(case, result);
    }
    for case in group(&all, "resizeEdges") {
        let actual = snap::resize_edges(
            point(&case["point"]),
            rect(&case["rect"]),
            case["margin"].as_f64().unwrap(),
        );
        assert_eq!(actual, edges(&case["expected"]), "{}", name(case));
    }
    for case in group(&all, "edgeGrip") {
        let actual = edge_grip::edges(
            point(&case["point"]),
            rect(&case["rect"]),
            edge_grip::BAND_WIDTH,
            edge_grip::CORNER_LENGTH,
        );
        assert_eq!(actual, edges(&case["expected"]), "{}", name(case));
    }
    for case in group(&all, "clampSize") {
        let actual = resolver::clamp_size(
            size(&case["size"]),
            &ThumbnailSettings::default(),
            case["aspectRatio"].as_f64(),
        );
        assert_eq!(actual, size(&case["expected"]), "{}", name(case));
    }
    for case in group(&all, "clampToScreens") {
        let actual = resolver::clamp_to_screens(
            rect(&case["rect"]),
            &screens(&case["screens"]),
            case["minimumVisible"].as_f64().unwrap(),
        );
        assert_eq!(actual, rect(&case["expected"]), "{}", name(case));
    }
    for case in group(&all, "zoom") {
        let anchor = ZoomAnchor::from_raw(case["anchor"].as_str().unwrap()).unwrap();
        let actual = layout::zoomed_frame(rect(&case["base"]), case["factor"].as_i64().unwrap(), anchor);
        assert_eq!(actual, rect(&case["expected"]), "{}", name(case));
    }
    for case in group(&all, "crop") {
        let r = layout::contents_rect(size(&case["sourceSize"]), case["cropHeight"].as_f64().unwrap());
        let n = nums(&case["expected"]);
        assert_eq!(
            [r.x, r.y, r.width, r.height],
            [n[0], n[1], n[2], n[3]],
            "{}",
            name(case)
        );
    }
}

/// 缩略图的基准 frame。
#[test]
fn resolve_frame_cases() {
    let all = load();
    for case in group(&all, "resolveFrame") {
        let identity = match case["identity"]["kind"].as_str().unwrap() {
            "character" => ClientIdentity::Character(case["identity"]["name"].as_str().unwrap().to_owned()),
            "login" => ClientIdentity::Login,
            "unknown" => ClientIdentity::Unknown,
            other => panic!("不认识的 kind {other}"),
        };
        let client = EveClient {
            id: WindowId(1),
            pid: 10,
            identity,
            window_frame: ScreenRect::new(0.0, 33.0, 1728.0, 1018.0),
            is_on_screen: true,
            is_minimized: Some(false),
            is_full_screen: None,
        };
        let mut profile = Profile::new("p", "T");
        for (character, layout) in case["layouts"].as_object().unwrap() {
            let layout: ThumbnailLayout = serde_json::from_value(layout.clone()).unwrap();
            profile.layouts.insert(character.clone(), layout);
        }
        let occupied: Vec<ScreenRect> = case["occupied"].as_array().unwrap().iter().map(rect).collect();
        let login_index = case["loginIndex"].as_u64().unwrap() as usize;
        let result = resolver::frame(
            &client,
            login_index,
            &profile,
            &screens(&case["screens"]),
            &occupied,
        );
        assert_eq!(result.frame, rect(&case["expected"]["frame"]), "{}", name(case));
        assert_eq!(
            result.is_auto_placed,
            case["expected"]["isAutoPlaced"].as_bool().unwrap(),
            "{}",
            name(case)
        );
    }
}
