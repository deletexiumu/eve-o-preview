// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面文字，对应 macOS 的 Localization/（架构文档 5.2 节）。
// 文案写在 shared/l10n/ 的 TOML 里；shared/tools/gen_l10n.py 生成 generated/ 下的代码，生成结果提交进仓库，
// 所以 cargo build 不依赖 Python。CI 用 `gen_l10n.py --check` 核对生成结果没有过期。
//
// 每个域一个 trait（与 macOS 的协议同名），每种语言一个单元结构体实现它；按语言取实现的函数与 macOS 的
// L10n 访问器同名（如 `settings`、`combat`、`hotkeys`）。不带参数的文字返回 `&'static str`，带参数的返回 String。
// 只在 macOS 上用的文案（keys 里写了 platforms = ["macos"]）不生成；两端用词不同的文案取 windows 的写法。

//! EVE-O Preview 的界面文字。
//!
//! ```
//! use eveo_core::model::AppLanguage;
//! assert_eq!(eveo_l10n::settings(AppLanguage::Zh).cancel(), "取消");
//! ```

mod support;

/// 生成的代码。每条文案的说明在 trait 方法上；生成器不按 clippy 与 rustfmt 的习惯写。
#[allow(clippy::all)]
#[rustfmt::skip]
mod generated;

pub use generated::*;
pub use support::{Plural, plural};
