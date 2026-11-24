// SPDX-License-Identifier: GPL-3.0-or-later
//
// Slint 界面（架构文档 2.3 节）。界面只认视图模型，不碰平台层。
// bind 模块把配置与各页的全局模型互相转换；screenshot 用软件渲染器出图，不需要显示器。
// 界面上的文字在 ui/generated/l10n.slint 的全局里（SettingsText 等），l10n 模块按界面语言填值；两者都由
// shared/tools/gen_l10n.py 生成。

//! EVE-O Preview 的 Slint 界面。

/// Slint 编译器生成的组件。生成代码不写文档、不按 clippy 的习惯写。
#[allow(missing_docs, clippy::all)]
mod generated {
    slint::include_modules!();
}

pub use generated::*;
pub use language::{language, set_language};

pub mod alerts;
pub mod bind;
pub mod chat;
pub mod environment;
pub mod general;
#[rustfmt::skip]
pub mod l10n;
pub mod language;
pub mod overlay;
pub mod profiles;
pub mod screenshot;
pub mod switching;
pub mod translation;
