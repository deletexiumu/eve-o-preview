// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图窗口管理器，对应 macOS 的 ThumbnailWindowManager 与 ThumbnailPanelController（架构文档 4.2 节）。
// 按协调器的呈现建、改、销毁缩略图窗口：
// - 位置与置顶：拖动中的窗口（interacting）不改 frame，由手势直接移动；
// - 可见性：不可见的窗口整个隐藏（不收鼠标），并注销 DWM 缩略图；
// - 边框：高亮色或中性边框色作为窗口底色，DWM 目标矩形向内缩进边框粗细（按所在显示器的 DPI 放大）；
// - 不透明度：DWM 缩略图的 opacity。
// DWM 注册的结果（成功或失败）作为缩略图状态报回协调器，失败的下一轮规划时重试。
// 每个窗口还有一个手势状态机（app-core 的 gesture），窗口过程的鼠标输入经应用层交给它。

use std::collections::{HashMap, HashSet};

use eveo_app_core::gesture::Gesture;
use eveo_core::geometry::{ScreenInfo, ScreenRect, screen_containing};
use eveo_core::model::WindowId;
use eveo_core::planning::{ThumbnailPresentation, ThumbnailStatus};
use eveo_core::support::hex_color;
use eveo_platform_win::thumbnail::{ThumbnailInput, ThumbnailWindow};

/// 没有高亮也没有中性边框时的底色：深灰，与 DWM 画面之间没有缝隙时看不到。
const DEFAULT_BACKGROUND: u32 = 0x0020_2020;

/// 一个客户端的缩略图窗口与它的手势状态。
struct Entry {
    /// 缩略图窗口。
    window: ThumbnailWindow,
    /// 手势状态机。
    gesture: Gesture,
    /// 最近报给协调器的 DWM 状态。
    status: ThumbnailStatus,
}

/// 全部缩略图窗口，按客户端窗口 ID 存放。
#[derive(Default)]
pub struct ThumbnailManager {
    entries: HashMap<WindowId, Entry>,
}

impl ThumbnailManager {
    /// 按呈现更新窗口。`make_handler` 给新建的窗口生成输入处理函数。
    /// 返回 DWM 状态有变化的窗口，调用方报给协调器。
    pub fn apply(
        &mut self,
        presentations: &[ThumbnailPresentation],
        thumbnails: &[WindowId],
        interacting: &HashSet<WindowId>,
        screens: &[ScreenInfo],
        mut make_handler: impl FnMut(WindowId) -> Box<dyn FnMut(ThumbnailInput)>,
    ) -> Vec<(WindowId, ThumbnailStatus)> {
        let live: HashSet<WindowId> = presentations.iter().map(|p| p.id).collect();
        // 客户端已消失的窗口直接丢弃：Drop 里注销缩略图并销毁窗口。
        self.entries.retain(|id, _| live.contains(id));
        // 要保持 DWM 注册的窗口：只有可见的缩略图注册，隐藏时注销，系统不再为它合成画面。
        let registered: HashSet<WindowId> = thumbnails.iter().copied().collect();
        let mut changes = Vec::new();
        for presentation in presentations {
            let id = presentation.id;
            let entry = match self.entries.entry(id) {
                std::collections::hash_map::Entry::Occupied(entry) => entry.into_mut(),
                std::collections::hash_map::Entry::Vacant(slot) => {
                    // 建窗口失败（极少见）时跳过这个客户端，下一次呈现再试。
                    let Ok(window) =
                        ThumbnailWindow::create(presentation.frame, presentation.is_always_on_top)
                    else {
                        continue;
                    };
                    window.set_input_handler(make_handler(id));
                    slot.insert(Entry {
                        window,
                        gesture: Gesture::new(),
                        status: ThumbnailStatus::Pending,
                    })
                }
            };
            if let Some(status) = update(
                entry,
                presentation,
                registered.contains(&id),
                interacting,
                screens,
            ) {
                changes.push((id, status));
            }
        }
        changes
    }

    /// 某个窗口的手势状态机。
    pub fn gesture(&mut self, id: WindowId) -> Option<&mut Gesture> {
        self.entries.get_mut(&id).map(|e| &mut e.gesture)
    }

    /// 拖动中直接移动窗口，不经过协调器。
    pub fn set_live_frame(&mut self, id: WindowId, frame: ScreenRect, topmost: bool) {
        if let Some(entry) = self.entries.get_mut(&id) {
            let _ = entry.window.set_frame(frame, topmost);
        }
    }

    /// 设光标形状。
    pub fn set_cursor(&self, id: WindowId, shape: eveo_platform_win::thumbnail::CursorShape) {
        if let Some(entry) = self.entries.get(&id) {
            entry.window.set_cursor(shape);
        }
    }

    /// 销毁全部窗口（退出时）。
    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

/// 按一个呈现更新一个窗口，返回变化了的 DWM 状态。
fn update(
    entry: &mut Entry,
    presentation: &ThumbnailPresentation,
    should_register: bool,
    interacting: &HashSet<WindowId>,
    screens: &[ScreenInfo],
) -> Option<ThumbnailStatus> {
    let id = presentation.id;
    let window = &mut entry.window;
    // 缩略图被隐藏时取消进行中的手势，松开鼠标时不会再提交（协调器已清掉它的交互状态）。
    if !presentation.is_visible {
        entry.gesture.cancel();
    }
    // 拖动中的窗口由手势直接移动；这里再按规划移动会与鼠标打架。
    if !interacting.contains(&id) && window.frame() != presentation.frame {
        let _ = window.set_frame(presentation.frame, presentation.is_always_on_top);
    }
    // 隐藏整个窗口而不只是隐藏 DWM 画面：否则透明的窗口仍会挡住鼠标点击。
    window.set_shown(presentation.is_visible);

    // 边框：高亮优先，其次中性边框；粗细按所在显示器的缩放放大。
    let scale = screen_containing(screens, presentation.frame.center()).map_or(1.0, |s| s.scale);
    let (color, thickness) = match (&presentation.highlight_color, &presentation.border_color) {
        (Some(color), _) => (bgr(color), presentation.highlight_thickness),
        (None, Some(color)) => (bgr(color), presentation.border_thickness),
        (None, None) => (None, 0.0),
    };
    window.set_background(color.unwrap_or(DEFAULT_BACKGROUND));
    let inset = (thickness * scale).round() as i32;
    // 不透明度只作用于 DWM 画面；边框（窗口底色）保持不透明，高亮在半透明时也看得清。
    let opacity = (presentation.opacity.clamp(0.0, 1.0) * 255.0).round() as u8;

    // 已注册的不重复注册（重新注册会闪一下）；注册失败报 Failed，协调器据此显示占位并在下一轮重试。
    let status = if should_register {
        if window.is_registered() || window.register(id).is_ok() {
            ThumbnailStatus::Shown
        } else {
            ThumbnailStatus::Failed
        }
    } else {
        window.unregister();
        ThumbnailStatus::Pending
    };
    let _ = window.set_appearance(inset, presentation.is_visible, opacity);
    (status != entry.status).then(|| {
        entry.status = status;
        status
    })
}

/// `#RRGGBB` 换成 Win32 的 `0x00BBGGRR`；格式不对时返回 `None`。
fn bgr(text: &str) -> Option<u32> {
    let (r, g, b) = hex_color::components(text)?;
    let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
    Some(byte(b) << 16 | byte(g) << 8 | byte(r))
}
