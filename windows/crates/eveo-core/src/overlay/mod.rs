// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的内容模型，对应 macOS 的 EVEOPreviewCore/Overlay/OverlayModels.swift（docs/macos/design-intel-translate.md
// 8.2 节）。预警与翻译各自把消息排成 OverlayContent，浮窗面板只认这里的类型，不知道预警与翻译的区别。
// 样式到颜色、字重的对应在界面层（Slint），这里只给语义上的样式名。
// - OverlayKind：浮窗的种类；聊天日志的跟踪请求也用它记下打开了哪些功能。
// - OverlaySpan / OverlaySpanStyle：一段带样式的文字。
// - OverlayLine：一条消息，至多两行文字，另带强调背景、复制文字与右键链接。
// - OverlayStatus / OverlayContent：标题下的状态行与整个浮窗的内容。
// - planner：浮窗的可见性、位置、层级与外观，以及活动角色（8.6 节）。
// - scroll：列表的滚动状态、新旧列表的差异与空列表的说明（8.5 节）。

//! 浮窗的种类与内容模型。

pub mod planner;
pub mod scroll;

#[cfg(test)]
mod tests;

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

/// 一段文字的样式（8.4 节的表）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OverlaySpanStyle {
    /// 普通文字。
    Plain,
    /// 暗色文字（分隔符、原文、没查到的人名）。
    Dim,
    /// 说话人。
    Speaker,
    /// 频道名。
    Channel,
    /// 时间：不足 120 秒。
    AgeFresh,
    /// 时间：不足 300 秒。
    AgeRecent,
    /// 时间：更早。
    AgeOld,
    /// 星系：高安（≥ 0.5）。
    SystemHigh,
    /// 星系：低安（0.1～0.4）。
    SystemLow,
    /// 星系：零安（≤ 0.0）。
    SystemNull,
    /// 星系：没有安全等级或虫洞。
    SystemUnknown,
    /// 跳数：高亮距离以内。
    JumpsNear,
    /// 跳数：高亮距离的两倍以内。
    JumpsMid,
    /// 跳数：更远。
    JumpsFar,
    /// 跳数：算不出。
    JumpsUnknown,
    /// 舰船。
    Ship,
    /// 人名。
    Pilot,
    /// 敌对数量。
    Count,
    /// 「安全」。
    Clear,
    /// 「未见」。
    NoVisual,
    /// 译文。
    Translated,
    /// 翻译中。
    Pending,
    /// 未翻译（失败）。
    Failed,
}

/// 一段带样式的文字。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlaySpan {
    /// 文字。
    pub text: String,
    /// 样式。
    pub style: OverlaySpanStyle,
}

impl OverlaySpan {
    /// 用文字与样式建一段。
    pub fn new(text: impl Into<String>, style: OverlaySpanStyle) -> Self {
        Self {
            text: text.into(),
            style,
        }
    }
}

/// 一行的强调背景。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OverlayEmphasis {
    /// 没有背景。
    #[default]
    None,
    /// 敌对在高亮距离以内（红色背景）。
    Alert,
    /// 报告安全（绿色背景）。
    Clear,
}

/// 右键「在浏览器中打开」的一项（6.9 节、8.7 节）。浮窗只显示 title，点击时 url 是 https 才打开。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayLink {
    /// 菜单项的文字。
    pub title: String,
    /// https 地址。
    pub url: String,
}

/// 浮窗里的一行（一条消息），至多两行文字。
/// 第一行是解析后的要点，第二行是原文；翻译浮窗里第一行是译文，第二行是原文。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct OverlayLine {
    /// 消息的编号，在一个浮窗内唯一且递增；浮窗按它对齐新旧列表。
    pub id: u64,
    /// 第一行。
    pub primary: Vec<OverlaySpan>,
    /// 第二行，字号小一级；空表示没有。
    pub secondary: Vec<OverlaySpan>,
    /// 强调背景。
    pub emphasis: OverlayEmphasis,
    /// 右键「复制」时放进剪贴板的文字。
    pub copy_text: String,
    /// 右键「在浏览器中打开」的各项；空表示没有，菜单里不出现这一项（6.9 节）。
    pub links: Vec<OverlayLink>,
}

/// 状态行的级别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayStatusLevel {
    /// 说明（白色，半透明）。
    Info,
    /// 提醒（黄色）。
    Warning,
    /// 错误（红色）。
    Error,
}

/// 浮窗标题下的状态行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayStatus {
    /// 文字，至多显示 2 行。
    pub text: String,
    /// 级别。
    pub level: OverlayStatusLevel,
}

/// 一个浮窗要显示的全部内容。
/// 控制器每次刷新都建一份完整的内容，浮窗按 context_key 与各行的 id 判断是整表重载还是只追加新行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayContent {
    /// 换了角色就换一个值，浮窗据此整表重载并回到底部。
    pub context_key: String,
    /// 标题行。
    pub title: String,
    /// 标题行右侧频道切换按钮的文字；None 时不显示按钮（预警浮窗没有这一项）。
    pub channel_label: Option<String>,
    /// 状态行；None 时不显示。
    pub status: Option<OverlayStatus>,
    /// 各行，旧的在前，最新的在最后。
    pub lines: Vec<OverlayLine>,
}
