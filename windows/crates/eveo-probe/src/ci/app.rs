// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用本身的冒烟检查（M4）：在假客户端旁边启动真正的 eve-o-preview.exe，从外面核对它的行为。
// - 配置写到探针输出目录下的临时 APPDATA，不碰运行机器上的真实配置；
// - 每个客户端一个缩略图窗口（按类名与 PID 找），第一次运行写出 config.json，自动排位的布局已保存；
// - 每个缩略图上有一个与它重合的叠加层窗口，左上角画着标题的深色半透明底（截图取色）；
// - 未悬停的缩略图整体半透明（默认不透明度 0.5）：画面与窗口后面的内容各占一半，而不是蒙上一层边框色；
// - 第二个实例发现已有实例后立即退出（单实例）；
// - 用 SendInput 左键点一个角色的缩略图，前台切到那个客户端（手势 → 协调器 → 激活）；
// - 右键拖动这个缩略图，松开后 config.json 里它的位置跟着变（手势 → 拖动提交 → 延迟写盘）；
// - 右键单击弹出菜单，按 Esc 关掉后前台回到原来的客户端，不停在应用看不见的窗口上。
// 结束时强制结束应用进程。

//! `eveo-probe ci --app` 的应用冒烟检查。

use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use eveo_core::geometry::{ScreenRect, main_screen, screen_containing};
use eveo_core::model::EveClient;
use eveo_platform_win::activation;
use eveo_platform_win::discovery::top_level_windows;
use eveo_platform_win::events::foreground_window;
use eveo_platform_win::message_loop::pump_for;
use eveo_platform_win::overlay::OVERLAY_CLASS;
use eveo_platform_win::screens::screens;
use eveo_platform_win::screenshot::Screenshot;
use serde_json::{Value, json};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    MOUSE_EVENT_FLAGS, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    SendInput, VK_ESCAPE,
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
    // 启动前把光标移开（缩略图自动排在主屏左上角），再截一张图：缩略图半透明时透出的就是这些像素。
    park_cursor();
    pump_for(Duration::from_millis(200));
    let before = Screenshot::capture().ok();
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

    if let (Some(frames), Some(config), Some(before)) = (&thumbnails, &config, &before) {
        check_opacity(clients, frames, config, before, report);
    }
    if let Some(frames) = &thumbnails {
        check_overlays(pid, frames, report);
    }

    // 单实例检查用同一个 APPDATA，但互斥量按会话判断，与配置目录无关。
    check_single_instance(app, &data, report);

    if let (Some(frames), Some(config)) = (thumbnails, config) {
        check_click_and_drag(clients, &frames, &config, &config_path, report);
    }
    // 强制结束：正常退出走托盘菜单，探针没法点托盘；配置已在拖动后写盘，不依赖退出时的写盘。
    let _ = child.kill();
    let _ = child.wait();
}

/// 未悬停时整个缩略图半透明：中心像素应接近「客户端颜色 × 0.5 + 启动前同一点的像素 × 0.5」。
///
/// 只把 DWM 画面设成半透明时，透出的是窗口底色（边框色或高亮色），结果偏向那个颜色，这项检查会失败。
fn check_opacity(
    clients: &[EveClient],
    frames: &[ScreenRect],
    config: &Value,
    before: &Screenshot,
    report: &mut Report,
) {
    // 取第一个有角色名的客户端；它的颜色按 FAKES 的顺序对应（clients 与 FAKES 同序）。
    let Some((index, name)) = clients
        .iter()
        .enumerate()
        .find_map(|(i, c)| c.character_name().map(|n| (i, n)))
    else {
        return;
    };
    let Some(frame) = frame_for(config, frames, name) else {
        return;
    };
    let color = super::FAKES[index].color;
    let point = (frame.mid_x().round() as i32, frame.mid_y().round() as i32);
    let Some(behind) = before.pixel(point.0, point.1) else {
        return;
    };
    // 默认不透明度 0.5：每个通道是两者的平均。允许 ±40，容下系统合成的取整与伽马差异。
    let channel = |shift: u32| ((color >> shift) & 0xFF) as i32;
    let expected = (
        (channel(16) + i32::from(behind.0)) / 2,
        (channel(8) + i32::from(behind.1)) / 2,
        (channel(0) + i32::from(behind.2)) / 2,
    );
    let mut seen = None;
    let blended = wait_for(Duration::from_secs(5), || {
        let pixel = Screenshot::capture().ok()?.pixel(point.0, point.1)?;
        seen = Some(pixel);
        let near = |a: u8, b: i32| (i32::from(a) - b).abs() <= 40;
        (near(pixel.0, expected.0) && near(pixel.1, expected.1) && near(pixel.2, expected.2)).then_some(())
    });
    let hex = |(r, g, b): (u8, u8, u8)| format!("{r:02X}{g:02X}{b:02X}");
    report.check(
        "未悬停的缩略图整体半透明（截图取色）",
        blended.is_some(),
        true,
        json!({"point": [point.0, point.1], "client": format!("{color:06X}"), "behind": hex(behind),
            "expected": format!("{:02X}{:02X}{:02X}", expected.0, expected.1, expected.2), "seen": seen.map(hex)}),
    );
}

