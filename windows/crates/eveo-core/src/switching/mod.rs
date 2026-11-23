// SPDX-License-Identifier: GPL-3.0-or-later
//
// 客户端切换的纯逻辑部分，对应 macOS 的 Switching/。

//! 循环组与登录客户端的循环顺序。

pub mod cycle;

pub use cycle::CycleDirection;
