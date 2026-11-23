// SPDX-License-Identifier: GPL-3.0-or-later
//
// 客户端发现的纯逻辑部分，对应 macOS 的 Clients/（架构文档 5.3 节）：
// 平台层枚举窗口 → `selector` 每个进程挑一个主窗口 → `ClientRegistry` 与上一轮比较得出差异。

//! 窗口标题解析、主窗口挑选与客户端登记。

mod registry;
pub mod selector;
pub mod title;

pub use registry::ClientRegistry;
