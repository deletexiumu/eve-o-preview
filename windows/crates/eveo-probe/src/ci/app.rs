// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用本身的冒烟检查（M4）：在假客户端旁边启动真正的 eve-o-preview.exe，从外面核对它的行为。
// - 配置写到探针输出目录下的临时 APPDATA，不碰运行机器上的真实配置；
// - 每个客户端一个缩略图窗口（按类名与 PID 找），第一次运行写出 config.json，自动排位的布局已保存；
// - 第二个实例发现已有实例后立即退出（单实例）；
// - 用 SendInput 左键点一个角色的缩略图，前台切到那个客户端（手势 → 协调器 → 激活）；
// - 右键拖动这个缩略图，松开后 config.json 里它的位置跟着变（手势 → 拖动提交 → 延迟写盘）。
// 结束时强制结束应用进程。

//! `eveo-probe ci --app` 的应用冒烟检查。

use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use eveo_core::geometry::ScreenRect;
use eveo_core::model::EveClient;
use eveo_platform_win::activation;
use eveo_platform_win::discovery::top_level_windows;
use eveo_platform_win::events::foreground_window;
use eveo_platform_win::message_loop::pump_for;
use serde_json::{Value, json};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    MOUSE_EVENT_FLAGS, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    SendInput,
};
use windows::Win32::UI::WindowsAndMessaging::SetCursorPos;

use super::{Report, expected_title, mouse_input};

/// 缩略图窗口的类名（见 eveo-platform-win 的 thumbnail 模块）。
const THUMBNAIL_CLASS: &str = "EVEOPreview.Thumbnail";
/// 右键拖动的位移。
const DRAG: (i32, i32) = (120, 60);

/// 启动应用并核对缩略图、配置、单实例、点击切换与拖动保存。
pub(super) fn check(app: &Path, clients: &[EveClient], out: &Path, report: &mut Report) {
    // 每次从空目录开始，保证走的是「第一次运行」的路径（写默认配置、自动排位）。
    let data = out.join("appdata");
    let _ = std::fs::remove_dir_all(&data);
    let config_path = data.join("EVE-O Preview").join("config.json");
    let mut child = match launch(app, &data) {
        Ok(child) => child,
        Err(error) => {
            report.check("启动应用", false, true, json!({"error": error.to_string()}));
            return;
        }
    };
    // 缩略图窗口按进程号认：探针自己的缩略图已销毁，假客户端没有这个类名的窗口。
    let pid = child.id();

    // 每个客户端一个可见的缩略图窗口；第一次运行写出配置，三个角色的自动布局都已保存。
    let expected = clients.len();
    let thumbnails = wait_for(Duration::from_secs(15), || {
        let found = thumbnail_frames(pid);
        (found.len() == expected).then_some(found)
    });
    report.check(
        "应用为每个客户端建一个缩略图窗口",
        thumbnails.is_some(),
        true,
        json!({"found": thumbnail_frames(pid).len(), "expected": expected}),
    );
    // 登录界面的客户端没有角色名，它的位置存在 loginPosition 里，不在 layouts 里。
    let characters: Vec<&str> = clients.iter().filter_map(|c| c.character_name()).collect();
    // 自动布局在第一次规划时写进配置，0.5 秒后写盘；文件可能先以默认配置出现，所以要等到布局齐全。
    let config = wait_for(Duration::from_secs(5), || {
        let config = read_json(&config_path)?;
        characters
            .iter()
            .all(|name| layout(&config, name).is_some())
            .then_some(config)
    });
    report.check(
        "第一次运行写出配置并保存自动布局",
        config.is_some(),
        true,
        json!({"path": config_path.display().to_string(), "exists": config_path.exists()}),
    );

    // 单实例检查用同一个 APPDATA，但互斥量按会话判断，与配置目录无关。
    check_single_instance(app, &data, report);

    if let (Some(frames), Some(config)) = (thumbnails, config) {
        check_click_and_drag(clients, &frames, &config, &config_path, report);
    }
    // 强制结束：正常退出走托盘菜单，探针没法点托盘；配置已在拖动后写盘，不依赖退出时的写盘。
    let _ = child.kill();
    let _ = child.wait();
}

/// 第二个实例：发现已有实例后通知它并立即退出，退出码 0。
fn check_single_instance(app: &Path, data: &Path, report: &mut Report) {
    // 第二个实例在主循环开始前就退出，5 秒足够；超时说明它没认出已有实例，要强制结束。
    let outcome = launch(app, data).map(|mut second| {
        let exited = wait_for(Duration::from_secs(5), || second.try_wait().ok().flatten());
        if exited.is_none() {
            let _ = second.kill();
        }
        exited.map(|status| status.success())
    });
    report.check(
        "第二个实例立即退出（单实例）",
        matches!(outcome, Ok(Some(true))),
        true,
        json!({"outcome": format!("{outcome:?}")}),
    );
}

