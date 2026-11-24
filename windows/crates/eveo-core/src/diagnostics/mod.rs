// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断的纯逻辑部分，对应 macOS 的 Diagnostics/（docs/macos/design-v1.1.md 第 6 节）：
// - session：会话标记 session.json 的读写与上一次运行的归类。
// - crash：上一次异常结束时找崩溃的证据。Windows 上有两处：WER 的报告目录，与本应用自己的日志里
//   那次会话的 fault 行（panic 钩子与顶层异常过滤器写的）。
// - redactor：问题报告的脱敏（用户名、计算机名、角色名、设备标识）与角色名的收集。
// - summary：配置摘要、环境报告、日志的取舍与文件清单。
// - issue：预填的 GitHub Issue 地址。
// 读目录、读文件由应用层做，这里只判断。

//! 会话标记、崩溃的证据与问题报告。

pub mod crash;
pub mod issue;
pub mod redactor;
pub mod session;
pub mod summary;
