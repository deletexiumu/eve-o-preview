// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译浮窗的管理，对应 macOS 的 InfoOverlayManager 与 OverlayInteraction（docs/macos/design-intel-translate.md
// 8.3～8.7 节）。每个浮窗由三部分组成：
// - eveo-ui 的离屏宿主（OverlayHost）：Slint 组件与内容视图，画进内存；
// - 平台层的分层窗口（PanelWindow）：显示宿主画好的画面，收鼠标输入；
// - 手势状态机（与缩略图共用的 Gesture）：右键或 Alt+左键拖动移动、从边缘拖动缩放、右键单击弹菜单。
//
// 输入的分工：
// - 滚轮与悬停交给 Slint（列表滚动、记下光标下的行）。
// - 不带修饰键的左键：手势给出 Click 时交给 Slint（点新消息条）；按在边缘带上时由手势缩放。
// - 右键：手势判断拖动还是弹菜单；菜单在应用层弹（要用到配置与剪贴板），这里只报事件和光标下的行。
// 拖动中的 frame 直接设给窗口，不经过规划器；松开时报 DragEnded，由应用层写进配置。
//
// 画面的提交：16 毫秒一次的定时器检查各宿主是否要重画（内容、悬停、滚动、动画变了），要重画才提交；
// 处理完一条鼠标输入后也立即检查一次，悬停与滚动没有延迟。

//! 预警与翻译浮窗的管理。

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::{Rc, Weak};
use std::time::Duration;

use eveo_app_core::event::DragContext;
use eveo_app_core::gesture::{Gesture, GestureOutput, Modifiers};
use eveo_core::geometry::{ScreenInfo, ScreenPoint, ScreenRect, size_scale_at};
use eveo_core::model::AppLanguage;
use eveo_core::overlay::planner::OverlayPresentation;
use eveo_core::overlay::{OverlayContent, OverlayKind, OverlayLine};
use eveo_platform_win::panel::{PanelInput, PanelWindow};
use eveo_platform_win::thumbnail::{CursorShape, MouseButton};
use eveo_ui::overlay::host::OverlayHost;

use crate::app::{cursor_for, gesture_button};

/// 检查重画的间隔：约 60 帧每秒。没有变化时只是一次比较，开销可以忽略。
const FRAME_INTERVAL: Duration = Duration::from_millis(16);

/// 浮窗报给应用层的事件。
#[derive(Debug, Clone, PartialEq)]
pub enum OverlayEvent {
    /// 开始拖动（移动或缩放）。
    DragBegan(OverlayKind),
    /// 拖动结束，提交最终 frame（全局物理像素）。
    DragEnded(OverlayKind, ScreenRect),
    /// 拖动被取消（失去鼠标捕获），frame 回到拖动前。
    DragCancelled(OverlayKind),
    /// 右键单击：在 point 处弹菜单；row 是光标下那一行的下标。
    Menu {
        /// 哪个浮窗。
        kind: OverlayKind,
        /// 光标位置。
        point: ScreenPoint,
        /// 光标下的行；不在任何一行上时为 None。
        row: Option<usize>,
    },
}

/// 按下时取拖动上下文的函数：参数是浮窗的种类与当前 frame。返回 None 表示不能拖动。
pub type DragContextProvider = Rc<dyn Fn(OverlayKind, ScreenRect) -> Option<DragContext>>;

/// 一个浮窗。
struct Panel {
    /// 种类。
    kind: OverlayKind,
    /// 离屏宿主。
    host: OverlayHost,
    /// 分层窗口。
    window: PanelWindow,
    /// 手势状态机。
    gesture: Gesture,
    /// 当前 frame（全局物理像素）。
    frame: ScreenRect,
    /// 拖动开始前的 frame，取消时回到这里。
    frame_before_drag: ScreenRect,
    /// 所在屏幕的缩放比例。
    scale: f64,
    /// 左键按下已交给 Slint，松开也要交给它。
    left_in_slint: bool,
    /// 鼠标进入时取的拖动上下文，只用于悬停时判断边缘带（不必每次移动都重算吸附目标）。
    hover_context: Option<DragContext>,
}

