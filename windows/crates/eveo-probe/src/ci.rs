// SPDX-License-Identifier: GPL-3.0-or-later
//
// CI 集成探针（架构文档 8.2 节）：启动四个假客户端（三个已登录、一个在登录界面），然后逐项核对：
// 运行环境（DWM、前台、显示器）、发现与 Core 的主窗口挑选、DWM 缩略图（截图取色）、激活、
// 键盘热键（SendInput 触发 RegisterHotKey）、重复注册的冲突、鼠标中键与侧键热键（低级鼠标钩子，含重装）、
// 这些原生窗口与钩子在 Slint 事件循环里共存（W7）、窗口事件、最小化后的缩略图。
// 每一项记成 report.json 里的一条检查；必需项失败时整次运行失败。

//! `eveo-probe ci`。

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use eveo_core::clients::selector;
use eveo_core::geometry::ScreenRect;
use eveo_core::hotkeys::backend::hotkey_id;
use eveo_core::hotkeys::{Hotkey, HotkeyModifiers, HotkeyScope, MouseBinding, MouseHotkeyMatcher};
use eveo_core::model::{EveClient, WindowId};
use eveo_platform_win::activation::{self, ActivationStep};
use eveo_platform_win::discovery::{self, ClientFilter};
use eveo_platform_win::events::{WindowEvent, WindowEventHooks, foreground_window};
use eveo_platform_win::hotkey::{HotkeyWindow, RegisterError};
use eveo_platform_win::message_loop::{pump_for, pump_until};
use eveo_platform_win::mouse_hook::MouseHook;
use eveo_platform_win::screenshot::Screenshot;
use eveo_platform_win::thumbnail::ThumbnailWindow;
use eveo_platform_win::{hwnd, process, screens};
use serde_json::{Value, json};
use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::Graphics::Dwm::DwmIsCompositionEnabled;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBD_EVENT_FLAGS, KEYBDINPUT, KEYEVENTF_KEYUP,
    MOUSE_EVENT_FLAGS, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP,
    MOUSEINPUT, SendInput, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WM_CLOSE, XBUTTON1};

use crate::option;

mod app;
mod event_loop;

/// 一个假客户端的设定：标题、颜色（RRGGBB）、位置。
struct FakeSpec {
    title: &'static str,
    color: u32,
    x: i32,
    y: i32,
}

/// 四个假客户端：三个已登录的角色与一个登录界面。客户区 640×360，正好是 Core 认可的最小主窗口尺寸。
const FAKES: [FakeSpec; 4] = [
    FakeSpec {
        title: "EVE - Test Pilot 1",
        color: 0xE0_2020,
        x: 20,
        y: 20,
    },
    FakeSpec {
        title: "EVE - Test Pilot 2",
        color: 0x20_C020,
        x: 80,
        y: 80,
    },
    FakeSpec {
        title: "EVE - Test Pilot 3",
        color: 0x20_20E0,
        x: 140,
        y: 140,
    },
    FakeSpec {
        title: "EVE",
        color: 0xE0_E020,
        x: 200,
        y: 200,
    },
];

/// 客户区尺寸。
const CLIENT_SIZE: (i32, i32) = (640, 360);

/// 缩略图尺寸。
const THUMBNAIL_SIZE: (f64, f64) = (192.0, 108.0);

/// 截图取色的容差（每个通道）。
const COLOR_TOLERANCE: i32 = 48;

/// 检查结果的累积。
#[derive(Default)]
struct Report {
    checks: Vec<Value>,
    failed_required: Vec<String>,
}

impl Report {
    /// 记一条检查。
    fn check(&mut self, name: &str, ok: bool, required: bool, detail: Value) {
        println!(
            "[{}] {name}{}",
            if ok { "通过" } else { "失败" },
            if required { "" } else { "（参考项）" }
        );
        if !ok {
            println!("       {detail}");
        }
        if !ok && required {
            self.failed_required.push(name.to_owned());
        }
        self.checks
            .push(json!({"name": name, "ok": ok, "required": required, "detail": detail}));
    }
}

