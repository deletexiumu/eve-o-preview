// SPDX-License-Identifier: GPL-3.0-or-later
//
// 数据模型，对应 macOS 的 Model/。M2a 先移植窗口与客户端模型；配置模型在 M2b 加入。

//! 数据模型。

mod client;

pub use client::{ClientChange, ClientIdentity, EveClient, Pid, RegistryDiff, WindowId, WindowInfo};
