// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键按作用范围启用与停用的规则，以及鼠标热键的匹配与吞掉规则，对应 macOS 的 Hotkeys/HotkeyActivation.swift。
// 规则是纯逻辑；平台层的热键服务与低级鼠标钩子（WH_MOUSE_LL）只负责调系统接口，判断都交给这里。
// Windows 的钩子回调里没有「拖动」事件，按下后的移动不送进来即可；保留这一种是为了与 macOS 共用用例。

//! 热键的启用规则与鼠标热键的匹配。

use std::collections::BTreeSet;

use super::{HotkeyModifiers, HotkeyScope};

/// 一条绑定此刻是否应启用：没有暂停，且作用范围是 `global`，或作用范围是 `game` 且前台是 EVE 客户端。
pub fn is_active(scope: HotkeyScope, is_game_frontmost: bool, is_suspended: bool) -> bool {
    !is_suspended
        && match scope {
            HotkeyScope::Global => true,
            HotkeyScope::Game => is_game_frontmost,
        }
}

/// 鼠标事件的种类。只有中键与侧键的事件会送到匹配器。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButtonEventKind {
    /// 按下（WM_MBUTTONDOWN、WM_XBUTTONDOWN）。
    Down,
    /// 按住移动（Windows 不送；macOS 的 otherMouseDragged）。
    Dragged,
    /// 松开（WM_MBUTTONUP、WM_XBUTTONUP）。
    Up,
}

/// 匹配器对一个鼠标事件的决定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseHotkeyDecision {
    /// 放行，事件照常传给前台应用。
    Pass,
    /// 吞掉，不触发热键（已吞掉的按下之后的拖动与松开）。
    Swallow,
    /// 吞掉并触发关联值所指的绑定。
    Fire(u32),
}

/// 一条鼠标绑定。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MouseBinding {
    /// 绑定编号，触发时回传。
    pub id: u32,
    /// 按钮号，2～4（与 `Hotkey` 的编号相同）。
    pub button: u8,
    /// 修饰键，要与事件的修饰键完全相同。
    pub modifiers: HotkeyModifiers,
    /// 已解析的作用范围。
    pub scope: HotkeyScope,
}

/// 只因还按着按钮而开着的钩子，最多再开多少秒。到期后放弃等松开，避免松开事件丢失时钩子一直开着。
pub const RELEASE_TIMEOUT: f64 = 10.0;

/// 鼠标热键的匹配状态：绑定表、前台状态、暂停状态与「按下已被吞掉」的按钮号。
///
/// 规则与 macOS 相同：
/// - 按下：先把按钮号移出 `swallowed_buttons`。没有暂停，且有绑定的按钮号与修饰键完全相同、作用范围此刻生效时，
///   把按钮号放进 `swallowed_buttons` 并触发；否则放行。
/// - 松开：按钮号在 `swallowed_buttons` 里时移出并吞掉，否则放行。不看松开时的修饰键、前台与暂停状态。
/// - 拖动：按钮号在 `swallowed_buttons` 里时吞掉，否则放行。
/// - 一次按下被吞掉，它的松开也要吞掉，否则前台应用会收到一个没有按下的松开。所以替换绑定表、前台变化、
///   暂停都不清空 `swallowed_buttons`；只要还有按钮按着，钩子就保持安装（见 `should_listen`）。
/// - 只因还按着按钮而装着的钩子，最多再装 `RELEASE_TIMEOUT` 秒（见 `refresh_release_deadline`），到期清空。
///   钩子被系统摘掉、被拆除时也整个清空：期间的松开收不到。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MouseHotkeyMatcher {
    bindings: Vec<MouseBinding>,
    is_game_frontmost: bool,
    is_suspended: bool,
    swallowed_buttons: BTreeSet<u8>,
    release_deadline: Option<f64>,
}

impl MouseHotkeyMatcher {
    /// 建一个空的匹配器：没有绑定，前台不是游戏，没有暂停。
    pub fn new() -> Self {
        Self::default()
    }

    /// 当前的鼠标绑定，按规划的顺序；同一按钮号与修饰键有多条时第一条生效。
    pub fn bindings(&self) -> &[MouseBinding] {
        &self.bindings
    }

    /// 按下已被吞掉、还没收到松开的按钮号。
    pub fn swallowed_buttons(&self) -> &BTreeSet<u8> {
        &self.swallowed_buttons
    }