/// 运行 CI 探针，返回退出码。
pub fn run(args: &[String]) -> i32 {
    let (Some(fake), Some(out)) = (option(args, "--fake-client"), option(args, "--out")) else {
        eprintln!(
            "用法：eveo-probe ci --fake-client <exefile.exe 的路径> --out <目录> [--app <eve-o-preview.exe 的路径>]"
        );
        return 2;
    };
    let out = PathBuf::from(out);
    if let Err(error) = std::fs::create_dir_all(&out) {
        eprintln!("建不了输出目录 {}：{error}", out.display());
        return 2;
    }
    screens::enable_per_monitor_dpi();
    let mut report = Report::default();
    let environment = environment(&mut report);
    let hooks = WindowEventHooks::install();
    report.check("窗口事件钩子全部注册", hooks.is_complete(), true, json!({}));

    let mut children = spawn_fakes(Path::new(fake), &mut report);
    let clients = discover(&mut report);
    let thumbnails = if clients.len() == FAKES.len() {
        check_thumbnails(&clients, &out, &mut report)
    } else {
        Vec::new()
    };
    if clients.len() == FAKES.len() {
        check_activation(&clients, &hooks, &mut report);
        check_hotkeys(&mut report);
        check_mouse_hotkeys(&mut report);
        event_loop::check(&clients, &hooks, &mut report);
        check_minimized(&clients, &thumbnails, &out, &mut report);
    }
    drop(thumbnails);
    // 应用本身的冒烟检查放在最后：探针自己的缩略图已经销毁，不会与应用的缩略图混在一起。
    if let Some(app_path) = option(args, "--app")
        && clients.len() == FAKES.len()
    {
        app::check(Path::new(app_path), &clients, &out, &mut report);
    }
    close_fakes(&clients, &mut children, &hooks, &mut report);

    let summary = json!({
        "environment": environment,
        "checks": report.checks,
        "failedRequired": report.failed_required,
    });
    let path = out.join("report.json");
    if let Err(error) = std::fs::write(&path, serde_json::to_string_pretty(&summary).unwrap_or_default()) {
        eprintln!("写不了 {}：{error}", path.display());
        return 1;
    }
    println!("报告：{}", path.display());
    if report.failed_required.is_empty() {
        0
    } else {
        eprintln!("必需项失败：{}", report.failed_required.join("、"));
        1
    }
}

/// 运行环境：DWM 合成、前台窗口、显示器、本进程权限。
fn environment(report: &mut Report) -> Value {
    // SAFETY: 只读。
    let dwm = unsafe { DwmIsCompositionEnabled() }
        .map(|b| b.as_bool())
        .unwrap_or(false);
    let screens = screens::screens();
    let foreground = foreground_window();
    report.check("DWM 合成在运行", dwm, true, json!({}));
    report.check(
        "至少有一块显示器",
        !screens.is_empty(),
        true,
        json!({"count": screens.len()}),
    );
    report.check(
        "有前台窗口（可交互的桌面会话）",
        foreground.is_some(),
        false,
        json!({}),
    );
    json!({
        "dwmComposition": dwm,
        "elevated": process::current_process_elevated(),
        "screens": screens.iter().map(|s| json!({
            "frame": rect_json(s.frame), "work": rect_json(s.visible_frame), "scale": s.scale, "main": s.is_main,
        })).collect::<Vec<_>>(),
    })
}

/// 矩形 → [x, y, 宽, 高]。
fn rect_json(r: ScreenRect) -> Value {
    json!([r.x, r.y, r.width, r.height])
}

