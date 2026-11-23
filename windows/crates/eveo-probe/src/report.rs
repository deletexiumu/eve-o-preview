// SPDX-License-Identifier: GPL-3.0-or-later
//
// 在装了真实客户端的机器上收集待实测的事实（架构文档 8.3 节）：
// W1 客户端窗口的类名、进程名、每个进程的顶层窗口数量与尺寸；W3 最小化时 DWM 缩略图的源尺寸；
// W5 各客户端激活走到的步骤（加 --activate 才测，会依次切换前台）；W8 客户端与本工具是否以管理员运行。
// 结果写成一个 JSON 文件，除角色名外不含个人信息；--redact 把角色名换成「角色 1」「角色 2」。

//! `eveo-probe report` 与 `eveo-probe list`。

use std::collections::BTreeMap;
use std::time::Duration;

use eveo_core::clients::selector;
use eveo_core::geometry::ScreenRect;
use eveo_core::model::EveClient;
use eveo_platform_win::activation::{self, ActivationStep};
use eveo_platform_win::discovery::{self, ClientFilter};
use eveo_platform_win::events::foreground_window;
use eveo_platform_win::message_loop::pump_for;
use eveo_platform_win::process::{self, process_info};
use eveo_platform_win::screens;
use eveo_platform_win::thumbnail::ThumbnailWindow;
use serde_json::{Value, json};

use crate::option;

/// 矩形 → [x, y, 宽, 高]。
fn rect_json(r: ScreenRect) -> Value {
    json!([r.x, r.y, r.width, r.height])
}

/// 列出全部顶层窗口（可见的在前），打印成表格。
pub fn list() -> i32 {
    // 与应用一样按每显示器 DPI 感知运行，打印的坐标才是物理像素，能与应用的布局对照。
    screens::enable_per_monitor_dpi();
    // 只列可见窗口：隐藏的窗口数量多，对判定客户端没有帮助。
    for window in discovery::top_level_windows()
        .into_iter()
        .filter(|w| w.is_visible)
    {
        // 读不到进程信息（例如受保护的系统进程）时显示问号，不跳过这一行。
        let process = process_info(window.pid)
            .map(|p| p.image_name)
            .unwrap_or_else(|| "?".into());
        println!(
            "{:>10}  {:>6}  {:<24}  {:<28}  {:?}  {}",
            window.hwnd,
            window.pid,
            process,
            window.class_name,
            rect_json(window.frame).to_string(),
            window.title.unwrap_or_default()
        );
    }
    0
}

/// 收集事实写成 JSON，返回退出码。
pub fn run(args: &[String]) -> i32 {
    let Some(out) = option(args, "--out") else {
        eprintln!("用法：eveo-probe report --out <文件> [--redact] [--activate]");
        return 2;
    };
    // --redact：角色名换成编号，报告可以直接贴到公开的议题里。
    let redact = args.iter().any(|a| a == "--redact");
    // --activate：会依次切换前台，运行期间不要操作电脑；不加时只读不改。
    let activate = args.iter().any(|a| a == "--activate");
    screens::enable_per_monitor_dpi();

    // W1：凡是 exefile.exe 的顶层窗口都列出来，不限类名，用来确认类名与窗口数量。
    let filter = ClientFilter {
        process_names: vec!["exefile.exe".into()],
        class_names: Vec::new(),
    };
    let candidates = discovery::candidate_windows(&filter);
    let mut names = Names::new(redact);
    // 每个进程有几个 exefile.exe 顶层窗口：大于 1 时主窗口挑选（Core 的 selector）才有意义。
    let mut per_process: BTreeMap<u32, usize> = BTreeMap::new();
    let windows: Vec<Value> = candidates
        .iter()
        .map(|c| {
            *per_process.entry(c.window.pid).or_default() += 1;
            json!({
                "pid": c.window.pid, "class": c.class_name, "process": c.process.image_name,
                "processPath": c.process.path, "elevated": c.process.elevated,
                "title": c.window.title.as_deref().map(|t| names.title(t)),
                "frame": rect_json(c.window.frame), "minimized": c.window.is_minimized,
                "fullScreen": c.window.is_full_screen,
            })
        })
        .collect();
    // 用与应用相同的规则挑主窗口，报告里的客户端就是应用会显示缩略图的那些。
    let main = selector::main_windows(&candidates.iter().map(|c| c.window.clone()).collect::<Vec<_>>());
    let clients: Vec<EveClient> = main.iter().map(EveClient::from_window).collect();

    let thumbnails = thumbnail_facts(&clients, &mut names);
    let activation = if activate {
        activation_facts(&clients, &mut names)
    } else {
        Value::Null
    };
    // 报告的键名带 W 编号，与架构文档第 9 节的待实测清单对应。
    let report = json!({
        "probeVersion": env!("CARGO_PKG_VERSION"),
        "probeElevated": process::current_process_elevated(),
        "screens": screens::screens().iter().map(|s| json!({
            "frame": rect_json(s.frame), "work": rect_json(s.visible_frame), "scale": s.scale, "main": s.is_main,
        })).collect::<Vec<_>>(),
        "w1Windows": windows,
        "w1WindowsPerProcess": per_process,
        "clients": clients.iter().map(|c| json!({"title": names.title(&c.display_title()), "pid": c.pid})).collect::<Vec<_>>(),
        "w3Thumbnails": thumbnails,
        "w5Activation": activation,
    });
    match std::fs::write(out, serde_json::to_string_pretty(&report).unwrap_or_default()) {
        Ok(()) => {
            println!("已写入 {out}，共 {} 个客户端窗口", clients.len());
            0
        }
        Err(error) => {
            eprintln!("写不了 {out}：{error}");
            1
        }
    }
}

