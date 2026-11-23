// SPDX-License-Identifier: GPL-3.0-or-later
//
// 无窗口截图（架构文档 8.4 节的界面截图回归）：用 Slint 的软件渲染器把界面画进内存，再编码成 PNG。
// 不需要显示器，Linux 容器与 CI 都能跑；云端改界面时直接看图。
// Slint 的平台每个进程只能设一次，所以这里的窗口放在线程局部变量里，各次截图共用。

//! 用软件渲染器把界面画成 PNG。

use std::cell::RefCell;
use std::rc::Rc;

use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, PhysicalSize, PlatformError};

use eveo_core::geometry::ScreenRect;
use eveo_core::model::{ClientIdentity, EveClient, Pid, Profile, WindowId};

use crate::SettingsWindow;

/// 一次截图的设定。
#[derive(Debug, Clone)]
pub struct ShotOptions {
    /// 暗色外观。
    pub dark: bool,
    /// 逻辑尺寸（与 Windows 100% 缩放时的像素相同）。
    pub size: (u32, u32),
    /// 缩放比例，1.5 对应 Windows 的 150%。
    pub scale: f32,
    /// 界面字体。Windows 上是 Segoe UI Variable；Linux 截图用装着的近似字体。
    pub font: String,
    /// 设置窗口的页，编号同 `SettingsWindow.page`。
    pub page: i32,
}

/// 只给软件渲染器用的平台。
struct Headless {
    window: Rc<MinimalSoftwareWindow>,
}

impl Platform for Headless {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        Ok(self.window.clone())
    }
}

thread_local! {
    /// 本线程的软件渲染窗口；第一次截图时创建并设为 Slint 的平台。
    static WINDOW: RefCell<Option<Rc<MinimalSoftwareWindow>>> = const { RefCell::new(None) };
}

/// 取（或创建）软件渲染窗口。
fn window() -> Result<Rc<MinimalSoftwareWindow>, String> {
    WINDOW.with(|cell| {
        if let Some(window) = cell.borrow().as_ref() {
            return Ok(window.clone());
        }
        let window = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
        slint::platform::set_platform(Box::new(Headless {
            window: window.clone(),
        }))
        .map_err(|e| format!("设置 Slint 平台失败：{e}"))?;
        *cell.borrow_mut() = Some(window.clone());
        Ok(window)
    })
}

/// 设好软件渲染平台（每个进程一次），单元测试建窗口前调用。
#[cfg(test)]
pub(crate) fn ensure_platform() -> Result<(), String> {
    window().map(|_| ())
}

/// 把设置窗口画成 PNG，返回文件内容。
pub fn settings_png(options: &ShotOptions) -> Result<Vec<u8>, String> {
    let window = window()?;
    // 先设缩放比例，再按物理像素设窗口大小：逻辑尺寸乘缩放比例。
    window.dispatch_event(WindowEvent::ScaleFactorChanged {
        scale_factor: options.scale,
    });
    // 每次截图新建组件，明暗与字体互不影响。
    let ui = SettingsWindow::new().map_err(|e| e.to_string())?;
    ui.set_dark(options.dark);
    ui.set_ui_font(options.font.as_str().into());
    // 各页显示一个新配置方案的默认值，与第一次打开应用时看到的一样；「客户端」页另加几个示例角色。
    let (profile, clients) = sample();
    crate::bind::show_previews(&ui, &profile);
    crate::bind::show_clients(&ui, &profile, &clients, false);
    // 「切换与热键」页的问题提示来自热键规划，与应用里一样由 Core 算出；截图里没有注册失败与录制。
    let plan = eveo_core::hotkeys::planner::plan(&profile);
    let state = crate::switching::SwitchingState {
        clients: &clients,
        plan: &plan,
        failed: &[],
        recording: None,
    };
    crate::switching::show_switching(&ui, &profile, &state);
    // 「配置方案」页：示例方案之外再放两个，示意列表与「切换」按钮；路径用常见的用户目录。
    let mut config = eveo_core::model::AppConfig {
        active_profile_id: profile.id.clone(),
        profiles: vec![profile],
        ..Default::default()
    };
    config.profiles.push(Profile::make_new("shot-2", "PVP 小队"));
    config.profiles.push(Profile::make_new("shot-3", "挖矿"));
    let path = r"C:\Users\Pilot\AppData\Roaming\EVE-O Preview\config.json";
    crate::profiles::show_profiles(&ui, &config, path);
    // 「通用」与「关于」页：新配置的默认值（界面语言跟随系统）与版本号。
    config.general.language = eveo_core::model::LanguagePreference::System;
    let logs = r"C:\Users\Pilot\AppData\Local\EVE-O Preview\logs";
    crate::general::show_general(&ui, &config.general, logs);
    crate::general::show_about(&ui);
    ui.set_page(options.page);
    let width = (options.size.0 as f32 * options.scale).round() as u32;
    let height = (options.size.1 as f32 * options.scale).round() as u32;
    window.set_size(PhysicalSize::new(width, height));
    ui.show().map_err(|e| e.to_string())?;
    // 推进一次定时器与动画，让 init 与 changed 回调里改的状态（如明暗配色）生效。
    slint::platform::update_timers_and_animations();
    // NewBuffer：每次都整幅重画，不依赖上一帧的内容。
    let mut pixels = vec![PremultipliedRgbaColor::default(); width as usize * height as usize];
    window.request_redraw();
    window.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, width as usize);
    });
    // 隐藏后组件释放，下一次截图从干净的状态开始。
    ui.hide().map_err(|e| e.to_string())?;
    encode(&pixels, width, height)
}