/// 启动四个假客户端。
fn spawn_fakes(path: &Path, report: &mut Report) -> Vec<Child> {
    let mut children = Vec::new();
    for spec in &FAKES {
        let spawned = Command::new(path)
            .args(["--title", spec.title, "--color", &format!("{:06X}", spec.color)])
            .args(["--x", &spec.x.to_string(), "--y", &spec.y.to_string()])
            .args([
                "--width",
                &CLIENT_SIZE.0.to_string(),
                "--height",
                &CLIENT_SIZE.1.to_string(),
            ])
            .spawn();
        match spawned {
            Ok(child) => children.push(child),
            Err(error) => report.check(
                "启动假客户端",
                false,
                true,
                json!({"title": spec.title, "error": error.to_string()}),
            ),
        }
    }
    children
}

/// 等假客户端出现，核对发现与 Core 的主窗口挑选。返回按 FAKES 顺序排列的客户端。
fn discover(report: &mut Report) -> Vec<EveClient> {
    let filter = ClientFilter::default();
    let started = Instant::now();
    let mut found = Vec::new();
    while started.elapsed() < Duration::from_secs(20) {
        pump_for(Duration::from_millis(200));
        found = discovery::candidate_windows(&filter);
        if found.len() >= FAKES.len() {
            break;
        }
    }
    let windows: Vec<_> = found.iter().map(|c| c.window.clone()).collect();
    let main = selector::main_windows(&windows);
    let clients: Vec<EveClient> = main.iter().map(EveClient::from_window).collect();
    let mut ordered = Vec::new();
    for spec in &FAKES {
        if let Some(client) = clients
            .iter()
            .find(|c| c.display_title() == expected_title(spec.title))
        {
            ordered.push(client.clone());
        }
    }
    let detail = json!({
        "elapsedMs": started.elapsed().as_millis() as u64,
        "candidates": found.iter().map(|c| json!({
            "title": c.window.title, "class": c.class_name, "process": c.process.image_name,
            "frame": rect_json(c.window.frame), "elevated": c.process.elevated,
        })).collect::<Vec<_>>(),
        "clients": clients.iter().map(|c| c.display_title()).collect::<Vec<_>>(),
    });
    report.check(
        "发现四个假客户端并识别出角色与登录界面",
        ordered.len() == FAKES.len(),
        true,
        detail,
    );
    ordered
}

/// 假客户端的标题在缩略图上显示成什么：角色名，或登录界面的 `EVE`。
fn expected_title(title: &str) -> &str {
    title.strip_prefix("EVE - ").unwrap_or(title)
}

/// 每个客户端建一个缩略图窗口，截图核对缩略图中心的颜色与源尺寸。
fn check_thumbnails(clients: &[EveClient], out: &Path, report: &mut Report) -> Vec<ThumbnailWindow> {
    let Some(screen) = screens::screens().into_iter().find(|s| s.is_main) else {
        return Vec::new();
    };
    let work = screen.visible_frame;
    let mut thumbnails = Vec::new();
    for (index, client) in clients.iter().enumerate() {
        let frame = ScreenRect::new(
            work.x + work.width - THUMBNAIL_SIZE.0 - 16.0,
            work.y + 16.0 + index as f64 * (THUMBNAIL_SIZE.1 + 12.0),
            THUMBNAIL_SIZE.0,
            THUMBNAIL_SIZE.1,
        );
        let created = ThumbnailWindow::create(frame, true).and_then(|mut t| {
            t.register(client.id)?;
            t.set_appearance(2, true, 255)?;
            Ok(t)
        });
        match created {
            Ok(thumbnail) => thumbnails.push(thumbnail),
            Err(error) => report.check(
                "注册 DWM 缩略图",
                false,
                true,
                json!({"client": client.display_title(), "error": error.message()}),
            ),
        }
    }
    pump_for(Duration::from_millis(1000));
    let shot = match Screenshot::capture() {
        Ok(shot) => shot,
        Err(error) => {
            report.check("截取屏幕", false, true, json!({"error": error.message()}));
            return thumbnails;
        }
    };
    let _ = shot.write_bmp(&out.join("thumbnails.bmp"));
    let mut all_ok = thumbnails.len() == clients.len();
    let mut details = Vec::new();
    for ((thumbnail, client), spec) in thumbnails.iter().zip(clients).zip(&FAKES) {
        let center = thumbnail.frame().center();
        let got = shot.pixel(center.x as i32, center.y as i32);
        let ok = got.is_some_and(|c| close_to(c, spec.color));
        let source = thumbnail.source_size();
        all_ok &= ok && source == Some(CLIENT_SIZE);
        details.push(json!({
            "client": client.display_title(), "expected": format!("{:06X}", spec.color),
            "got": got.map(|(r, g, b)| format!("{r:02X}{g:02X}{b:02X}")), "sourceSize": source,
        }));
    }
    report.check(
        "缩略图显示对应客户端的画面（截图取色）且只取客户区",
        all_ok,
        true,
        json!(details),
    );
    thumbnails
}

