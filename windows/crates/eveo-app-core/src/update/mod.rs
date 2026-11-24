// SPDX-License-Identifier: GPL-3.0-or-later
//
// 自动更新在应用层的部分（docs/windows/architecture.md 6.3 节）：state.json 的更新记录与更新流程的状态机。
// 规则（版本比较、要不要提示、何时检查、能否安装）在 eveo_core::update；网络、文件与替换 exe 在平台层；
// 这里把两者串起来，决定「现在该做什么」，由应用层执行。状态机不碰 I/O，所以能用普通单元测试覆盖整个流程。

//! 自动更新的记录与流程。

pub mod machine;
pub mod state;
