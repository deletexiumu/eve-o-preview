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
// 标题、占位、跳过标记与战斗提醒画在缩略图窗口的叠加层上；提醒的闪烁由应用的定时器调 `animate` 逐帧推进。

use std::collections::{HashMap, HashSet};

use eveo_app_core::flash;
use eveo_app_core::gesture::Gesture;
use eveo_app_core::lock_effect::{self, LockFrame};
use eveo_core::geometry::{ScreenInfo, ScreenRect, screen_containing};
use eveo_core::model::{AppLanguage, COMBAT_ALERT_DEFAULT_COLOR, CombatAlertStyle, WindowId};
use eveo_core::planning::{ThumbnailPlaceholder, ThumbnailPresentation, ThumbnailStatus};
use eveo_core::support::hex_color;
use eveo_platform_win::overlay::{self, OverlayAlert, OverlayContent, OverlayLock, OverlayTitle};
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
    /// 叠加层的内容；提醒的强度随闪烁逐帧改写。
    overlay: OverlayContent,
}

/// 全部缩略图窗口，按客户端窗口 ID 存放。
pub struct ThumbnailManager {
    entries: HashMap<WindowId, Entry>,
    /// 提醒当前的强度；新出现的提醒从这个值开始，与正在闪的步调一致。
    intensity: f32,
    /// 占位文字的语言。
    language: AppLanguage,
    /// 是否已完成过至少一次呈现应用：启动时已锁定不播开启瞬间动画，仅在后续由未锁定切为锁定时播放。
    has_applied: bool,
    /// 上一次应用呈现时的锁定布局状态。
    was_locked: bool,
    /// 最近一次从未锁定切为锁定的单调时钟时刻（秒）；未锁定时为 `None`。
    locked_since: Option<f64>,
}

impl Default for ThumbnailManager {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            intensity: 1.0,
            language: AppLanguage::En,
            has_applied: false,
            was_locked: false,
            locked_since: None,
        }
    }
}