/// 颜色是否接近 RRGGBB。
fn close_to((r, g, b): (u8, u8, u8), expected: u32) -> bool {
    let channel = |shift: u32| ((expected >> shift) & 0xFF) as i32;
    (i32::from(r) - channel(16)).abs() <= COLOR_TOLERANCE
        && (i32::from(g) - channel(8)).abs() <= COLOR_TOLERANCE
        && (i32::from(b) - channel(0)).abs() <= COLOR_TOLERANCE
}

/// 依次激活每个客户端，核对前台窗口、升级步骤与前台事件。
///
/// 前台事件逐次核对：每次激活后取出这段时间的事件，只要求真正换了前台的那几次（步骤不是
/// `alreadyForeground`）收到该客户端的前台事件。最后启动的假客户端本来就在前台，激活它不会有事件。
fn check_activation(clients: &[EveClient], hooks: &WindowEventHooks, report: &mut Report) {
    hooks.drain();
    let mut details = Vec::new();
    let mut events_ok = true;
    let mut all_ok = true;
    for client in clients.iter().rev().chain(clients.iter().take(1)) {
        let outcome = activation::activate(client.id);
        pump_for(Duration::from_millis(150));
        let foreground = foreground_window() == Some(client.id);
        all_ok &= outcome.succeeded() && foreground;
        let events = hooks.drain();
        let changed = outcome.step != ActivationStep::AlreadyForeground;
        let event = events.contains(&WindowEvent::Foreground(client.id));
        events_ok &= !changed || event;
        details.push(json!({
            "client": client.display_title(), "step": step_name(outcome.step), "foreground": foreground,
            "foregroundEvent": event, "eventCount": events.len(),
        }));
    }
    report.check("激活客户端并成为前台", all_ok, true, json!(details));
    report.check("每次换前台都收到前台变化事件", events_ok, true, json!(details));
}

/// 激活步骤的名字。
fn step_name(step: ActivationStep) -> &'static str {
    match step {
        ActivationStep::AlreadyForeground => "alreadyForeground",
        ActivationStep::Direct => "direct",
        ActivationStep::AfterSyntheticInput => "afterSyntheticInput",
        ActivationStep::AttachedInput => "attachedInput",
        ActivationStep::Failed => "failed",
    }
}