impl Panel {
    /// 全局坐标换成相对窗口左上角的物理像素。
    /// 平台层给的是全局坐标（GetCursorPos），Slint 要的是窗口内的坐标；缩放比例由宿主再换成逻辑坐标。
    fn local(&self, point: ScreenPoint) -> (f64, f64) {
        (point.x - self.frame.x, point.y - self.frame.y)
    }

    /// 放到新的 frame：尺寸变了要按新尺寸重画（下一次提交时一起换位置）；只移动时直接挪窗口。
    /// 尺寸按四舍五入后的整数像素比较：拖动时的小数位移不会让宿主每次都整幅重画。
    fn set_frame(&mut self, frame: ScreenRect, scale: f64) {
        let size = |r: ScreenRect| (r.width.round() as u32, r.height.round() as u32);
        let resized = size(frame) != size(self.frame) || scale != self.scale;
        self.frame = frame;
        self.scale = scale;
        if resized {
            let (width, height) = size(frame);
            self.host.resize(width, height, scale as f32);
        } else {
            self.window
                .move_to(frame.x.round() as i32, frame.y.round() as i32);
        }
    }

    /// 要重画时画一帧并提交。
    /// 位置、尺寸与画面一起提交；画面没变时什么也不做（只移动的情形已在 set_frame 里挪过窗口）。
    /// 提交失败（窗口已销毁、GDI 资源耗尽）时丢掉这一帧，下一次变化时再试。
    fn flush(&mut self) {
        let frame = (
            self.frame.x.round() as i32,
            self.frame.y.round() as i32,
            self.frame.width.round() as i32,
            self.frame.height.round() as i32,
        );
        if let Some(bgra) = self.host.render() {
            let _ = self.window.present(frame, bgra);
        }
    }

    /// 处理一条鼠标输入，返回要报给应用层的事件。
    ///
    /// 事件先收在返回值里，由调用方在放开浮窗的借用之后再放进共用的队列，应用层处理事件时可以再借用浮窗。
    fn handle(&mut self, input: PanelInput, provider: &DragContextProvider) -> Vec<OverlayEvent> {
        let mut events = Vec::new();
        match input {
            PanelInput::Enter => {
                self.hover_context = provider(self.kind, self.frame);
            }
            PanelInput::Move { point, modifiers } => {
                if self.gesture_active() {
                    let outputs = self.gesture.moved(point, modifiers.shift);
                    self.apply_outputs(outputs, point, &mut events);
                } else {
                    let edges = self.gesture.hover_edges(point, self.hover_context.as_ref());
                    self.window.set_cursor(cursor_for(edges));
                }
                // 悬停与按住左键的移动都交给 Slint（悬停色、光标下的行）。
                let (x, y) = self.local(point);
                self.host.pointer_moved(x, y);
            }
            PanelInput::Press {
                button,
                modifiers,
                point,
            } => {
                let context = provider(self.kind, self.frame);
                let modifiers = Modifiers {
                    ctrl: modifiers.ctrl,
                    alt: modifiers.alt,
                    shift: modifiers.shift,
                };
                let outputs = self
                    .gesture
                    .press(gesture_button(button), modifiers, point, context);
                self.apply_outputs(outputs, point, &mut events);
            }
            PanelInput::Release { button, point } => {
                let outputs = self.gesture.release(gesture_button(button));
                self.apply_outputs(outputs, point, &mut events);
                if button == MouseButton::Left && self.left_in_slint {
                    self.left_in_slint = false;
                    let (x, y) = self.local(point);
                    self.host.left_button(x, y, false);
                }
            }
            // 滚轮不经过手势：拖动中滚动也照常翻列表，与 macOS 一致。
            PanelInput::Wheel { delta, point } => {
                let (x, y) = self.local(point);
                self.host.wheel(x, y, delta);
            }
            PanelInput::Leave => {
                self.host.pointer_exited();
                self.window.set_cursor(CursorShape::Arrow);
            }
            // 失去捕获（弹出了菜单、Alt+Tab）：拖动作废，回到拖动前的位置；交给 Slint 的左键按下也作废。
            PanelInput::CaptureLost => {
                if self.gesture.cancel() {
                    let (before, scale) = (self.frame_before_drag, self.scale);
                    self.set_frame(before, scale);
                    events.push(OverlayEvent::DragCancelled(self.kind));
                }
                self.left_in_slint = false;
            }
        }
        events
    }

