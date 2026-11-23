// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置里一条热键字符串的解析结果，对应 macOS 的 Hotkeys/HotkeySpec.swift。
// 语法：热键字符串 = 热键 [ "@" 作用范围 ]，作用范围是 global 或 game，不区分大小写，`@` 两侧的空白去掉。
// 没有后缀表示跟随配置方案的 hotkeyDefaultScope。
// `@` 后面不是 global 或 game、有多个 `@`、`@` 前面为空，都解析失败。

//! 带作用范围后缀的热键字符串。

use std::fmt;

use super::{Hotkey, HotkeyScope};
use crate::support::{StringEnum, text};

/// 配置里一条热键字符串的解析结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct HotkeySpec {
    /// 热键（触发键加修饰键）。
    pub hotkey: Hotkey,
    /// 作用范围；`None` 表示跟随配置方案的默认值。
    pub scope: Option<HotkeyScope>,
}

impl HotkeySpec {
    /// 解析一条热键字符串，如 `ctrl+Mouse4@game`、`F13`、`alt+F13 @ Global`。解析失败时返回 `None`。
    pub fn parse(string: &str) -> Option<Self> {
        let parts: Vec<&str> = string.split('@').collect();
        match parts.as_slice() {
            [hotkey] => Some(Self {
                hotkey: Hotkey::parse(hotkey)?,
                scope: None,
            }),
            [hotkey, suffix] => {
                // 后缀去掉空白后按小写匹配；前面的热键部分交给 Hotkey 解析（它自己去掉各段的空白）。
                let scope = HotkeyScope::from_raw(&text::trim_whitespace(suffix).to_lowercase())?;
                Some(Self {
                    hotkey: Hotkey::parse(hotkey)?,
                    scope: Some(scope),
                })
            }
            // 多个 `@`。
            _ => None,
        }
    }

    /// 已解析的作用范围：有后缀时取后缀，否则取配置方案的默认值。
    pub fn resolved_scope(&self, profile_default: HotkeyScope) -> HotkeyScope {
        self.scope.unwrap_or(profile_default)
    }
}

/// 规范写法：热键的规范写法，有作用范围时紧跟 `@global` 或 `@game`，如 `ctrl+Mouse4@game`。
impl fmt::Display for HotkeySpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.hotkey)?;
        if let Some(scope) = self.scope {
            write!(f, "@{}", scope.raw())?;
        }
        Ok(())
    }
}