/// 注册 Ctrl+Shift+F13，用 SendInput 按下，核对收到热键消息；再从另一个窗口注册同一组合，核对报冲突。
/// 不用 Alt：Alt 会让前台的假客户端进入菜单状态。
fn check_hotkeys(report: &mut Report) {
    let hotkey = Hotkey::parse("ctrl+shift+F13").expect("固定的热键字符串");
    let Some(key) = hotkey.key_code() else {
        return;
    };
    let id = hotkey_id::encode(1, 1).expect("编号在范围内");
    let mut window = match HotkeyWindow::create() {
        Ok(window) => window,
        Err(error) => {
            report.check("建热键消息窗口", false, true, json!({"error": error.message()}));
            return;
        }
    };
    let registered = window.register(id, hotkey.modifiers, key);
    report.check(
        "注册 Ctrl+Shift+F13",
        registered.is_ok(),
        true,
        json!({"error": format!("{registered:?}")}),
    );
    if registered.is_err() {
        return;
    }
    let mut other = HotkeyWindow::create().ok();
    let conflict = other
        .as_mut()
        .map(|w| w.register(hotkey_id::encode(1, 2).unwrap_or(2), hotkey.modifiers, key));
    report.check(
        "重复注册同一组合时报冲突",
        matches!(conflict, Some(Err(RegisterError::AlreadyRegistered))),
        true,
        json!({"result": format!("{conflict:?}")}),
    );
    send_chord(&[0x11, 0x10], key);
    let mut received = None;
    let fired = pump_until(Duration::from_secs(3), |msg| {
        received = window.hotkey_id(msg);
        received.is_some()
    });
    let decoded = received.and_then(hotkey_id::decode);
    report.check(
        "按下组合键收到热键消息，编号能解回代数与绑定",
        fired && decoded == Some((1, 1)),
        true,
        json!({"received": received, "decoded": decoded}),
    );
}

/// 一个键盘事件。
fn key_input(vk: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                ..Default::default()
            },
        },
    }
}

/// 一个鼠标按钮事件。
fn mouse_input(flags: MOUSE_EVENT_FLAGS, data: u32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dwFlags: flags,
                mouseData: data,
                ..Default::default()
            },
        },
    }
}

/// 按下修饰键，送出中间的事件，再按相反顺序抬起修饰键。
fn send_with_modifiers(modifiers: &[u16], middle: [INPUT; 2]) {
    let mut inputs: Vec<INPUT> = modifiers.iter().map(|&m| key_input(m, false)).collect();
    inputs.extend(middle);
    inputs.extend(modifiers.iter().rev().map(|&m| key_input(m, true)));
    // SAFETY: inputs 在调用期间有效，结构大小如实给出。
    unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
}

/// 用 SendInput 按下修饰键与键，再按相反顺序抬起。
fn send_chord(modifiers: &[u16], key: u8) {
    let key = u16::from(key);
    send_with_modifiers(modifiers, [key_input(key, false), key_input(key, true)]);
}

/// 鼠标中键与侧键热键：低级鼠标钩子在专用线程，命中时吞掉按下与松开并通知主线程；重装后照样工作。
fn check_mouse_hotkeys(report: &mut Report) {
    const VK_CONTROL: u16 = 0x11;
    const VK_SHIFT: u16 = 0x10;
    let window = match HotkeyWindow::create() {
        Ok(window) => window,
        Err(error) => {
            report.check(
                "建鼠标热键的通知窗口",
                false,
                true,
                json!({"error": error.message()}),
            );
            return;
        }
    };
    let mut matcher = MouseHotkeyMatcher::new();
    matcher.replace_bindings(vec![
        MouseBinding {
            id: 7,
            button: 2,
            modifiers: HotkeyModifiers::CONTROL,
            scope: HotkeyScope::Global,
        },
        MouseBinding {
            id: 8,
            button: 3,
            modifiers: HotkeyModifiers::CONTROL | HotkeyModifiers::SHIFT,
            scope: HotkeyScope::Global,
        },
    ]);
    let hook = match MouseHook::start(Arc::new(Mutex::new(matcher)), window.hwnd()) {
        Ok(hook) => hook,
        Err(error) => {
            report.check("安装低级鼠标钩子", false, true, json!({"error": error}));
            return;
        }
    };
    let wait_fire = |timeout: Duration| {
        let mut fired = None;
        pump_until(timeout, |msg| {
            fired = MouseHook::fired_binding(msg);
            fired.is_some()
        });
        fired
    };
    let pending = |hook: &MouseHook| {
        let matcher = hook.matcher().lock().unwrap_or_else(|e| e.into_inner());
        matcher.swallowed_buttons().len()
    };

    let middle = [
        mouse_input(MOUSEEVENTF_MIDDLEDOWN, 0),
        mouse_input(MOUSEEVENTF_MIDDLEUP, 0),
    ];
    send_with_modifiers(&[VK_CONTROL], middle);
    let fired = wait_fire(Duration::from_secs(3));
    pump_for(Duration::from_millis(100));
    let left = pending(&hook);
    report.check(
        "Ctrl+中键触发鼠标热键，按下与松开都被吞掉",
        fired == Some(7) && left == 0,
        true,
        json!({"fired": fired, "unreleased": left}),
    );

    send_with_modifiers(&[], middle);
    let fired = wait_fire(Duration::from_millis(500));
    report.check(
        "修饰键不符时放行，不触发",
        fired.is_none() && pending(&hook) == 0,
        true,
        json!({"fired": fired}),
    );

    hook.reinstall();
    let deadline = Instant::now() + Duration::from_secs(2);
    while hook.install_count() < 2 && Instant::now() < deadline {
        pump_for(Duration::from_millis(50));
    }
    let reinstalled = hook.install_count() >= 2;
    let x1 = XBUTTON1 as u32;
    let side = [
        mouse_input(MOUSEEVENTF_XDOWN, x1),
        mouse_input(MOUSEEVENTF_XUP, x1),
    ];
    send_with_modifiers(&[VK_CONTROL, VK_SHIFT], side);
    let fired = wait_fire(Duration::from_secs(3));
    report.check(
        "重装钩子后 Ctrl+Shift+侧键照样触发",
        reinstalled && fired == Some(8),
        true,
        json!({"installs": hook.install_count(), "fired": fired}),
    );
}