    /// 手势是否在进行中（按下之后、松开之前）。按下后即使还没开始拖动，移动也要交给手势判断阈值。
    fn gesture_active(&self) -> bool {
        self.gesture != Gesture::new()
    }

    /// 执行手势的输出。
    fn apply_outputs(
        &mut self,
        outputs: Vec<GestureOutput>,
        point: ScreenPoint,
        events: &mut Vec<OverlayEvent>,
    ) {
        for output in outputs {
            match output {
                // 不带修饰键的左键：交给 Slint 当作按下（松开时再交一次，Slint 才算一次点击）。
                GestureOutput::Click => {
                    let (x, y) = self.local(point);
                    self.host.left_button(x, y, true);
                    self.left_in_slint = true;
                }
                // Ctrl+左键在缩略图上是最小化客户端，浮窗没有对应的动作。
                GestureOutput::Minimize => {}
                GestureOutput::Menu => events.push(OverlayEvent::Menu {
                    kind: self.kind,
                    point,
                    row: self.host.hovered_row(),
                }),
                GestureOutput::DragBegan(base) => {
                    self.frame_before_drag = self.frame;
                    let scale = self.scale;
                    self.set_frame(base, scale);
                    events.push(OverlayEvent::DragBegan(self.kind));
                }
                GestureOutput::LiveFrame(frame) => {
                    let scale = self.scale;
                    self.set_frame(frame, scale);
                }
                GestureOutput::DragEnded(frame) => {
                    let scale = self.scale;
                    self.set_frame(frame, scale);
                    events.push(OverlayEvent::DragEnded(self.kind, frame));
                }
            }
        }
    }
}

/// 两个浮窗与它们共用的事件队列、拖动上下文与定时器。
pub struct InfoOverlays {
    /// 已建的浮窗。
    panels: Rc<RefCell<Vec<Rc<RefCell<Panel>>>>>,
    /// 待应用层处理的事件。
    events: Rc<RefCell<VecDeque<OverlayEvent>>>,
    /// 取拖动上下文的函数。
    provider: DragContextProvider,
    /// 界面语言。
    language: AppLanguage,
    /// 检查重画的定时器；有浮窗时运行。
    timer: slint::Timer,
}

impl InfoOverlays {
    /// 建管理器；provider 在按下鼠标时给出拖动上下文（吸附目标、尺寸上下限、是否锁定）。
    pub fn new(language: AppLanguage, provider: DragContextProvider) -> Self {
        Self {
            panels: Rc::default(),
            events: Rc::default(),
            provider,
            language,
            timer: slint::Timer::default(),
        }
    }

    /// 按规划结果建、改、关浮窗。正在拖动的浮窗不改 frame，免得和鼠标抢位置。
    ///
    /// 缩放比例按 frame 中心所在的屏幕取：浮窗跨在两块屏幕之间时按大部分所在的那块画，字不会忽大忽小。
    pub fn apply(&mut self, presentations: &[OverlayPresentation], screens: &[ScreenInfo]) {
        // 不在结果里的浮窗（功能关了）关掉。
        self.panels
            .borrow_mut()
            .retain(|p| presentations.iter().any(|x| x.kind == p.borrow().kind));
        for presentation in presentations {
            let Some(panel) = self
                .panel(presentation.kind)
                .or_else(|| self.create(presentation.kind))
            else {
                continue;
            };
            let mut panel = panel.borrow_mut();
            if !panel.gesture.is_dragging() {
                let scale = size_scale_at(screens, presentation.frame.center());
                panel.set_frame(presentation.frame, scale);
            }
            panel
                .host
                .view()
                .borrow()
                .set_appearance(presentation.opacity, presentation.font_size);
            // 盖在全屏客户端上也是置顶；每次都设，后显示的置顶窗口在前，浮窗不会被缩略图盖住以外的置顶窗口挡住。
            panel
                .window
                .set_topmost(presentation.is_always_on_top || presentation.is_over_full_screen);
            panel.window.set_shown(presentation.is_visible);
            panel.flush();
        }
        self.update_timer();
    }

    /// 显示新内容。
    pub fn set_content(&self, kind: OverlayKind, content: &OverlayContent) {
        if let Some(panel) = self.panel(kind) {
            let mut panel = panel.borrow_mut();
            panel.host.view().borrow_mut().set_content(content);
            panel.flush();
        }
    }

