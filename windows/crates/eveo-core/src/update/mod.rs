// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动更新的规则（docs/windows/architecture.md 6.3 节）：从 macOS 的 EVEOPreviewCore/Updates 移植，行为与 macOS 一致；
// Windows 的差别（只取 Release 列表、`v` 与旧的 `win-v` 两种 tag、预发布的渠道、ed25519 签名的校验和文件、便携 exe）
// 写在各模块的开头。网络、文件与替换 exe 在平台层与应用层，这里只有纯函数。

//! 自动更新的规则。
//!
//! - [`version`]：语义化版本号。
//! - [`feed`]：检查地址、附件地址的核对与附件名。
//! - [`parser`]：Release 列表的解析与限流判断。
//! - [`history`]：中间版本的发布说明。
//! - [`notes`]：发布说明按语言的选取与切块。
//! - [`policy`]：能否安装、挑哪个版本、要不要提示、何时检查、新 exe 能否安装。
//! - [`install`]：替换 exe 与回滚的规则。
//! - [`archive`]：从更新包里取出 exe、PE 头的机器类型。
//! - [`checksums`]：校验和文件、签名与 SHA-256。
//! - [`models`]：值类型与错误。

pub mod archive;
pub mod checksums;
pub mod feed;
pub mod history;
pub mod install;
pub mod models;
pub mod notes;
pub mod parser;
pub mod policy;
pub mod version;
