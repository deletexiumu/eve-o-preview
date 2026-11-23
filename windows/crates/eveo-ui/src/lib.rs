// SPDX-License-Identifier: GPL-3.0-or-later
//
// Slint 界面（架构文档 2.3 节）。界面只认视图模型，不碰平台层。
// bind 模块把配置与各页的全局模型互相转换；screenshot 用软件渲染器出图，不需要显示器。

//! EVE-O Preview 的 Slint 界面。

/// Slint 编译器生成的组件。生成代码不写文档、不按 clippy 的习惯写。
#[allow(missing_docs, clippy::all)]
mod generated {
    slint::include_modules!();
}

pub use generated::*;

pub mod bind;
pub mod profiles;
pub mod screenshot;
pub mod switching;
