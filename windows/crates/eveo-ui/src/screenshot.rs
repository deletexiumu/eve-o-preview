// SPDX-License-Identifier: GPL-3.0-or-later
//
// 无窗口截图（架构文档 8.4 节的界面截图回归）：用 Slint 的软件渲染器把界面画进内存，再编码成 PNG。
// 不需要显示器，Linux 容器与 CI 都能跑；云端改界面时直接看图。
// Slint 的平台存在线程局部的上下文里，每个线程只能设一次，所以这里的窗口也放在线程局部变量里，同一线程的各次截图共用。
// 单元测试各跑在自己的线程上，各自设一次平台，互不影响。

//! 用软件渲染器把界面画成 PNG。

use std::cell::RefCell;
use std::rc::Rc;

use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, PhysicalSize, PlatformError};

use eveo_core::geometry::ScreenRect;
use eveo_core::model::{ChannelRef, ClientIdentity, EveClient, Pid, Profile, WindowId};

use crate::{OverlayWindow, SettingsWindow};

mod overlay_sample;

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
    /// 界面语言。
    pub language: eveo_core::model::AppLanguage,
}

/// 只给软件渲染器用的平台。
struct Headless {
    window: Rc<MinimalSoftwareWindow>,
}

impl Platform for Headless {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        // 浮窗宿主事先放好了自己的软件渲染窗口时用它（与应用里的平台相同的约定），否则用截图窗口。
        if let Some(adapter) = crate::overlay::host::take_pending_adapter() {
            return Ok(adapter);
        }
        Ok(self.window.clone())
    }
}

thread_local! {
    /// 本线程的软件渲染窗口；第一次截图时创建并设为 Slint 的平台。
    static WINDOW: RefCell<Option<Rc<MinimalSoftwareWindow>>> = const { RefCell::new(None) };
}

/// 取（或创建）软件渲染窗口。
pub(crate) fn window() -> Result<Rc<MinimalSoftwareWindow>, String> {
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

/// 设好软件渲染平台（每个线程一次），单元测试建窗口前调用。
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
    crate::set_language(&ui, options.language);
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
    // 「提醒」页：默认值，日志目录自动查找。
    let automatic = r"C:\Users\Pilot\Documents\EVE\logs";
    crate::alerts::show_alerts(&ui, &config.profiles[0], &config.general, automatic);
    // 「预警」与「翻译」页：各放几个频道，示意列表；翻译页选了本地频道，内置频道的按钮随之置灰。
    let mut intel = config.profiles[0].intel.clone();
    intel.channels = vec![
        ChannelRef::new("Intel.North", None),
        ChannelRef::new("Delve.Intel", None),
    ];
    intel.reference_system = Some("1DQ1-A".to_owned());
    crate::chat::show_intel(&ui, &intel);
    // 状态行：监视中，路径较长（示意长路径在标题下整行显示）。
    let watching = eveo_core::chat_log::ChatLogStatus::Watching {
        directory: r"C:\Users\Pilot\Documents\EVE\logs\Chatlogs".to_owned(),
        followed_files: 3,
    };
    crate::chat::show_intel_status(&ui, &watching);
    // 运行时状态：两个在线角色（一个有游戏日志的位置、一个手动输入的星系查不到）、人名核对就绪、星图数据已读入。
    let intel_text = eveo_l10n::intel(crate::language());
    crate::intel::show_intel_view(
        &ui,
        &crate::intel::IntelView {
            locations: vec![
                crate::intel::LocationView {
                    name: "Pilot One".to_owned(),
                    text: intel_text.location_value(
                        "1DQ1-A",
                        intel_text.source_game_log(),
                        &intel_text.age_minutes(3),
                    ),
                    has_location: true,
                    not_found: false,
                    cleared: 0,
                },
                crate::intel::LocationView {
                    name: "Pilot Two".to_owned(),
                    text: intel_text.location_unknown().to_owned(),
                    has_location: false,
                    not_found: true,
                    cleared: 0,
                },
            ],
            reference_not_found: false,
            pilot_status: intel_text.pilot_lookup_idle(42),
            pilot_cache: intel_text.pilot_cache_count(42),
            static_data: intel_text.static_data_build(3_720_952),
        },
    );
    let mut translation = config.profiles[0].translation.clone();
    translation.channels = vec![
        ChannelRef::built_ins()[0].clone(),
        ChannelRef::new("Rookie Help", None),
    ];
    crate::chat::show_translation(&ui, &translation, &config.general.translation_endpoint);
    // 运行时状态：未启用、Key 已保存、测过一次、缓存里有一些句子（示意各行的样子）。
    let text = eveo_l10n::translation(crate::language());
    crate::translation::show_translation_view(
        &ui,
        &crate::translation::TranslationView {
            status_text: text.status_off().to_owned(),
            key_stored: true,
            test_result: text.test_succeeded("o7，星门安全，一路顺风"),
            test_succeeded: true,
            cache_count: 128,
            ..Default::default()
        },
    );
    // 「环境检查」页：一个以管理员运行的客户端（示意警示色与说明），日志目录在、Gamelogs 不在。
    crate::environment::show_privileges(&ui, false, &["Pilot One".to_owned()]);
    let folders = crate::environment::LogFolders {
        root: automatic.to_owned(),
        root_found: true,
        chatlogs_found: true,
        gamelogs_found: false,
    };
    crate::environment::show_logs(&ui, &folders, "22:51:03");
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

/// 把预警浮窗画成 PNG：示例内容画在深灰的底色上（浮窗背景半透明，底色代替游戏画面）。
/// 只用 options 的尺寸、缩放、字体与语言。
///
/// 内容经 OverlayView 显示，与应用里走同一条路：富文本的拼法、说明与新消息条的规则都在截图里看得到。
/// 背景不透明度与字号取默认值（0.85、12），与新配置第一次打开时一样。
pub fn overlay_png(options: &ShotOptions) -> Result<Vec<u8>, String> {
    let window = window()?;
    window.dispatch_event(WindowEvent::ScaleFactorChanged {
        scale_factor: options.scale,
    });
    let ui = OverlayWindow::new().map_err(|e| e.to_string())?;
    ui.set_ui_font(options.font.as_str().into());
    let width = (options.size.0 as f32 * options.scale).round() as u32;
    let height = (options.size.1 as f32 * options.scale).round() as u32;
    window.set_size(PhysicalSize::new(width, height));
    ui.show().map_err(|e| e.to_string())?;
    let view = crate::overlay::OverlayView::attach(ui.clone_strong(), options.language);
    view.borrow().set_appearance(0.85, 12.0);
    view.borrow_mut().set_content(&overlay_sample::content());
    // 推进一次定时器，让 changed 回调（贴住底部时滚到底部）生效。
    slint::platform::update_timers_and_animations();
    // 底色：接近游戏里太空背景的深灰蓝，预乘后不透明。
    let backdrop = PremultipliedRgbaColor {
        red: 0x2a,
        green: 0x30,
        blue: 0x3a,
        alpha: 0xff,
    };
    let mut pixels = vec![backdrop; width as usize * height as usize];
    window.request_redraw();
    window.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, width as usize);
    });
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
