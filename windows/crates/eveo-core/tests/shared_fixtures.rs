// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一致性测试：读 shared/fixtures 里与 macOS 共用的用例，逐个断言（架构文档 5.4 节）。
// macOS 端的对应测试是 macos/Tests/EVEOPreviewCoreTests/SharedFixtureTests.swift。

//! 与 macOS 共用的一致性用例。

use std::collections::HashSet;
use std::path::PathBuf;

use eveo_core::clients::{selector, title};
use eveo_core::geometry::ScreenRect;
use eveo_core::model::{ClientIdentity, Pid, WindowId, WindowInfo};
use eveo_core::switching::{CycleDirection, cycle};
use serde::Deserialize;

/// 读 shared/fixtures 下的一个 JSON 文件。crate 在 windows/crates/eveo-core，往上三级是仓库根目录。
fn load<T: for<'de> Deserialize<'de>>(relative: &str) -> T {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/fixtures")
        .join(relative);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}：{e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{} 格式不对：{e}", path.display()))
}

/// JSON 里的方向写法。
#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Direction {
    /// 前进。
    Forward,
    /// 后退。
    Backward,
}

impl From<Direction> for CycleDirection {
    fn from(d: Direction) -> Self {
        match d {
            Direction::Forward => CycleDirection::Forward,
            Direction::Backward => CycleDirection::Backward,
        }
    }
}

// ---- title ----

/// title/cases.json 的顶层。
#[derive(Deserialize)]
struct TitleFile {
    /// 全部用例。
    cases: Vec<TitleCase>,
}

/// 一个标题用例。
#[derive(Deserialize)]
struct TitleCase {
    /// 用例说明。
    name: String,
    /// 窗口标题，`None` 表示读不到。
    title: Option<String>,
    /// 进程 ID，用于未知客户端的显示标题。
    pid: Pid,
    /// 期望的身份与显示标题。
    expected: TitleExpected,
}

/// 标题用例的期望输出。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TitleExpected {
    /// `character`、`login` 或 `unknown`。
    kind: String,
    /// 角色名，只有 `character` 有。
    name: Option<String>,
    /// 缩略图上显示的标题。
    display_title: String,
}

/// 窗口标题 → 身份与显示标题。
#[test]
fn title_cases() {
    let file: TitleFile = load("title/cases.json");
    assert!(!file.cases.is_empty());
    for case in file.cases {
        let expected = match case.expected.kind.as_str() {
            "character" => ClientIdentity::Character(case.expected.name.clone().expect("character 缺 name")),
            "login" => ClientIdentity::Login,
            "unknown" => ClientIdentity::Unknown,
            other => panic!("{}：不认识的 kind {other}", case.name),
        };
        let actual = title::identity(case.title.as_deref());
        assert_eq!(actual, expected, "{}", case.name);
        assert_eq!(
            title::display_title(&actual, case.pid),
            case.expected.display_title,
            "{}",
            case.name
        );
    }
}

// ---- cycle ----

/// cycle/cases.json 的顶层。
#[derive(Deserialize)]
struct CycleFile {
    /// 循环组用例。
    group: Vec<GroupCase>,
    /// 登录客户端循环用例。
    login: Vec<LoginCase>,
}

/// 一个循环组用例。
#[derive(Deserialize)]
struct GroupCase {
    /// 用例说明。
    name: String,
    /// 组成员，按循环顺序。
    members: Vec<String>,
    /// 方向。
    direction: Direction,
    /// 当前激活的角色。
    active: Option<String>,
    /// 在运行的角色。
    running: Vec<String>,
    /// 被跳过的角色。
    skipped: Vec<String>,
    /// 期望的下一个角色。
    expected: Option<String>,
}

/// 一个登录客户端循环用例。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoginCase {
    /// 用例说明。
    name: String,
    /// 登录客户端的 PID，顺序任意。
    pids: Vec<Pid>,
    /// 当前前台的登录客户端。
    #[serde(rename = "activePID")]
    active_pid: Option<Pid>,
    /// 方向。
    direction: Direction,
    /// 期望的下一个 PID。
    expected: Option<Pid>,
}

/// 循环组与登录客户端的下一个目标。
#[test]
fn cycle_cases() {
    let file: CycleFile = load("cycle/cases.json");
    assert!(!file.group.is_empty() && !file.login.is_empty());
    for case in file.group {
        let running: HashSet<String> = case.running.into_iter().collect();
        let skipped: HashSet<String> = case.skipped.into_iter().collect();
        let actual = cycle::next(
            &case.members,
            case.direction.into(),
            case.active.as_deref(),
            &running,
            &skipped,
        );
        assert_eq!(actual, case.expected.as_deref(), "{}", case.name);
    }
    for case in file.login {
        let actual = cycle::next_login_client(&case.pids, case.active_pid, case.direction.into());
        assert_eq!(actual, case.expected, "{}", case.name);
    }
}

// ---- clients ----

/// clients/main-windows.json 的顶层。
#[derive(Deserialize)]
struct SelectorFile {
    /// 全部用例。
    cases: Vec<SelectorCase>,
}

/// 一个主窗口挑选用例。
#[derive(Deserialize)]
struct SelectorCase {
    /// 用例说明。
    name: String,
    /// 候选窗口。
    windows: Vec<FixtureWindow>,
    /// 期望选出的窗口 ID，按 PID 升序。
    expected: Vec<u64>,
}

/// 用例里的一个候选窗口。
#[derive(Deserialize)]
struct FixtureWindow {
    /// 窗口 ID。
    id: u64,
    /// 进程 ID。
    pid: Pid,
    /// 标题，`None` 表示读不到。
    title: Option<String>,
    /// 左边。
    x: f64,
    /// 上边。
    y: f64,
    /// 宽度。
    width: f64,
    /// 高度。
    height: f64,
}

impl From<FixtureWindow> for WindowInfo {
    fn from(w: FixtureWindow) -> Self {
        WindowInfo {
            window_id: WindowId(w.id),
            pid: w.pid,
            title: w.title,
            frame: ScreenRect::new(w.x, w.y, w.width, w.height),
            is_on_screen: true,
            is_minimized: None,
            is_full_screen: None,
        }
    }
}

/// 一批候选窗口 → 每个进程的主窗口。
#[test]
fn main_window_cases() {
    let file: SelectorFile = load("clients/main-windows.json");
    assert!(!file.cases.is_empty());
    for case in file.cases {
        let windows: Vec<WindowInfo> = case.windows.into_iter().map(Into::into).collect();
        let actual: Vec<u64> = selector::main_windows(&windows)
            .iter()
            .map(|w| w.window_id.0)
            .collect();
        assert_eq!(actual, case.expected, "{}", case.name);
    }
}