/// 最小化第一个客户端，截图看缩略图显示什么（对应真实客户端的 W3），再还原。只作参考。
fn check_minimized(clients: &[EveClient], thumbnails: &[ThumbnailWindow], out: &Path, report: &mut Report) {
    let (Some(client), Some(thumbnail)) = (clients.first(), thumbnails.first()) else {
        return;
    };
    activation::minimize(client.id);
    pump_for(Duration::from_millis(1000));
    let center = thumbnail.frame().center();
    let shot = Screenshot::capture().ok();
    if let Some(shot) = &shot {
        let _ = shot.write_bmp(&out.join("minimized.bmp"));
    }
    let got = shot.and_then(|s| s.pixel(center.x as i32, center.y as i32));
    report.check(
        "最小化后缩略图仍显示最后一帧",
        got.is_some_and(|c| close_to(c, FAKES[0].color)),
        false,
        json!({"got": got.map(|(r, g, b)| format!("{r:02X}{g:02X}{b:02X}")), "sourceSize": thumbnail.source_size()}),
    );
    let restored = activation::activate(client.id);
    report.check(
        "从最小化还原并激活",
        restored.succeeded() && restored.restored,
        false,
        json!({"step": step_name(restored.step)}),
    );
}

/// 关闭假客户端，核对销毁事件；超时没退出的强制结束。
fn close_fakes(clients: &[EveClient], children: &mut [Child], hooks: &WindowEventHooks, report: &mut Report) {
    hooks.drain();
    for client in clients {
        // SAFETY: 向别的进程的窗口投递关闭消息，句柄失效时只是失败。
        let _ = unsafe { PostMessageW(Some(hwnd(client.id)), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    for child in children.iter_mut() {
        while Instant::now() < deadline && matches!(child.try_wait(), Ok(None)) {
            pump_for(Duration::from_millis(100));
        }
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
        }
        let _ = child.wait();
    }
    pump_for(Duration::from_millis(300));
    let events = hooks.drain();
    let destroyed: Vec<WindowId> = clients
        .iter()
        .map(|c| c.id)
        .filter(|id| events.contains(&WindowEvent::Destroyed(*id)))
        .collect();
    report.check(
        "关闭客户端时收到销毁事件",
        destroyed.len() == clients.len(),
        false,
        json!({"destroyed": destroyed.len(), "expected": clients.len()}),
    );
}
