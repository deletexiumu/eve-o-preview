// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图规划的一致性测试：读 shared/fixtures/planner/cases.json，逐例断言（架构文档 5.4 节）。
// macOS 端的对应测试是 SharedPlannerFixtureTests.swift。
// 每个呈现只比较用例里写出的字段；`visible` 对应这里要保持注册的 DWM 缩略图（macOS 是要捕获的窗口）。

//! 与 macOS 共用的缩略图规划用例。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use eveo_core::geometry::{ScreenInfo, ScreenRect};
use eveo_core::model::{ClientIdentity, EveClient, Profile, WindowId};
use eveo_core::planning::{
    self, CombatAlertWindow, FrontmostContext, PlannerInput, SessionState, ThumbnailPlaceholder,
    ThumbnailPresentation, ThumbnailStatus,
};
use eveo_core::support::StringEnum;
use serde_json::{Value, json};

/// 读用例文件。crate 在 windows/crates/eveo-core，往上三级是仓库根目录。
fn load() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures/planner/cases.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}：{e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{} 格式不对：{e}", path.display()))
}

/// [x, y, 宽, 高] → 矩形。
fn rect(v: &Value) -> ScreenRect {
    let n: Vec<f64> = serde_json::from_value(v.clone()).expect("矩形");
    ScreenRect::new(n[0], n[1], n[2], n[3])
}

/// 矩形 → [x, y, 宽, 高]。
fn rect_json(r: ScreenRect) -> Value {
    json!([r.x, r.y, r.width, r.height])
}

/// 窗口编号。
fn window(v: &Value) -> WindowId {
    WindowId(v.as_u64().expect("窗口编号"))
}

/// 客户端。
fn client(v: &Value) -> EveClient {
    let identity = match v["identity"]["kind"].as_str().expect("kind") {
        "character" => ClientIdentity::Character(v["identity"]["name"].as_str().expect("name").to_owned()),
        "login" => ClientIdentity::Login,
        _ => ClientIdentity::Unknown,
    };
    EveClient {
        id: window(&v["id"]),
        pid: u32::try_from(v["pid"].as_u64().expect("pid")).expect("pid"),
        identity,
        window_frame: rect(&v["frame"]),
        is_on_screen: true,
        is_minimized: Some(v["isMinimized"].as_bool().unwrap_or(false)),
        is_full_screen: v["isFullScreen"].as_bool(),
    }
}

/// 前台：`{"client": pid}`、`"selfApp"` 或 `"other"`。
fn frontmost(v: &Value) -> FrontmostContext {
    match v {
        Value::String(s) if s == "selfApp" => FrontmostContext::SelfApp,
        Value::Object(map) => {
            FrontmostContext::Client(u32::try_from(map["client"].as_u64().expect("pid")).expect("pid"))
        }
        _ => FrontmostContext::Other,
    }
}

/// 会话状态，缺的键取默认值。
fn session(v: &Value) -> SessionState {
    let names = |key: &str| -> HashSet<String> {
        serde_json::from_value(v.get(key).cloned().unwrap_or(json!([]))).expect("字符串数组")
    };
    let alerts = v["combatAlerts"].as_object().map_or_else(HashMap::new, |map| {
        map.iter()
            .map(|(id, a)| {
                let window = WindowId(id.parse().expect("窗口编号"));
                let alert = CombatAlertWindow {
                    started_at: a["startedAt"].as_f64().expect("startedAt"),
                    until: a["until"].as_f64().expect("until"),
                };
                (window, alert)
            })
            .collect()
    });
    SessionState {
        hide_all: v["hideAll"].as_bool().unwrap_or(false),
        skipped_characters: names("skippedCharacters"),
        hovered_window: v.get("hoveredWindow").map(window),
        interacting_windows: v["interactingWindows"]
            .as_array()
            .map_or_else(HashSet::new, |a| a.iter().map(window).collect()),
        last_eve_context_at: v["lastEVEContextAt"].as_f64().unwrap_or(0.0),
        last_active_pid: v["lastActivePID"]
            .as_u64()
            .map(|p| u32::try_from(p).expect("pid")),
        combat_alerts: alerts,
    }
}

