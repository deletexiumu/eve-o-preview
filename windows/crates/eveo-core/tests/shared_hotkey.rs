// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的一致性测试：读 shared/fixtures/hotkey/cases.json，逐组断言（架构文档 5.4 节）。
// macOS 端的对应测试是 SharedHotkeyFixtureTests.swift。
// 期望值是一个对象且带 `macos`、`windows` 两个键时，两端的结果不同，这里取 `windows`。

//! 与 macOS 共用的热键用例。

use std::path::PathBuf;

use eveo_core::config::one_time_defaults;
use eveo_core::hotkeys::{
    HotkeyAction, HotkeyIssue, HotkeyPlan, HotkeyRejection, HotkeyScope, HotkeySpec, MouseBinding,
    MouseButtonEventKind, MouseHotkeyDecision, MouseHotkeyMatcher, planner,
};
use eveo_core::model::{AppConfig, Profile};
use eveo_core::support::StringEnum;
use eveo_core::switching::CycleDirection;
use serde_json::{Value, json};

/// 读用例文件。crate 在 windows/crates/eveo-core，往上三级是仓库根目录。
fn load() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures/hotkey/cases.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}：{e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{} 格式不对：{e}", path.display()))
}

/// 读一组用例。
fn group<'a>(value: &'a Value, key: &str) -> &'a Vec<Value> {
    let cases = value[key].as_array().unwrap_or_else(|| panic!("缺少 {key}"));
    assert!(!cases.is_empty(), "{key} 为空");
    cases
}

/// 本平台的期望值：分平台写的取 `windows`，否则原样。
fn expected(value: &Value) -> &Value {
    match value {
        Value::Object(map) if map.contains_key("windows") && map.contains_key("macos") => &map["windows"],
        other => other,
    }
}

/// 用例的名字。
fn name(case: &Value) -> &str {
    case["name"].as_str().unwrap_or("?")
}

/// 动作写成用例里的字符串。
fn action_name(action: &HotkeyAction) -> String {
    match action {
        HotkeyAction::Cycle { group_id, direction } => {
            let dir = match direction {
                CycleDirection::Forward => "forward",
                CycleDirection::Backward => "backward",
            };
            format!("cycle:{group_id}:{dir}")
        }
        HotkeyAction::ActivateCharacter(name) => format!("character:{name}"),
        HotkeyAction::CycleLoginClients => "cycleLoginClients".into(),
        HotkeyAction::ToggleHideAll => "toggleHideAll".into(),
        HotkeyAction::MinimizeAll => "minimizeAll".into(),
    }
}

/// 拒绝原因写成用例里的字符串。
fn reason_name(reason: HotkeyRejection) -> &'static str {
    match reason {
        HotkeyRejection::MissingModifier => "missingModifier",
        HotkeyRejection::SystemReserved => "systemReserved",
        HotkeyRejection::UnsupportedMouseButton => "unsupportedMouseButton",
    }
}

/// 规划结果写成与用例相同的 JSON 形状。
fn plan_json(plan: &HotkeyPlan) -> Value {
    let bindings: Vec<Value> = plan
        .bindings
        .iter()
        .map(|b| {
            json!({"id": b.id, "hotkey": b.hotkey.to_string(), "action": action_name(&b.action),
                   "scope": b.scope.raw()})
        })
        .collect();
    let issues: Vec<Value> = plan
        .issues
        .iter()
        .map(|issue| match issue {
            HotkeyIssue::Unparsable { text, action } => {
                json!({"kind": "unparsable", "text": text, "action": action_name(action)})
            }
            HotkeyIssue::Duplicate {
                hotkey,
                kept,
                dropped,
            } => json!({"kind": "duplicate",
                "hotkey": hotkey.to_string(), "kept": action_name(kept), "dropped": action_name(dropped)}),
            HotkeyIssue::Rejected {
                hotkey,
                action,
                reason,
            } => json!({"kind": "rejected",
                "hotkey": hotkey.to_string(), "action": action_name(action), "reason": reason_name(*reason)}),
        })
        .collect();
    json!({"bindings": bindings, "issues": issues})
}

/// 解析：规范写法或解析失败。
#[test]
fn parse() {
    let all = load();
    for case in group(&all, "parse") {
        let input = case["input"].as_str().expect("input");
        let got = HotkeySpec::parse(input).map(|s| s.to_string());
        let want = expected(&case["expect"]).as_str().map(str::to_owned);
        assert_eq!(got, want, "{}：{input:?}", name(case));
        // 规范写法能解析回同一个结果。
        if let Some(text) = &got {
            assert_eq!(
                HotkeySpec::parse(text).map(|s| s.to_string()).as_ref(),
                Some(text),
                "{}",
                name(case)
            );
        }
    }
}

