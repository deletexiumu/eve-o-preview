// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的内容模型，对应 macOS 的 EVEOPreviewCore/Overlay（docs/macos/design-intel-translate.md 8.2 节）。
// 目前只有浮窗的种类：聊天日志的跟踪请求用它记下打开了哪些功能。排版与样式在后续的浮窗里加。

//! 浮窗的种类（预警、翻译）。

/// 浮窗的种类：同一种面板，两个实例。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum OverlayKind {
    /// 预警浮窗。
    Intel,
    /// 翻译浮窗。
    Translation,
}

impl OverlayKind {
    /// 全部种类，按设置界面里的顺序。
    pub const ALL: [OverlayKind; 2] = [OverlayKind::Intel, OverlayKind::Translation];
}