/// 呈现写成用例里的字段。
fn presentation_json(p: &ThumbnailPresentation) -> Value {
    json!({
        "frame": rect_json(p.frame), "isVisible": p.is_visible, "title": p.title, "showsTitle": p.shows_title,
        "titleFontSize": p.title_font_size, "titleColor": p.title_color, "opacity": p.opacity,
        "highlightColor": p.highlight_color, "highlightThickness": p.highlight_thickness,
        "borderColor": p.border_color, "borderThickness": p.border_thickness,
        "alert": p.alert.as_ref().map(|a| json!({"color": a.color, "style": a.style.raw()})),
        "isActive": p.is_active, "isSkipped": p.is_skipped, "isAlwaysOnTop": p.is_always_on_top,
        "isOverFullScreen": p.is_over_full_screen, "isZoomed": p.is_zoomed,
        "placeholder": match p.placeholder {
            ThumbnailPlaceholder::None => "none",
            ThumbnailPlaceholder::Minimized => "minimized",
            ThumbnailPlaceholder::Unavailable => "unavailable",
        },
    })
}

/// 两个 JSON 值相等，数字按数值比较。
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

/// 逐例规划并核对写出的字段。
#[test]
fn planner_cases() {
    let all = load();
    let cases = all["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for case in cases {
        let name = case["name"].as_str().unwrap_or("?");
        let clients: Vec<EveClient> = case["clients"]
            .as_array()
            .expect("clients")
            .iter()
            .map(client)
            .collect();
        let profile: Profile = serde_json::from_value(case["profile"].clone()).expect("profile");
        let screens: Vec<ScreenInfo> = case["screens"]
            .as_array()
            .expect("screens")
            .iter()
            .map(|s| ScreenInfo {
                frame: rect(&s["frame"]),
                visible_frame: rect(&s["visibleFrame"]),
                scale: s["scale"].as_f64().expect("scale"),
                is_main: s["isMain"].as_bool().expect("isMain"),
            })
            .collect();
        let session = session(&case["session"]);
        // 用例里的画面都正常：全部窗口的缩略图已注册。
        let states: HashMap<WindowId, ThumbnailStatus> =
            clients.iter().map(|c| (c.id, ThumbnailStatus::Shown)).collect();
        let input = PlannerInput {
            clients: &clients,
            frontmost: frontmost(&case["frontmost"]),
            profile: &profile,
            session: &session,
            screens: &screens,
            thumbnail_states: &states,
            now: case["now"].as_f64().expect("now"),
        };
        let plan = planning::plan(&input);
        let expect = &case["expect"];
        let wanted = expect["presentations"].as_array().expect("presentations");
        assert_eq!(plan.presentations.len(), wanted.len(), "{name}");
        for (index, (got, want)) in plan.presentations.iter().zip(wanted).enumerate() {
            let got = presentation_json(got);
            for (key, value) in want.as_object().expect("呈现") {
                assert!(
                    same(&got[key], value),
                    "{name} 第 {} 个 {key}：得到 {}，期望 {value}",
                    index + 1,
                    got[key]
                );
            }
        }
        if let Some(layouts) = expect.get("layoutsToPersist") {
            let got = serde_json::to_value(&plan.layouts_to_persist).expect("布局");
            assert!(same(&got, layouts), "{name} layoutsToPersist：得到 {got}");
        }
        if let Some(visible) = expect.get("visible") {
            let got: Vec<u64> = plan.thumbnails.iter().map(|w| w.0).collect();
            assert!(same(&json!(got), visible), "{name} visible：得到 {got:?}");
        }
        if let Some(wake) = expect.get("nextWakeAt") {
            assert!(
                same(&json!(plan.next_wake_at), wake),
                "{name} nextWakeAt：得到 {:?}",
                plan.next_wake_at
            );
        }
    }
}
