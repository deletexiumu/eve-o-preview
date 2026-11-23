// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图的鼠标手势，对应 macOS 的 Thumbnails/ThumbnailInteraction.swift（架构文档 4.5 节、7.3 节）。
// macOS 的 Option 键在 Windows 上换成 Alt；其余规则相同：
//
// | 操作 | 手势 |
// | --- | --- |
// | 切换 | 左键按下（不带 Ctrl、Alt），按下即切换；按在边缘带上时改为松开时切换 |
// | 最小化 | Ctrl+左键按下 |
// | 菜单 | 右键按下并松开，期间移动不超过 4 点 |
// | 移动 | 右键拖动，或 Alt+左键拖动，移动超过 4 点后开始 |
// | 缩放 | 同移动，起点落在边缘 12 点内时改为缩放那条边或那个角；也可以不带修饰键直接用左键从边缘 6 点内拖动 |
// | 绕过吸附 | 拖动时按住 Shift；缩放时 Shift 同时保持宽高比 |
//
// 拖动中每次鼠标事件都由「起点 frame + 鼠标原始位移」算出候选 frame 再吸附，直接设给缩略图窗口，
// 不经过规划器与配置保存；松开时才通知协调器提交一次。状态机是纯逻辑：输入是按键、坐标与修饰键，
// 输出是要做的事，窗口过程负责把 Win32 消息换成输入、把输出换成协调器事件或窗口移动。

//! 缩略图的手势状态机。

use eveo_core::geometry::{ScreenPoint, ScreenRect};
use eveo_core::layout::edge_grip::{self, PlainPress};
use eveo_core::layout::snap::{self, DEFAULT_THRESHOLD, ResizeEdges, SnapTargets};

use crate::event::DragContext;

/// 开始拖动的最小移动距离。
pub const DRAG_THRESHOLD: f64 = 4.0;
/// 右键或 Alt+左键拖动时，起点落在边缘多少以内改为缩放。
pub const RESIZE_MARGIN: f64 = 12.0;

/// 鼠标按键。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    /// 左键。
    Left,
    /// 右键。
    Right,
}

/// 按下时的修饰键。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Modifiers {
    /// Ctrl。
    pub ctrl: bool,
    /// Alt。
    pub alt: bool,
    /// Shift。
    pub shift: bool,
}

/// 手势要求做的事。
#[derive(Debug, Clone, PartialEq)]
pub enum GestureOutput {
    /// 切换到这个客户端（`Event::ThumbnailClicked`）。
    Click,
    /// 最小化这个客户端（`Event::ThumbnailMinimizeRequested`）。
    Minimize,
    /// 在光标处弹出右键菜单。
    Menu,
    /// 拖动开始（`Event::DragBegan`），并把窗口放到这个基准 frame（悬停放大时缩回去）。
    DragBegan(ScreenRect),
    /// 拖动中：把窗口直接放到这个 frame。
    LiveFrame(ScreenRect),
    /// 拖动结束，提交最终 frame（`Event::DragEnded`）。
    DragEnded(ScreenRect),
}

/// 进行中的拖动。
#[derive(Debug, Clone, PartialEq)]
struct Drag {
    /// 拖动开始时的上下文。
    context: DragContext,
    /// 被拖动的边；为空表示移动。
    edges: ResizeEdges,
    /// 当前的 frame。
    current: ScreenRect,
}

/// 手势阶段。
#[derive(Debug, Clone, PartialEq, Default)]
enum Phase {
    /// 没有按键按下，或按下后不产生手势（如左键切换后）。
    #[default]
    Idle,
    /// 已按下，还没移动超过阈值。上下文在按下时取好，缺失表示不能拖动。
    Pending {
        button: Button,
        start: ScreenPoint,
        context: Option<DragContext>,
    },
    /// 不带修饰键的左键按在边缘带上，还没移动超过阈值：拖动则缩放这些边，松开则切换。
    PendingEdge {
        start: ScreenPoint,
        edges: ResizeEdges,
        context: DragContext,
    },
    /// 正在拖动。
    Dragging {
        button: Button,
        start: ScreenPoint,
        drag: Drag,
    },
    /// 布局已锁定或不能拖动：吞掉本次拖动，松开时什么也不做。
    Suppressed,
}

