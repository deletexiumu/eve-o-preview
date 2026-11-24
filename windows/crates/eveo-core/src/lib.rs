// SPDX-License-Identifier: GPL-3.0-or-later
//
// EVE-O Preview Windows 版的纯逻辑核心，逐模块对应 macOS 的 EVEOPreviewCore
// （docs/windows/architecture.md 3.1 节）。这里不调用任何平台接口，全部能在 Linux 上测试。
// 两端的行为由 shared/fixtures 里的同一批用例对齐（5.4 节）。

//! EVE-O Preview 的纯逻辑核心。
//!
//! - [`geometry`]：屏幕坐标中的点、尺寸、矩形与显示器信息。
//! - [`model`]：窗口与客户端的值类型。
//! - [`chat_log`]：聊天日志的解析、目录与文件取舍、覆盖情况与位置线索。
//! - [`clients`]：窗口标题解析、主窗口挑选与客户端登记。
//! - [`switching`]：循环组与登录客户端的循环顺序。
//! - [`layout`]：缩略图的基准位置、吸附、边缘缩放、悬停放大与画面裁剪。
//! - [`hotkeys`]：热键字符串的解析、规划与鼠标热键的匹配。
//! - [`planning`]：缩略图的可见性与呈现规划。
//! - [`combat_log`]：战斗日志的分行、文件头、伤害行解析、目录与文件挑选、提醒规则与防重放。
//! - [`config`]：配置的迁移、校验与配置方案的增删改。
//! - [`diagnostics`]：会话标记与上一次运行的归类、崩溃的证据。
//! - [`frame_cap`]：用 NVIDIA 驱动给 EVE 客户端限帧的计划与还原记录（Windows 独有）。
//! - [`translation`]：聊天翻译的接口解析、判断与分批、提示词、请求与答复。
//! - [`update`]：自动更新的版本号、Release 列表、发布说明、决策规则与更新包的核对。
//! - [`support`]：字符串枚举与宽松解码、十六进制颜色、与 Foundation 对齐的文本处理。

// 声明宏要在使用它们的模块之前引入，所以 support 放在最前面。
#[macro_use]
pub mod support;

pub mod autostart;
pub mod chat_log;
pub mod clients;
pub mod combat_log;
pub mod config;
pub mod diagnostics;
pub mod frame_cap;
pub mod geometry;
pub mod hotkeys;
pub mod intel;
pub mod layout;
pub mod logging;
pub mod model;
pub mod overlay;
pub mod planning;
pub mod static_data;
pub mod switching;
pub mod translation;
pub mod update;
