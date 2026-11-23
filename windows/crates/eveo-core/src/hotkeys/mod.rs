// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的纯逻辑部分，对应 macOS 的 Hotkeys/（架构文档 4.4 节）：作用范围、热键字符串的解析与规范写法、
// 规划（去重与拒绝）、启用规则与鼠标热键的匹配，以及注册编号的编码。
// 注册（RegisterHotKey）与鼠标钩子在 eveo-platform-win（M3 起）。两端的行为由 shared/fixtures/hotkey 对齐。

//! 热键。

pub mod activation;
pub mod backend;
mod hotkey;
pub mod key_code;
pub mod planner;
mod spec;

pub use activation::{MouseBinding, MouseButtonEventKind, MouseHotkeyDecision, MouseHotkeyMatcher};
pub use hotkey::{Hotkey, HotkeyModifiers, HotkeyTrigger, MOUSE_BUTTON_RANGE, WINDOWS_MOUSE_BUTTONS};
pub use planner::{HotkeyAction, HotkeyBinding, HotkeyIssue, HotkeyPlan, HotkeyRejection};
pub use spec::HotkeySpec;

string_enum! {
    /// 没有 `@global`、`@game` 后缀的热键的作用范围。
    pub enum HotkeyScope {
        /// 对所有应用生效。
        Global => "global",
        /// 只在前台是 EVE 客户端时生效；前台是本应用的设置窗口或其他应用时都不生效。
        Game => "game",
    }
}
