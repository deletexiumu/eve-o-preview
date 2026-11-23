// SPDX-License-Identifier: GPL-3.0-or-later
//
// Slint 界面（架构文档 2.3 节）。界面只认视图模型，不碰平台层；这一版是设置窗口的视觉原型（M4、Q2）。

//! EVE-O Preview 的 Slint 界面。

/// Slint 编译器生成的组件。生成代码不写文档、不按 clippy 的习惯写。
#[allow(missing_docs, clippy::all)]
mod generated {
    slint::include_modules!();
}

pub use generated::*;

pub mod screenshot;
