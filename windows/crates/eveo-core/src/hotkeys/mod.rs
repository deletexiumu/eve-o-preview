// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键的纯逻辑部分，对应 macOS 的 Hotkeys/。M2b 先放配置要用的作用范围；
// 热键字符串的解析、冲突检查与规划在 M2c 加入。

//! 热键。

string_enum! {
    /// 没有 `@global`、`@game` 后缀的热键的作用范围。
    pub enum HotkeyScope {
        /// 对所有应用生效。
        Global => "global",
        /// 只在前台是 EVE 客户端时生效；前台是本应用的设置窗口或其他应用时都不生效。
        Game => "game",
    }
}