/// 截图用的配置方案与在线客户端：两个在线角色（一个设了自己的高亮颜色）、一个离线且隐藏的角色、一个登录界面。
/// 角色名是虚构的。
fn sample() -> (Profile, Vec<EveClient>) {
    let mut profile = Profile::make_new("shot", "Default");
    // 「Old Alt」只在隐藏名单里：离线、开关关着，示意配置里出现过的角色也会列出。
    // 「Kestrel Nine」设了自己的高亮颜色，示意「默认」按钮可点的样子；其余角色跟随全局颜色。
    profile.hidden_characters.push("Old Alt".to_owned());
    // 与 Windows 版新配置的默认热键相同（共用默认值是 macOS 的组合键）。
    profile.hotkeys.toggle_hide_all = vec!["ctrl+alt+shift+H@global".to_owned()];
    // 「切换与热键」页：一个两人的循环组，一个角色的直达热键（键盘一条、鼠标侧键一条），
    // 再故意放一条缺修饰键的热键，示意问题提示的样子。
    // 循环组的 id 固定，截图每次都一样。
    profile.cycle_groups.push(eveo_core::model::CycleGroup {
        id: "GROUP-1".to_owned(),
        name: "主力舰队".to_owned(),
        forward_hotkeys: vec!["ctrl+F13".to_owned()],
        backward_hotkeys: vec!["ctrl+shift+F13".to_owned()],
        members: vec!["Aria Voss".to_owned(), "Kestrel Nine".to_owned()],
    });
    profile.character_hotkeys.insert(
        "Aria Voss".to_owned(),
        vec!["alt+Num1".to_owned(), "ctrl+Mouse4@game".to_owned()],
    );
    profile
        .character_hotkeys
        .insert("Kestrel Nine".to_owned(), vec!["K".to_owned()]);
    profile
        .highlight_colors
        .insert("Kestrel Nine".to_owned(), "#FF8C00".to_owned());
    // 窗口 ID 与 PID 随意取，只要互不相同。
    let client = |id: u64, identity: ClientIdentity| EveClient {
        id: WindowId(id),
        pid: id as Pid,
        identity,
        window_frame: ScreenRect::new(0.0, 0.0, 1280.0, 720.0),
        is_on_screen: true,
        is_minimized: Some(false),
        is_full_screen: Some(false),
    };
    // 一个登录界面的客户端让「登录界面的客户端」一组也出现在截图里。
    let clients = vec![
        client(1, ClientIdentity::Character("Aria Voss".to_owned())),
        client(2, ClientIdentity::Character("Kestrel Nine".to_owned())),
        client(3, ClientIdentity::Login),
    ];
    (profile, clients)
}

/// 预乘的 RGBA → PNG。
fn encode(pixels: &[PremultipliedRgbaColor], width: u32, height: u32) -> Result<Vec<u8>, String> {
    // PNG 要的是非预乘的 RGBA；完全透明的像素颜色无意义，写成 0。
    let mut rgba = Vec::with_capacity(pixels.len() * 4);
    for p in pixels {
        let unpremultiply = |c: u8| match p.alpha {
            0 => 0,
            a => ((u16::from(c) * 255 + u16::from(a) / 2) / u16::from(a)).min(255) as u8,
        };
        rgba.extend_from_slice(&[
            unpremultiply(p.red),
            unpremultiply(p.green),
            unpremultiply(p.blue),
            p.alpha,
        ]);
    }
    // 8 位 RGBA，不压缩调优，截图工具不在意体积。
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
        writer.write_image_data(&rgba).map_err(|e| e.to_string())?;
    }
    Ok(out)
}