/// 一个缩略图的手势状态机。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Gesture {
    phase: Phase,
}

impl Gesture {
    /// 建一个空闲的状态机。
    pub fn new() -> Self {
        Self::default()
    }

    /// 是否正在拖动（超过阈值之后）。
    pub fn is_dragging(&self) -> bool {
        matches!(self.phase, Phase::Dragging { .. })
    }

    /// 按下。`context` 是协调器的 `drag_context`（客户端已消失时为 `None`）。
    ///
    /// 左键无修饰键立即切换；按在边缘带上时先等待。Ctrl+左键立即最小化。Alt+左键与右键进入待定。
    pub fn press(
        &mut self,
        button: Button,
        modifiers: Modifiers,
        point: ScreenPoint,
        context: Option<DragContext>,
    ) -> Vec<GestureOutput> {
        match button {
            Button::Left if modifiers.ctrl => {
                self.phase = Phase::Idle;
                vec![GestureOutput::Minimize]
            }
            Button::Left if modifiers.alt => {
                self.phase = Phase::Pending {
                    button,
                    start: point,
                    context,
                };
                Vec::new()
            }
            Button::Left => {
                // 边缘带只看实际显示的 frame（悬停放大时是放大后的），与光标显示一致。
                if let Some(context) = context
                    && let PlainPress::Resize(edges) = edge_grip::plain_press(
                        point,
                        context.edge_frame,
                        context.allows_resize,
                        context.is_locked,
                    )
                {
                    self.phase = Phase::PendingEdge {
                        start: point,
                        edges,
                        context,
                    };
                    return Vec::new();
                }
                self.phase = Phase::Idle;
                vec![GestureOutput::Click]
            }
            Button::Right => {
                self.phase = Phase::Pending {
                    button,
                    start: point,
                    context,
                };
                Vec::new()
            }
        }
    }

    /// 按住移动。超过阈值后开始移动或缩放，之后每次都给出新的 frame。`shift` 是当前是否按着 Shift。
    pub fn moved(&mut self, point: ScreenPoint, shift: bool) -> Vec<GestureOutput> {
        match std::mem::take(&mut self.phase) {
            Phase::Pending {
                button,
                start,
                context,
            } => {
                if distance(start, point) <= DRAG_THRESHOLD {
                    self.phase = Phase::Pending {
                        button,
                        start,
                        context,
                    };
                    return Vec::new();
                }
                self.begin_drag(button, start, context, None, point, shift)
            }
            Phase::PendingEdge {
                start,
                edges,
                context,
            } => {
                if distance(start, point) <= DRAG_THRESHOLD {
                    self.phase = Phase::PendingEdge {
                        start,
                        edges,
                        context,
                    };
                    return Vec::new();
                }
                // 用按下时判定的边，不再按 12 点重新判断：用户抓的就是那条边。
                self.begin_drag(Button::Left, start, Some(context), Some(edges), point, shift)
            }
            Phase::Dragging {
                button,
                start,
                mut drag,
            } => {
                drag.current = frame_for(&drag, point.x - start.x, point.y - start.y, shift);
                let frame = drag.current;
                self.phase = Phase::Dragging { button, start, drag };
                vec![GestureOutput::LiveFrame(frame)]
            }
            other => {
                self.phase = other;
                Vec::new()
            }
        }
    }

