// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVE-O Preview Windows 版的纯逻辑核心，逐模块对应 macOS 的 EVEOPreviewCore
// （docs/windows/architecture.md 3.1 节）。这里不调用任何平台接口，全部能在 Linux 上测试。
// 两端的行为由 shared/fixtures 里的同一批用例对齐（5.4 节）。

//! EVE-O Preview 的纯逻辑核心。
//!
//! - [`geometry`]：屏幕坐标中的点、尺寸、矩形与显示器信息。
//! - [`model`]：窗口与客户端的值类型。
//! - [`clients`]：窗口标题解析、主窗口挑选与客户端登记。
//! - [`switching`]：循环组与登录客户端的循环顺序。

pub mod clients;
pub mod geometry;
pub mod model;
pub mod switching;