impl ThumbnailManager {
    /// 按呈现更新窗口。`make_handler` 给新建的窗口生成输入处理函数。
    /// `is_locked` 直接取自当前配置方案的 `behavior.lock_layout`，这样在客户端数量为 0 时
    /// 也能准确追踪锁定切换，避免启动时已锁定或客户端全部关闭重开后误播开启瞬间动画。
    /// 返回 DWM 状态有变化的窗口，调用方报给协调器。
    pub fn apply(
        &mut self,
        (presentations, thumbnails, interacting, screens): (
            &[ThumbnailPresentation],
            &[WindowId],
            &HashSet<WindowId>,
            &[ScreenInfo],
        ),
        is_locked: bool,
        now: f64,
        mut make_handler: impl FnMut(WindowId) -> Box<dyn FnMut(ThumbnailInput)>,
    ) -> Vec<(WindowId, ThumbnailStatus)> {
        let live: HashSet<WindowId> = presentations.iter().map(|p| p.id).collect();
        // 客户端已消失的窗口直接丢弃：Drop 里注销缩略图并销毁窗口。
        self.entries.retain(|id, _| live.contains(id));
        // 检测锁定布局状态变化：从未锁定切到锁定时记下开启时刻，驱动同步的合拢与对角流光动画。
        if lock_effect::should_trigger_engage(self.has_applied, self.was_locked, is_locked) {
            self.locked_since = Some(now);
        } else if !is_locked {
            self.locked_since = None;
        }
        self.has_applied = true;
        self.was_locked = is_locked;
        let lock_frame =
            is_locked.then(|| lock_effect::sample(now, self.locked_since, overlay::animations_enabled()));
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
                        overlay: OverlayContent::default(),
                    })
                }
            };
            if let Some(status) = update(
                entry,
                presentation,
                registered.contains(&id),
                interacting,
                screens,
                (self.intensity, self.language, lock_frame),
            ) {
                changes.push((id, status));
            }
        }
        changes
    }

    /// 换占位文字的语言；下一次呈现时生效（换语言来自配置变化，随后总会重新呈现）。
    pub fn set_language(&mut self, language: AppLanguage) {
        self.language = language;
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

    /// 推进提醒闪烁与锁定布局特效动画：按 `now`（秒）采样曲线并重画变化了的叠加层。
    /// 系统关掉了动画效果时两类特效均静止显示（内容不变则不重画）；既无提醒也未锁定时立即返回，零开销。
    pub fn animate(&mut self, now: f64) {
        let has_alert = self.entries.values().any(|e| e.overlay.alert.is_some());
        let has_lock = self.entries.values().any(|e| e.overlay.lock.is_some());
        if !has_alert && !has_lock {
            return;
        }
        // 每帧都问一次系统设置：用户在运行期间改了「动画效果」开关，下一帧立即生效。
        let animated = overlay::animations_enabled();
        if has_alert {
            self.intensity = if animated {
                flash::intensity(now) as f32
            } else {
                1.0
            };
        }
        let lock_frame = has_lock.then(|| lock_effect::sample(now, self.locked_since, animated));
        // 只改动画字段、其余内容不变；平台层比较内容不同才真正重画。
        // 隐藏的缩略图跳过更新（再次显示时会由 apply 刷新），避免无谓的克隆与重画。
        for entry in self.entries.values_mut() {
            if !entry.window.is_shown() {
                continue;
            }
            let mut changed = false;
            if let Some(alert) = &mut entry.overlay.alert {
                alert.intensity = self.intensity;
                changed = true;
            }
            if let (Some(lock), Some(frame)) = (&mut entry.overlay.lock, lock_frame) {
                let next = overlay_lock(frame, lock.border_inset);
                if *lock != next {
                    *lock = next;
                    changed = true;
                }
            }
            if changed {
                entry.window.set_overlay(entry.overlay.clone());
            }
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
    (intensity, language, lock_frame): (f32, AppLanguage, Option<LockFrame>),
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
    let inset = if color.is_some() {
        (thickness * scale).round() as i32
    } else {
        0
    };
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
    // 叠加层每次呈现都重算内容，但平台层比较内容后才重画：多数重算（例如前台切换）只改边框，不碰叠加层。
    // 锁定特效把当前外圈边框的物理像素宽度 inset 传给叠加层，使锁定特效严格画在外圈高亮边框之内侧，两种效果叠加不覆盖。
    entry.overlay = overlay_content(
        presentation,
        scale as f32,
        intensity,
        language,
        lock_frame
            .filter(|_| presentation.is_locked)
            .map(|f| overlay_lock(f, inset.max(0) as f32)),
    );
    window.set_overlay(entry.overlay.clone());
    (status != entry.status).then(|| {
        entry.status = status;
        status
    })
}

/// 由呈现得出叠加层的内容。占位文字按界面语言。
fn overlay_content(
    presentation: &ThumbnailPresentation,
    scale: f32,
    intensity: f32,
    language: AppLanguage,
    lock: Option<OverlayLock>,
) -> OverlayContent {
    let strings = eveo_l10n::thumbnail(language);
    let title = presentation.shows_title.then(|| OverlayTitle {
        text: presentation.title.clone(),
        size: presentation.title_font_size as f32,
        color: rgb(&presentation.title_color).unwrap_or(0xFF_FF_FF),
    });
    // DWM 画面在最小化时仍是最后一帧，占位铺一层深色半透明底并写明原因；注册失败时底下是边框色。
    let placeholder = match presentation.placeholder {
        ThumbnailPlaceholder::None => None,
        ThumbnailPlaceholder::Unavailable => Some(strings.preview_unavailable().to_owned()),
        ThumbnailPlaceholder::Minimized => Some(strings.minimized().to_owned()),
    };
    let alert = presentation.alert.as_ref().map(|alert| OverlayAlert {
        // 颜色已由配置校验保证合法，这里只作防御：解析失败时用默认的红色。
        color: rgb(&alert.color)
            .or_else(|| rgb(COMBAT_ALERT_DEFAULT_COLOR))
            .unwrap_or(0xFF_3B_30),
        border: matches!(alert.style, CombatAlertStyle::Border | CombatAlertStyle::Both),
        wash: matches!(alert.style, CombatAlertStyle::Wash | CombatAlertStyle::Both),
        intensity,
    });
    OverlayContent {
        title,
        skipped: presentation.is_skipped,
        placeholder,
        lock,
        alert,
        scale,
    }
}

/// 把 `LockFrame` 与外圈边框内缩像素转换成平台层的 `OverlayLock`。
fn overlay_lock(frame: LockFrame, border_inset: f32) -> OverlayLock {
    OverlayLock {
        border_inset,
        clamp_offset: frame.clamp_offset,
        clamp_alpha: frame.clamp_alpha,
        hairline_alpha: frame.hairline_alpha,
        flash_mix: frame.flash_mix,
        glint_phase: frame.glint_phase,
        sheen_progress: frame.sheen_progress,
    }
}

/// `#RRGGBB` 换成 `0xRRGGBB`；格式不对时返回 `None`。
fn rgb(text: &str) -> Option<u32> {
    let (r, g, b) = hex_color::components(text)?;
    let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
    Some(byte(r) << 16 | byte(g) << 8 | byte(b))
}

/// `#RRGGBB` 换成 Win32 的 `0x00BBGGRR`；格式不对时返回 `None`。
fn bgr(text: &str) -> Option<u32> {
    // 0xRRGGBB 的红与蓝对调。
    rgb(text).map(|v| (v & 0x00_FF_00) | (v >> 16) | ((v & 0xFF) << 16))
}