    /// 松开。右键没拖动时弹菜单；边缘带上的左键没拖动时切换；拖动中则提交最终 frame。
    /// 与按下的键不同的松开忽略（例如左键拖动中按了一下右键）。
    pub fn release(&mut self, button: Button) -> Vec<GestureOutput> {
        let pressed = match &self.phase {
            Phase::Pending { button, .. } | Phase::Dragging { button, .. } => Some(*button),
            Phase::PendingEdge { .. } => Some(Button::Left),
            Phase::Idle | Phase::Suppressed => None,
        };
        if pressed.is_some_and(|b| b != button) {
            return Vec::new();
        }
        match std::mem::take(&mut self.phase) {
            Phase::Pending {
                button: Button::Right,
                ..
            } => vec![GestureOutput::Menu],
            // 边缘上的单击：没拖动，按普通点击切换。
            Phase::PendingEdge { .. } => vec![GestureOutput::Click],
            Phase::Dragging { drag, .. } => vec![GestureOutput::DragEnded(drag.current)],
            _ => Vec::new(),
        }
    }

    /// 取消进行中的手势，不提交（缩略图在拖动中被隐藏、窗口失去鼠标捕获时）。
    /// 返回取消前是否正在拖动：是的话调用方要送 `Event::DragCancelled`。
    pub fn cancel(&mut self) -> bool {
        let was_dragging = self.is_dragging();
        self.phase = Phase::Idle;
        was_dragging
    }

    /// 鼠标停在缩略图上（没有按键按下）时应显示缩放光标的边；规则与左键按下时的边缘带一致。
    pub fn hover_edges(&self, point: ScreenPoint, context: Option<&DragContext>) -> ResizeEdges {
        match (&self.phase, context) {
            (Phase::Idle, Some(c)) if c.allows_resize && !c.is_locked => edge_grip::edges(
                point,
                c.edge_frame,
                edge_grip::BAND_WIDTH,
                edge_grip::CORNER_LENGTH,
            ),
            _ => ResizeEdges::NONE,
        }
    }

    /// 开始拖动：按显示的 frame 判断移动还是缩放，把窗口放回基准 frame，再按当前位置算一次。
    fn begin_drag(
        &mut self,
        button: Button,
        start: ScreenPoint,
        context: Option<DragContext>,
        forced_edges: Option<ResizeEdges>,
        point: ScreenPoint,
        shift: bool,
    ) -> Vec<GestureOutput> {
        let Some(context) = context.filter(|c| !c.is_locked) else {
            self.phase = Phase::Suppressed;
            return Vec::new();
        };
        let edges = if context.allows_resize {
            forced_edges.unwrap_or_else(|| snap::resize_edges(start, context.edge_frame, RESIZE_MARGIN))
        } else {
            ResizeEdges::NONE
        };
        let base = context.start_frame;
        let mut drag = Drag {
            context,
            edges,
            current: base,
        };
        drag.current = frame_for(&drag, point.x - start.x, point.y - start.y, shift);
        let frame = drag.current;
        self.phase = Phase::Dragging { button, start, drag };
        vec![GestureOutput::DragBegan(base), GestureOutput::LiveFrame(frame)]
    }
}

/// 两点间的距离。
fn distance(a: ScreenPoint, b: ScreenPoint) -> f64 {
    (b.x - a.x).hypot(b.y - a.y)
}

/// 按位移算出新 frame：没有边是移动，否则是缩放。
fn frame_for(drag: &Drag, dx: f64, dy: f64, shift: bool) -> ScreenRect {
    let context = &drag.context;
    if drag.edges.is_empty() {
        // 移动：起点 frame 平移后吸附；按住 Shift 或关闭吸附时不吸附。
        let proposed = context.start_frame.offset_by(dx, dy);
        if !context.snap_enabled || shift {
            return proposed;
        }
        return snap::snap_move(proposed, &context.targets, DEFAULT_THRESHOLD).rect;
    }
    // 缩放：只移动被拖动的边，再吸附并按尺寸与宽高比约束。
    let mut proposed = context.start_frame;
    if drag.edges.contains(ResizeEdges::LEFT) {
        proposed.x += dx;
        proposed.width -= dx;
    }
    if drag.edges.contains(ResizeEdges::RIGHT) {
        proposed.width += dx;
    }
    if drag.edges.contains(ResizeEdges::TOP) {
        proposed.y += dy;
        proposed.height -= dy;
    }
    if drag.edges.contains(ResizeEdges::BOTTOM) {
        proposed.height += dy;
    }
    // 按住 Shift 时吸附目标为空（只做约束），并保持拖动开始时的宽高比。
    let keep_aspect = context.lock_aspect_ratio || shift;
    let none = SnapTargets::none();
    let targets = if context.snap_enabled && !shift {
        &context.targets
    } else {
        &none
    };
    snap::snap_resize(
        proposed,
        drag.edges,
        targets,
        DEFAULT_THRESHOLD,
        context.minimum_size,
        context.maximum_size,
        keep_aspect
            .then(|| context.start_frame.size().aspect_ratio())
            .flatten(),
    )
    .rect
}