    /// 钩子只因还按着按钮而装着时的截止时刻（单调时钟的秒）；不在这种状态时为 `None`。
    pub fn release_deadline(&self) -> Option<f64> {
        self.release_deadline
    }

    /// 是否存在此刻生效的绑定：没有暂停，且作用范围此刻生效。
    pub fn has_active_binding(&self) -> bool {
        self.bindings.iter().any(|b| self.binding_is_active(b))
    }

    /// 钩子此刻应否安装：存在此刻生效的绑定，或者还有已吞掉按下、没等到松开的按钮。
    pub fn should_listen(&self) -> bool {
        self.has_active_binding() || !self.swallowed_buttons.is_empty()
    }

    /// 替换绑定表。`swallowed_buttons` 保留：已吞掉的按下，它的松开照样吞掉。
    pub fn replace_bindings(&mut self, bindings: Vec<MouseBinding>) {
        self.bindings = bindings;
    }

    /// 更新前台状态。`swallowed_buttons` 保留。
    pub fn set_game_frontmost(&mut self, is_frontmost: bool) {
        self.is_game_frontmost = is_frontmost;
    }

    /// 更新暂停状态。暂停期间新的按下一律放行；暂停前已吞掉的按下，它的松开照样吞掉。
    pub fn set_suspended(&mut self, suspended: bool) {
        self.is_suspended = suspended;
    }

    /// 钩子被系统摘掉或被拆除时调用：期间的松开事件可能丢了，清空 `swallowed_buttons`。
    pub fn hook_was_removed(&mut self) {
        self.swallowed_buttons.clear();
        self.release_deadline = None;
    }

    /// 整理「只因按着按钮而装着」的截止时刻，返回调用方下一次应检查的时刻；`None` 表示不用再检查。
    ///
    /// - 有生效的绑定，或者没有按钮按着：不在这种状态，清掉截止时刻。
    /// - 刚进入这种状态：截止时刻记为 now 加 `RELEASE_TIMEOUT`。计时从这一刻开始，不从按下开始。
    /// - 已到截止时刻：清空 `swallowed_buttons`，之后钩子可以拆除。
    pub fn refresh_release_deadline(&mut self, now: f64) -> Option<f64> {
        if self.has_active_binding() || self.swallowed_buttons.is_empty() {
            self.release_deadline = None;
            return None;
        }
        match self.release_deadline {
            None => {
                self.release_deadline = Some(now + RELEASE_TIMEOUT);
                self.release_deadline
            }
            Some(deadline) if now < deadline => Some(deadline),
            Some(_) => {
                self.hook_was_removed();
                None
            }
        }
    }

    /// 判断一个事件。modifiers 只应含 Ctrl、Alt、Shift、Win 四种。
    pub fn handle(
        &mut self,
        kind: MouseButtonEventKind,
        button: u8,
        modifiers: HotkeyModifiers,
    ) -> MouseHotkeyDecision {
        match kind {
            MouseButtonEventKind::Down => {
                // 先移出：上一次点击的松开可能没收到，不能让它影响这一次。
                self.swallowed_buttons.remove(&button);
                if self.is_suspended {
                    return MouseHotkeyDecision::Pass;
                }
                let hit = self
                    .bindings
                    .iter()
                    .find(|b| b.button == button && b.modifiers == modifiers && self.binding_is_active(b));
                match hit {
                    Some(binding) => {
                        let id = binding.id;
                        self.swallowed_buttons.insert(button);
                        MouseHotkeyDecision::Fire(id)
                    }
                    None => MouseHotkeyDecision::Pass,
                }
            }
            MouseButtonEventKind::Up => {
                if self.swallowed_buttons.remove(&button) {
                    MouseHotkeyDecision::Swallow
                } else {
                    MouseHotkeyDecision::Pass
                }
            }
            MouseButtonEventKind::Dragged => {
                if self.swallowed_buttons.contains(&button) {
                    MouseHotkeyDecision::Swallow
                } else {
                    MouseHotkeyDecision::Pass
                }
            }
        }
    }

    /// 一条绑定此刻是否生效。
    fn binding_is_active(&self, binding: &MouseBinding) -> bool {
        is_active(binding.scope, self.is_game_frontmost, self.is_suspended)
    }
}