/// 叠加层：每个缩略图一个、位置与它重合；默认配置显示标题，标题底把画面压暗一半。
///
/// 取色比较同一列上的两点：标题底内侧（左边距 4、底的内边距 5 之间，避开文字）与标题下方的画面。
/// 两点下面是同一个假客户端的纯色画面，标题底处的最亮通道应明显低于下方（50% 黑色叠上去约剩一半）。
fn check_overlays(pid: u32, frames: &[ScreenRect], report: &mut Report) {
    // 叠加层在第一次呈现时画出并显示；等它们全部出现，并且位置与缩略图一一重合。
    let matched = wait_for(Duration::from_secs(5), || {
        let overlays = window_frames(pid, OVERLAY_CLASS);
        let all = overlays.len() == frames.len()
            && frames.iter().all(|f| overlays.iter().any(|o| same_frame(o, f)));
        all.then_some(overlays)
    });
    report.check(
        "每个缩略图上有一个重合的叠加层",
        matched.is_some(),
        true,
        json!({"overlays": window_frames(pid, OVERLAY_CLASS).iter().map(|f| [f.x, f.y, f.width, f.height])
            .collect::<Vec<_>>(), "thumbnails": frames.iter().map(|f| [f.x, f.y, f.width, f.height])
            .collect::<Vec<_>>()}),
    );
    // 取第一个缩略图即可：每个缩略图的叠加层走同一段代码，位置已在上面逐个核对过。
    // 坐标按所在显示器的缩放换算：叠加层的边距与字号都是 DIP，乘以缩放后才是像素。
    let Some(frame) = frames.first() else {
        return;
    };
    // 光标停在缩略图中心：悬停时不透明度是 1，取色不受窗口后面内容的影响。
    move_cursor((frame.mid_x().round() as i32, frame.mid_y().round() as i32));
    let scale = screen_containing(&screens(), frame.center()).map_or(1.0, |s| s.scale);
    // 标题底从 (4, 4) 起，12 点的字高约 16，加 4 的上下空白；取底的竖直中点与它下方 40 点处。
    let x = (frame.x + 6.0 * scale).round() as i32;
    let pill_y = (frame.y + 14.0 * scale).round() as i32;
    let below_y = (frame.y + 50.0 * scale).round() as i32;
    let brightest = |c: (u8, u8, u8)| c.0.max(c.1).max(c.2);
    // 截图要在叠加层画出之后才有意义，所以和窗口一样在超时内反复取；最后一次的取色写进报告，失败时便于判断。
    let mut samples = None;
    let darkened = wait_for(Duration::from_secs(5), || {
        let shot = Screenshot::capture().ok()?;
        let pair = (shot.pixel(x, pill_y)?, shot.pixel(x, below_y)?);
        samples = Some(pair);
        let (pill, below) = (brightest(pair.0), brightest(pair.1));
        (below > 150 && f64::from(pill) < f64::from(below) * 0.7).then_some(())
    });
    report.check(
        "标题的深色底画在缩略图左上角（截图取色）",
        darkened.is_some(),
        true,
        json!({"point": [x, pill_y], "below": [x, below_y], "samples": samples.map(|(a, b)| {
            vec![format!("{:02X}{:02X}{:02X}", a.0, a.1, a.2), format!("{:02X}{:02X}{:02X}", b.0, b.1, b.2)]
        })}),
    );
}

/// 两个矩形是否重合（允许 1 像素的取整误差）。
///
/// 缩略图的 frame 是浮点数，两个窗口各自取整后可能差 1；叠加层与缩略图用同一次取整的结果，
/// 实际应完全相同，放宽 1 像素只是不让检查依赖取整的细节。
fn same_frame(a: &ScreenRect, b: &ScreenRect) -> bool {
    (a.x - b.x).abs() <= 1.0
        && (a.y - b.y).abs() <= 1.0
        && (a.width - b.width).abs() <= 1.0
        && (a.height - b.height).abs() <= 1.0
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
    let Some(frame) = frame_for(config, frames, name) else {
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

    // 右键单击（不拖动）弹出菜单，按 Esc 关掉；前台应回到拖动前的客户端（左键点过的目标）。
    // 弹菜单时应用要把自己的隐藏窗口设成前台，菜单关闭后必须还回去，否则游戏收不到键盘。
    let dropped = (center.0 + DRAG.0, center.1 + DRAG.1);
    click(dropped, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
    pump_for(Duration::from_millis(500));
    let during = foreground_window();
    let escape = [
        super::key_input(VK_ESCAPE.0, false),
        super::key_input(VK_ESCAPE.0, true),
    ];
    // SAFETY: input 在调用期间有效，结构大小如实给出。
    unsafe { SendInput(&escape, size_of_val(&escape[0]) as i32) };
    let restored = wait_for(Duration::from_secs(3), || {
        (foreground_window() == Some(target.id)).then_some(())
    });
    report.check(
        "右键菜单按 Esc 关掉后前台回到客户端",
        restored.is_some(),
        true,
        json!({"target": target.id.0, "duringMenu": during.map(|w| w.0), "after": foreground_window().map(|w| w.0)}),
    );
}

/// 按保存的布局找到某个角色的缩略图：布局的左上角就是缩略图窗口的左上角。
fn frame_for(config: &Value, frames: &[ScreenRect], name: &str) -> Option<ScreenRect> {
    let (x, y) = layout(config, name)?;
    frames
        .iter()
        .find(|f| (f.x - x).abs() < 1.0 && (f.y - y).abs() < 1.0)
        .copied()
}

/// 把光标移到主屏右下角附近，离自动排位的缩略图（主屏左上角起）最远。
fn park_cursor() {
    if let Some(main) = main_screen(&screens()) {
        let frame = main.frame;
        move_cursor((
            (frame.max_x() - 8.0).round() as i32,
            (frame.max_y() - 8.0).round() as i32,
        ));
    }
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
    window_frames(pid, THUMBNAIL_CLASS)
}

/// 应用进程里某个类名的可见顶层窗口的矩形。
fn window_frames(pid: u32, class: &str) -> Vec<ScreenRect> {
    top_level_windows()
        .into_iter()
        .filter(|w| w.pid == pid && w.class_name == class && w.is_visible)
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