#[cfg(test)]
mod tests {
    use eveo_core::geometry::ScreenSize;

    use super::*;

    /// 一个 384×216、位于 (100, 100) 的缩略图，可缩放、未锁定、吸附打开、没有其他目标。
    fn context() -> DragContext {
        let frame = ScreenRect::new(100.0, 100.0, 384.0, 216.0);
        DragContext {
            start_frame: frame,
            edge_frame: frame,
            is_locked: false,
            snap_enabled: true,
            lock_aspect_ratio: false,
            allows_resize: true,
            minimum_size: ScreenSize::new(192.0, 108.0),
            maximum_size: ScreenSize::new(960.0, 540.0),
            targets: SnapTargets::none(),
        }
    }

    /// 简写一个点。
    fn p(x: f64, y: f64) -> ScreenPoint {
        ScreenPoint::new(x, y)
    }

    /// 修饰键的简写。
    fn mods(ctrl: bool, alt: bool) -> Modifiers {
        Modifiers {
            ctrl,
            alt,
            shift: false,
        }
    }

    /// 中间的左键按下立即切换，之后的移动与松开什么也不做。
    #[test]
    fn plain_left_press_in_middle_clicks_immediately() {
        // (300, 200) 离四条边都远，不在边缘带内。
        let mut g = Gesture::new();
        assert_eq!(
            g.press(Button::Left, mods(false, false), p(300.0, 200.0), Some(context())),
            vec![GestureOutput::Click]
        );
        assert!(g.moved(p(350.0, 250.0), false).is_empty());
        assert!(g.release(Button::Left).is_empty());
    }

    /// Ctrl+左键最小化，即使按在边缘带上。
    #[test]
    fn ctrl_left_minimizes() {
        // (101, 101) 在左上角的角区里；Ctrl 优先于边缘判断。
        let mut g = Gesture::new();
        assert_eq!(
            g.press(Button::Left, mods(true, false), p(101.0, 101.0), Some(context())),
            vec![GestureOutput::Minimize]
        );
    }

    /// 右键按下松开、移动不超过阈值：弹菜单。
    #[test]
    fn right_click_without_drag_opens_menu() {
        // 移动约 2.8 像素，没超过 4 像素的阈值，仍算单击。
        let mut g = Gesture::new();
        assert!(
            g.press(
                Button::Right,
                mods(false, false),
                p(300.0, 200.0),
                Some(context())
            )
            .is_empty()
        );
        assert!(g.moved(p(302.0, 202.0), false).is_empty());
        assert_eq!(g.release(Button::Right), vec![GestureOutput::Menu]);
    }

    /// 右键从中间拖动：超过阈值后移动，松开时提交平移后的 frame。
    #[test]
    fn right_drag_moves_and_commits() {
        // 位移 (50, 30)；没有吸附目标，frame 原样平移。
        let mut g = Gesture::new();
        g.press(
            Button::Right,
            mods(false, false),
            p(300.0, 200.0),
            Some(context()),
        );
        let out = g.moved(p(350.0, 230.0), false);
        assert_eq!(out[0], GestureOutput::DragBegan(context().start_frame));
        assert_eq!(
            out[1],
            GestureOutput::LiveFrame(ScreenRect::new(150.0, 130.0, 384.0, 216.0))
        );
        assert_eq!(
            g.release(Button::Right),
            vec![GestureOutput::DragEnded(ScreenRect::new(
                150.0, 130.0, 384.0, 216.0
            ))]
        );
    }