    /// 换界面语言。
    pub fn set_language(&mut self, language: AppLanguage) {
        self.language = language;
        for panel in self.panels.borrow().iter() {
            panel.borrow().host.view().borrow_mut().set_language(language);
        }
    }

    /// 取走待处理的事件。
    pub fn drain_events(&self) -> Vec<OverlayEvent> {
        self.events.borrow_mut().drain(..).collect()
    }

    /// 浮窗列表第 row 行的消息（菜单的「复制」「在浏览器中打开」用）。
    pub fn line(&self, kind: OverlayKind, row: usize) -> Option<OverlayLine> {
        let panel = self.panel(kind)?;
        let panel = panel.borrow();
        let view = panel.host.view().borrow();
        view.line(row).cloned()
    }

    /// 菜单的「滚动到最新」。
    pub fn scroll_to_latest(&self, kind: OverlayKind) {
        if let Some(panel) = self.panel(kind) {
            panel.borrow().host.view().borrow_mut().scroll_to_latest();
        }
    }

    /// 可见浮窗的 frame（吸附目标），不含 excluding。
    pub fn visible_frames(&self, excluding: Option<OverlayKind>) -> Vec<ScreenRect> {
        self.panels
            .borrow()
            .iter()
            .map(|p| p.borrow())
            .filter(|p| Some(p.kind) != excluding && p.window.is_shown())
            .map(|p| p.frame)
            .collect()
    }

    /// 正在拖动的浮窗。
    pub fn interacting(&self) -> Vec<OverlayKind> {
        self.panels
            .borrow()
            .iter()
            .map(|p| p.borrow())
            .filter(|p| p.gesture.is_dragging())
            .map(|p| p.kind)
            .collect()
    }

    /// 找浮窗。
    fn panel(&self, kind: OverlayKind) -> Option<Rc<RefCell<Panel>>> {
        self.panels
            .borrow()
            .iter()
            .find(|p| p.borrow().kind == kind)
            .cloned()
    }

    /// 建一个浮窗并接上输入处理。建不了（系统资源耗尽、Slint 出错）时返回 None，功能照常运行，只是看不到浮窗。
    ///
    /// 输入处理函数只持有浮窗的弱引用：浮窗被关掉（功能关闭）后，窗口过程里迟到的消息直接忽略。
    fn create(&self, kind: OverlayKind) -> Option<Rc<RefCell<Panel>>> {
        let host = OverlayHost::new(self.language).ok()?;
        let window = PanelWindow::create().ok()?;
        let panel = Rc::new(RefCell::new(Panel {
            kind,
            host,
            window,
            gesture: Gesture::new(),
            frame: ScreenRect::new(0.0, 0.0, 0.0, 0.0),
            frame_before_drag: ScreenRect::new(0.0, 0.0, 0.0, 0.0),
            scale: 1.0,
            left_in_slint: false,
            hover_context: None,
        }));
        let weak: Weak<RefCell<Panel>> = Rc::downgrade(&panel);
        let events = self.events.clone();
        let provider = self.provider.clone();
        panel.borrow().window.set_input_handler(move |input| {
            let Some(panel) = weak.upgrade() else {
                return;
            };
            // 浮窗正被别处借用（不应发生：输入只在消息循环里派发）时丢掉这条输入，不让程序崩溃。
            let Ok(mut panel) = panel.try_borrow_mut() else {
                return;
            };
            let produced = panel.handle(input, &provider);
            panel.flush();
            events.borrow_mut().extend(produced);
        });
        self.panels.borrow_mut().push(panel.clone());
        Some(panel)
    }

    /// 有浮窗时运行检查重画的定时器，没有时停掉。
    /// 定时器在 Slint 的事件循环里运行，和窗口过程在同一个线程上，不会与输入处理同时借用浮窗。
    fn update_timer(&self) {
        if self.panels.borrow().is_empty() {
            self.timer.stop();
            return;
        }
        if self.timer.running() {
            return;
        }
        let panels = Rc::downgrade(&self.panels);
        self.timer
            .start(slint::TimerMode::Repeated, FRAME_INTERVAL, move || {
                let Some(panels) = panels.upgrade() else {
                    return;
                };
                for panel in panels.borrow().iter() {
                    if let Ok(mut panel) = panel.try_borrow_mut() {
                        panel.flush();
                    }
                }
            });
    }
}