/// W3：给每个客户端注册一个临时缩略图，记下源尺寸与客户端是否最小化。
fn thumbnail_facts(clients: &[EveClient], names: &mut Names) -> Value {
    let facts: Vec<Value> = clients
        .iter()
        .map(|client| {
            // 窗口放在左上角、不置顶，只为拿到源尺寸；注册后等一会儿让 DWM 准备好。
            let result =
                ThumbnailWindow::create(ScreenRect::new(0.0, 0.0, 192.0, 108.0), false).and_then(|mut t| {
                    t.register(client.id)?;
                    pump_for(Duration::from_millis(200));
                    Ok(t.source_size())
                });
            json!({
                "client": names.title(&client.display_title()),
                "minimized": client.is_minimized,
                "sourceSize": result.as_ref().ok().cloned().flatten(),
                "error": result.err().map(|e| e.message()),
            })
        })
        .collect();
    json!(facts)
}

/// W5：依次激活每个客户端，记下走到的步骤与是否真成了前台，最后把原来的前台还回去。
fn activation_facts(clients: &[EveClient], names: &mut Names) -> Value {
    let original = foreground_window();
    let facts: Vec<Value> = clients
        .iter()
        .map(|client| {
            // 每次激活后等 300 毫秒再读前台：激活是异步生效的。
            let outcome = activation::activate(client.id);
            pump_for(Duration::from_millis(300));
            json!({
                "client": names.title(&client.display_title()),
                "step": match outcome.step {
                    ActivationStep::AlreadyForeground => "alreadyForeground",
                    ActivationStep::Direct => "direct",
                    ActivationStep::AfterSyntheticInput => "afterSyntheticInput",
                    ActivationStep::AttachedInput => "attachedInput",
                    ActivationStep::Failed => "failed",
                },
                "restored": outcome.restored,
                "foreground": foreground_window() == Some(client.id),
            })
        })
        .collect();
    // 把用户原来的前台窗口还回去，探针跑完后桌面与开始时一样。
    if let Some(original) = original {
        activation::activate(original);
    }
    json!(facts)
}

/// 角色名的脱敏：同一个名字总是换成同一个编号。
struct Names {
    redact: bool,
    seen: BTreeMap<String, usize>,
}

impl Names {
    /// 建一个映射；redact 为假时原样输出。
    fn new(redact: bool) -> Self {
        Self {
            redact,
            seen: BTreeMap::new(),
        }
    }

    /// 窗口标题（`EVE - 角色名`）或显示名（角色名）。登录界面的 `EVE`、`EVE (<pid>)` 原样保留，
    /// 角色名按需换成编号，标题的 `EVE - ` 前缀保留。
    fn title(&mut self, text: &str) -> String {
        // 登录界面的标题不含角色名，脱敏时原样保留，便于区分登录客户端。
        if !self.redact || text == "EVE" || text.starts_with("EVE (") {
            return text.to_owned();
        }
        let (prefix, name) = match text.strip_prefix("EVE - ") {
            Some(name) => ("EVE - ", name),
            None => ("", text),
        };
        // 编号按第一次出现的顺序给，同一个角色在报告各处编号相同。
        let next = self.seen.len() + 1;
        let index = *self.seen.entry(name.to_owned()).or_insert(next);
        format!("{prefix}角色 {index}")
    }
}