    /// 不带修饰键的左键按在右边缘带上：松开时才切换；拖动则缩放右边。
    #[test]
    fn plain_left_on_edge_band_resizes_or_clicks_on_release() {
        // 右边在 x = 484，482 落在 6 像素的边缘带内、离上下角都远，只抓右边。
        let mut g = Gesture::new();
        assert!(
            g.press(Button::Left, mods(false, false), p(482.0, 200.0), Some(context()))
                .is_empty()
        );
        assert_eq!(g.release(Button::Left), vec![GestureOutput::Click]);

        g.press(Button::Left, mods(false, false), p(482.0, 200.0), Some(context()));
        let out = g.moved(p(532.0, 200.0), false);
        assert_eq!(
            out[1],
            GestureOutput::LiveFrame(ScreenRect::new(100.0, 100.0, 434.0, 216.0))
        );
    }

    /// Alt+左键从边缘 12 点内拖动：缩放那条边（这里是左边，右边不动）。
    #[test]
    fn alt_left_drag_near_edge_resizes() {
        // Alt+左键按 12 像素判断边：110 离左边 10 像素，抓左边；向左拖 20，左边外移、宽度加 20。
        let mut g = Gesture::new();
        g.press(Button::Left, mods(false, true), p(110.0, 200.0), Some(context()));
        let out = g.moved(p(90.0, 200.0), false);
        assert_eq!(
            out[1],
            GestureOutput::LiveFrame(ScreenRect::new(80.0, 100.0, 404.0, 216.0))
        );
    }

    /// 缩放受尺寸上下限约束。
    #[test]
    fn resize_is_clamped_to_minimum() {
        // 把右边拖到 x = 200 会让宽度只剩 100，下限 192 把它撑回来。
        let mut g = Gesture::new();
        g.press(Button::Left, mods(false, false), p(482.0, 200.0), Some(context()));
        let out = g.moved(p(200.0, 200.0), false);
        let GestureOutput::LiveFrame(frame) = out[1] else {
            panic!("{out:?}")
        };
        assert!((frame.width - 192.0).abs() < 1e-9);
    }

    /// 登录客户端不能缩放：边缘带不存在，左键按下即切换；右键从边缘拖动也是移动。
    #[test]
    fn login_clients_only_move() {
        // 登录客户端的尺寸不保存，所以不给缩放：同样的位置与位移只会移动。
        let mut ctx = context();
        ctx.allows_resize = false;
        let mut g = Gesture::new();
        assert_eq!(
            g.press(
                Button::Left,
                mods(false, false),
                p(482.0, 200.0),
                Some(ctx.clone())
            ),
            vec![GestureOutput::Click]
        );
        g.press(Button::Right, mods(false, false), p(482.0, 200.0), Some(ctx));
        let out = g.moved(p(532.0, 200.0), false);
        assert_eq!(
            out[1],
            GestureOutput::LiveFrame(ScreenRect::new(150.0, 100.0, 384.0, 216.0))
        );
    }

    /// 布局锁定时吞掉拖动：不移动，松开也不弹菜单。
    #[test]
    fn locked_layout_suppresses_drag() {
        // 锁定后右键拖动既不移动，也不在松开时弹菜单（用户本意是拖动）。
        let mut ctx = context();
        ctx.is_locked = true;
        let mut g = Gesture::new();
        g.press(Button::Right, mods(false, false), p(300.0, 200.0), Some(ctx));
        assert!(g.moved(p(400.0, 300.0), false).is_empty());
        assert!(g.release(Button::Right).is_empty());
    }

