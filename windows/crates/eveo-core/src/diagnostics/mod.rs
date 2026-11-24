// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断的纯逻辑部分，对应 macOS 的 Diagnostics/（docs/macos/design-v1.1.md 第 6 节）：
// - session：会话标记 session.json 的读写与上一次运行的归类。
// - crash：上一次异常结束时找崩溃的证据。Windows 上有两处：WER 的报告目录，与本应用自己的日志里
//   那次会话的 fault 行（panic 钩子与顶层异常过滤器写的）。
// 读目录、读文件由应用层做，这里只判断。

//! 会话标记与崩溃的证据。

pub mod crash;
pub mod session;