/// 点第二个角色的缩略图切到它；再右键拖动这个缩略图，核对保存的位置。
fn check_click_and_drag(
    clients: &[EveClient],
    frames: &[ScreenRect],
    config: &Value,
    config_path: &Path,
    report: &mut Report,
) {
    let (Some(first), Some(target)) = (clients.first(), clients.get(1)) else {
        return;
    };
    let Some(name) = target.character_name() else {
        return;
    };
    // 按保存的布局找到它的缩略图：布局的左上角就是缩略图窗口的左上角。
    let Some((x, y)) = layout(config, name) else {
        return;
    };
    let Some(frame) = frames
        .iter()
        .find(|f| (f.x - x).abs() < 1.0 && (f.y - y).abs() < 1.0)
    else {
        report.check(
            "按布局找到缩略图",
            false,
            true,
            json!({"layout": [x, y], "frames": frames.iter().map(|f| [f.x, f.y]).collect::<Vec<_>>()}),
        );
        return;
    };
    // 点中心而不是边缘：边缘带上的左键要等松开才切换，中心按下即切换。
    let center = (frame.mid_x().round() as i32, frame.mid_y().round() as i32);

    // 先让另一个客户端在前台，再点缩略图；否则目标可能本来就在前台，检查不出切换。
    let _ = activation::activate(first.id);
    pump_for(Duration::from_millis(300));
    click(center, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
    let switched = wait_for(Duration::from_secs(5), || {
        (foreground_window() == Some(target.id)).then_some(())
    });
    report.check(
        "左键点缩略图切到对应客户端",
        switched.is_some(),
        true,
        json!({"target": expected_title(&target.display_title()), "foreground": foreground_window().map(|w| w.0)}),
    );

    // 右键拖动：按下、分几步移动、松开。每步之间让应用处理鼠标消息。
    // 右键拖动是移动（不缩放），起点在中心，离边缘超过 12 像素。
    move_cursor(center);
    send(MOUSEEVENTF_RIGHTDOWN);
    pump_for(Duration::from_millis(100));
    for step in 1..=6 {
        move_cursor((center.0 + DRAG.0 * step / 6, center.1 + DRAG.1 * step / 6));
        pump_for(Duration::from_millis(60));
    }
    send(MOUSEEVENTF_RIGHTUP);
    // 写盘有 0.5 秒的延迟。吸附可能把位置拉动几个像素，允许 ±12。
    let moved = wait_for(Duration::from_secs(5), || {
        let (nx, ny) = layout(&read_json(config_path)?, name)?;
        let close = |a: f64, b: f64| (a - b).abs() <= 12.0;
        (close(nx, x + f64::from(DRAG.0)) && close(ny, y + f64::from(DRAG.1))).then_some((nx, ny))
    });
    report.check(
        "右键拖动缩略图后保存新位置",
        moved.is_some(),
        true,
        json!({"before": [x, y], "after": read_json(config_path).and_then(|c| layout(&c, name))
            .map(|(a, b)| vec![a, b]), "drag": [DRAG.0, DRAG.1]}),
    );
}

/// 启动应用：后台模式，APPDATA 与 LOCALAPPDATA 指到 `data`。
fn launch(app: &Path, data: &Path) -> std::io::Result<Child> {
    Command::new(app)
        .arg("--background")
        .env("APPDATA", data)
        .env("LOCALAPPDATA", data.join("local"))
        .spawn()
}

/// 应用进程的可见缩略图窗口的矩形。
fn thumbnail_frames(pid: u32) -> Vec<ScreenRect> {
    top_level_windows()
        .into_iter()
        .filter(|w| w.pid == pid && w.class_name == THUMBNAIL_CLASS && w.is_visible)
        .map(|w| w.frame)
        .collect()
}

/// 当前配置方案里某个角色的布局位置。
fn layout(config: &Value, name: &str) -> Option<(f64, f64)> {
    let active = config.get("activeProfileID")?.as_str()?;
    let profile = config
        .get("profiles")?
        .as_array()?
        .iter()
        .find(|p| p.get("id").and_then(Value::as_str) == Some(active))?;
    let layout = profile.get("layouts")?.get(name)?;
    Some((layout.get("x")?.as_f64()?, layout.get("y")?.as_f64()?))
}

/// 读一个 JSON 文件；不存在或写到一半读不出时返回 `None`。
fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// 每 100 毫秒试一次，直到 `probe` 给出结果或超时。等待期间照常分发本线程的消息。
fn wait_for<T>(timeout: Duration, mut probe: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(value) = probe() {
            return Some(value);
        }
        if Instant::now() >= deadline {
            return None;
        }
        pump_for(Duration::from_millis(100));
    }
}

/// 把光标移到某点。系统据此给光标下（或捕获鼠标）的窗口发移动消息。
fn move_cursor((x, y): (i32, i32)) {
    // SAFETY: 只移动光标。
    let _ = unsafe { SetCursorPos(x, y) };
}

/// 在当前光标位置送一个鼠标按钮事件。
fn send(flags: MOUSE_EVENT_FLAGS) {
    let input = [mouse_input(flags, 0)];
    // SAFETY: input 在调用期间有效，结构大小如实给出。
    unsafe { SendInput(&input, size_of_val(&input[0]) as i32) };
}

/// 在某点按下并松开。
fn click(point: (i32, i32), down: MOUSE_EVENT_FLAGS, up: MOUSE_EVENT_FLAGS) {
    move_cursor(point);
    pump_for(Duration::from_millis(100));
    send(down);
    pump_for(Duration::from_millis(50));
    send(up);
}