    /// 吸附到附近的屏幕边；按住 Shift 时不吸附。
    #[test]
    fn move_snaps_to_screen_edge_unless_shift() {
        // 向左移 95：左边落在 x = 5，离屏幕左边 5 像素，在 8 像素的吸附阈值内，吸到 0。
        let mut ctx = context();
        ctx.targets.screens = vec![ScreenRect::new(0.0, 0.0, 1920.0, 1080.0)];
        let mut g = Gesture::new();
        g.press(
            Button::Right,
            mods(false, false),
            p(300.0, 200.0),
            Some(ctx.clone()),
        );
        let out = g.moved(p(205.0, 200.0), false);
        assert_eq!(
            out[1],
            GestureOutput::LiveFrame(ScreenRect::new(0.0, 100.0, 384.0, 216.0))
        );
        let out = g.moved(p(205.0, 200.0), true);
        assert_eq!(
            out[0],
            GestureOutput::LiveFrame(ScreenRect::new(5.0, 100.0, 384.0, 216.0))
        );
    }

    /// 悬停放大时开始拖动：窗口先缩回基准 frame，再按位移移动。
    #[test]
    fn drag_from_zoomed_frame_starts_from_base_frame() {
        // 放大 2 倍后显示 768×432；拖动开始时窗口先回到 384×216 的基准 frame。
        let mut ctx = context();
        ctx.edge_frame = ScreenRect::new(100.0, 100.0, 768.0, 432.0);
        let mut g = Gesture::new();
        g.press(Button::Right, mods(false, false), p(600.0, 400.0), Some(ctx));
        let out = g.moved(p(610.0, 400.0), false);
        assert_eq!(
            out[0],
            GestureOutput::DragBegan(ScreenRect::new(100.0, 100.0, 384.0, 216.0))
        );
    }

    /// 取消拖动：报告曾在拖动，之后的松开不提交。
    #[test]
    fn cancel_during_drag_reports_and_drops_commit() {
        // 例如拖动中按 Alt+Tab：窗口失去捕获，之后的松开发生在别的窗口上。
        let mut g = Gesture::new();
        g.press(
            Button::Right,
            mods(false, false),
            p(300.0, 200.0),
            Some(context()),
        );
        g.moved(p(400.0, 200.0), false);
        assert!(g.cancel());
        assert!(g.release(Button::Right).is_empty());
        assert!(!g.cancel());
    }

    /// 拖动中松开的是另一个键：忽略，拖动继续。
    #[test]
    fn release_of_other_button_is_ignored() {
        // 右键拖动中按一下左键再松开：拖动不能因此提前结束。
        let mut g = Gesture::new();
        g.press(
            Button::Right,
            mods(false, false),
            p(300.0, 200.0),
            Some(context()),
        );
        g.moved(p(400.0, 200.0), false);
        assert!(g.release(Button::Left).is_empty());
        assert!(g.is_dragging());
    }

    /// 悬停光标：边缘带内给出边，中间、锁定或拖动中为空。
    #[test]
    fn hover_edges_follow_edge_band() {
        // 与左键按下的边缘带规则一致，光标形状与实际行为不会不符。
        let g = Gesture::new();
        assert_eq!(
            g.hover_edges(p(482.0, 200.0), Some(&context())),
            ResizeEdges::RIGHT
        );
        assert!(g.hover_edges(p(300.0, 200.0), Some(&context())).is_empty());
        let mut locked = context();
        locked.is_locked = true;
        assert!(g.hover_edges(p(482.0, 200.0), Some(&locked)).is_empty());
    }

    /// 客户端已消失（没有上下文）时右键拖动被吞掉。
    #[test]
    fn missing_context_suppresses_drag() {
        // 按下时客户端已在本轮轮询中消失，协调器给不出上下文。
        let mut g = Gesture::new();
        g.press(Button::Right, mods(false, false), p(300.0, 200.0), None);
        assert!(g.moved(p(400.0, 200.0), false).is_empty());
        assert!(g.release(Button::Right).is_empty());
    }
}