/// 规划：绑定与问题。
#[test]
fn plan() {
    let all = load();
    for case in group(&all, "plan") {
        let profile: Profile = serde_json::from_value(case["profile"].clone()).expect("profile");
        assert_eq!(
            plan_json(&planner::plan(&profile)),
            *expected(&case["expect"]),
            "{}",
            name(case)
        );
    }
}

/// 用例里的热键字符串 → 按钮号与修饰键。
fn mouse(text: &str) -> (u8, eveo_core::hotkeys::HotkeyModifiers) {
    let hotkey = HotkeySpec::parse(text).expect("鼠标热键").hotkey;
    (hotkey.mouse_button().expect("鼠标按键"), hotkey.modifiers)
}

/// 鼠标匹配器：逐步执行并核对决定、截止时刻与监听状态。
#[test]
fn mouse_matcher() {
    let all = load();
    for case in group(&all, "mouseMatcher") {
        let mut matcher = MouseHotkeyMatcher::new();
        for (index, step) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let at = format!("{} 第 {} 步", name(case), index + 1);
            match step["op"].as_str().expect("op") {
                "bindings" => {
                    let bindings = step["bindings"].as_array().expect("bindings").iter().map(|b| {
                        let (button, modifiers) = mouse(b["hotkey"].as_str().expect("hotkey"));
                        MouseBinding {
                            id: u32::try_from(b["id"].as_u64().expect("id")).expect("id"),
                            button,
                            modifiers,
                            scope: HotkeyScope::from_raw(b["scope"].as_str().expect("scope")).expect("scope"),
                        }
                    });
                    matcher.replace_bindings(bindings.collect());
                }
                "frontmost" => matcher.set_game_frontmost(step["value"].as_bool().expect("value")),
                "suspended" => matcher.set_suspended(step["value"].as_bool().expect("value")),
                "hookRemoved" => matcher.hook_was_removed(),
                "refresh" => {
                    let got = matcher.refresh_release_deadline(step["now"].as_f64().expect("now"));
                    assert_eq!(got, step["expect"].as_f64(), "{at}");
                }
                "check" => {
                    assert_eq!(
                        Some(matcher.should_listen()),
                        step["shouldListen"].as_bool(),
                        "{at}"
                    );
                    assert_eq!(
                        Some(matcher.has_active_binding()),
                        step["hasActiveBinding"].as_bool(),
                        "{at}"
                    );
                }
                op => {
                    let kind = match op {
                        "down" => MouseButtonEventKind::Down,
                        "up" => MouseButtonEventKind::Up,
                        "dragged" => MouseButtonEventKind::Dragged,
                        other => panic!("{at}：不认识的 op {other}"),
                    };
                    let (button, modifiers) = mouse(step["hotkey"].as_str().expect("hotkey"));
                    let got = match matcher.handle(kind, button, modifiers) {
                        MouseHotkeyDecision::Pass => "pass".to_owned(),
                        MouseHotkeyDecision::Swallow => "swallow".to_owned(),
                        MouseHotkeyDecision::Fire(id) => format!("fire:{id}"),
                    };
                    assert_eq!(Some(got.as_str()), step["expect"].as_str(), "{at}");
                }
            }
        }
    }
}

/// 字符串数组。
fn strings(value: &Value) -> Vec<String> {
    serde_json::from_value(value.clone()).expect("字符串数组")
}

/// 一次性默认值：待补的项与补后的结果。
#[test]
fn one_time_defaults() {
    let all = load();
    let groups = &all["oneTimeDefaults"];
    for case in group(groups, "pending") {
        let got = one_time_defaults::pending(&strings(&case["applied"]));
        assert_eq!(got, strings(&case["expect"]), "{}", name(case));
    }
    for case in group(groups, "apply") {
        let profiles: Vec<Profile> = serde_json::from_value(case["profiles"].clone()).expect("profiles");
        let config = AppConfig {
            active_profile_id: profiles[0].id.clone(),
            profiles,
            ..AppConfig::default()
        };
        let result = one_time_defaults::apply(&strings(&case["ids"]), &config);
        let want = expected(&case["expect"]).as_array().expect("expect");
        assert_eq!(result.profiles.len(), want.len(), "{}", name(case));
        for (profile, want) in result.profiles.iter().zip(want) {
            let at = format!("{} / {}", name(case), profile.id);
            assert_eq!(
                profile.hotkeys.toggle_hide_all,
                strings(&want["toggleHideAll"]),
                "{at}"
            );
            if let Some(on) = want["highlightEnabled"].as_bool() {
                assert_eq!(profile.overlay.highlight_enabled, on, "{at}");
            }
            if let Some(color) = want["highlightColor"].as_str() {
                assert_eq!(profile.overlay.highlight_color, color, "{at}");
            }
        }
    }
}
