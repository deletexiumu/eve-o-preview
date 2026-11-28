// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗的内容视图（docs/macos/design-intel-translate.md 8.4、8.5 节）：把 Core 的 OverlayContent 交给 ui/overlay.slint 的
// OverlayWindow，并按 OverlayScrollRules 维护行、新消息条与阅读位置。对应 macOS 的 OverlayStyle 与 InfoOverlayContentView。
//
// 富文本：每行的各段按样式表（8.4 节）换成颜色与粗细，拼成 StyledText 认的 Markdown：
// - 颜色用 `<font color="#rrggbbaa">…</font>`，粗体用 `**…**`。StyledText 只有常规与粗体两档，macOS 的「中等」按常规画。
// - 文字里的 ASCII 标点一律加反斜杠转义，换行与制表符换成空格：消息正文来自聊天频道，任何人都能写，
//   不能让 `*`、`<`、`[` 之类被当成标记，也不能让一条消息拆成几段或变成列表。
// - 万一仍解析失败（不应发生），退回不带样式的纯文本，内容照常显示。
//
// 滚动（8.5 节）：
// - 换了角色（context_key 变了）：整表替换，回到底部。
// - 否则按 diff：头部去掉、中间改、尾部追加；对不上时整表替换。贴住底部时由 Slint 跟着滚到底部；
//   不贴时，去掉头部行前后各读一次内容高度，把滚动位置挪回差值，用户正在看的那一行停在原处。
// - 离开底部期间新到的条数显示在新消息条上，点它或菜单「滚动到最新」回到底部。

//! 浮窗的内容视图。

use std::cell::RefCell;
use std::fmt::Write as _;
use std::rc::Rc;

use slint::{ComponentHandle, Model, StyledText, VecModel};

use eveo_core::model::AppLanguage;
use eveo_core::overlay::scroll::{
    OverlayListPlaceholder, OverlayScrollState, after_append, after_user_scroll, diff, placeholder,
};
use eveo_core::overlay::{
    OverlayContent, OverlayEmphasis, OverlayLine, OverlaySpan, OverlaySpanStyle, OverlayStatusLevel,
};

use crate::{OverlayRowData, OverlayWindow};

/// 一段文字的颜色（8.4 节的表），`#rrggbbaa`。白色的几档不透明度：0.92 是 `eb`，0.8 是 `cc`，0.55 是 `8c`。
/// 颜色带上 alpha 两位，StyledText 的 `<font color>` 按 Slint 的颜色字面量解析，认 8 位十六进制。
/// 白色系的几档靠 alpha 区分主次：正文最亮，时间与说明次之，原文最暗，与 macOS 的观感一致。
pub fn span_color(style: OverlaySpanStyle) -> &'static str {
    use OverlaySpanStyle as S;
    match style {
        S::Plain | S::Translated => "#ffffffeb",
        S::Dim | S::Channel | S::AgeOld | S::JumpsUnknown | S::NoVisual | S::Pending => "#ffffff8c",
        S::Speaker => "#a8c7faff",
        S::AgeFresh => "#ff6b6bff",
        S::AgeRecent | S::JumpsMid => "#ffd166ff",
        S::SystemHigh | S::Clear => "#6bd38aff",
        S::SystemLow => "#f2b45aff",
        S::SystemNull | S::Failed => "#ff7a7aff",
        S::SystemUnknown => "#b8b8b8ff",
        S::JumpsNear => "#ff5252ff",
        S::JumpsFar => "#ffffffcc",
        S::Ship => "#7fc8ffff",
        S::Pilot => "#ffb870ff",
        S::Count => "#ffffffff",
    }
}

/// 一段文字是否用粗体：macOS 表里是粗体的两种（高亮距离以内的跳数、敌对数量）。
/// 只有这两种要一眼看到：敌对离得很近、来了多少人。其余样式靠颜色区分，不加粗，避免整行都很重。
pub fn is_bold(style: OverlaySpanStyle) -> bool {
    matches!(style, OverlaySpanStyle::JumpsNear | OverlaySpanStyle::Count)
}

/// 把一段文字转义后写进 out：ASCII 标点加反斜杠（CommonMark 允许转义任何 ASCII 标点），
/// 换行、回车与制表符换成空格（一条消息只占一段）。
/// 非 ASCII 的字符（中文、俄文、全角标点）在 CommonMark 里没有特殊含义，原样写出。
/// 反斜杠本身也是 ASCII 标点，同样转义，所以原文里的 `\` 显示为一个反斜杠。
fn escape_into(text: &str, out: &mut String) {
    for c in text.chars() {
        match c {
            '\n' | '\r' | '\t' => out.push(' '),
            c if c.is_ascii_punctuation() => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
}

/// 把一行的各段拼成 Markdown（见文件头）。空的段跳过。
/// 每段都包在自己的 `<font>` 里，段与段之间不共享样式；行首总是 `<font` 标签，
/// 所以正文开头的空格、数字加点（`1.`）、`-` 都不会被当成缩进代码块或列表。
pub fn markup(spans: &[OverlaySpan]) -> String {
    let mut out = String::new();
    for span in spans {
        if span.text.is_empty() {
            continue;
        }
        let _ = write!(out, "<font color=\"{}\">", span_color(span.style));
        if is_bold(span.style) {
            // `**` 紧挨着空白时不算粗体标记，所以两端的空白放在 `**` 外面。
            let trimmed = span.text.trim();
            let leading = &span.text[..span.text.len() - span.text.trim_start().len()];
            let trailing = &span.text[span.text.trim_end().len()..];
            escape_into(leading, &mut out);
            if !trimmed.is_empty() {
                out.push_str("**");
                escape_into(trimmed, &mut out);
                out.push_str("**");
            }
            escape_into(trailing, &mut out);
        } else {
            escape_into(&span.text, &mut out);
        }
        out.push_str("</font>");
    }
    out
}

/// 一行的富文本；解析失败时退回纯文本（各段直接相连）。
/// 解析在主线程上做，每行一次；一个浮窗至多 300 行，只在行新增或内容变化时解析，开销可以忽略。
pub fn styled(spans: &[OverlaySpan]) -> StyledText {
    StyledText::from_markdown(&markup(spans)).unwrap_or_else(|_| {
        let plain: String = spans.iter().map(|s| s.text.as_str()).collect();
        StyledText::from_plain_text(&plain.replace(['\n', '\r', '\t'], " "))
    })
}

/// 一条消息在列表里的一行。
/// 没有第二行时 secondary 是空的富文本，Slint 那边按 has-secondary 不建这个元素，不占高度。
pub fn row(line: &OverlayLine) -> OverlayRowData {
    OverlayRowData {
        primary: styled(&line.primary),
        secondary: styled(&line.secondary),
        has_secondary: !line.secondary.is_empty(),
        emphasis: match line.emphasis {
            OverlayEmphasis::None => 0,
            OverlayEmphasis::Alert => 1,
            OverlayEmphasis::Clear => 2,
        },
    }
}

/// 一个浮窗的内容视图：持有窗口、行的模型、当前内容与滚动状态。只在主线程上用。
///
/// 一个浮窗一个视图；预警与翻译两个浮窗各有一个。视图不管窗口的位置、显隐与层级，那些由应用层按规划结果设。
/// 右键菜单要的消息（复制、打开链接）从 lines 按 Slint 报的 hovered-row 取。
pub struct OverlayView {
    /// 浮窗。
    window: OverlayWindow,
    /// 列表的行，与 lines 一一对应。
    rows: Rc<VecModel<OverlayRowData>>,
    /// 当前显示的各条消息。
    lines: Vec<OverlayLine>,
    /// 当前的 context_key；还没显示过内容时为 None。
    context_key: Option<String>,
    /// 滚动状态。
    scroll: OverlayScrollState,
    /// 界面语言，用于说明与新消息条的文字。
    language: AppLanguage,
    /// 上一次的内容是否为空、属于哪种说明；换语言时据此重填。
    placeholder: Option<OverlayListPlaceholder>,
    /// 用户点了标题栏右侧的频道切换按钮，应用层取走后弹菜单。
    channel_switcher_clicked: bool,
}

impl OverlayView {
    /// 建视图并接上窗口的回调（用户滚动、点新消息条、点频道切换按钮）。回调只持有弱引用，视图释放后不再生效。
    ///
    /// 返回 Rc<RefCell<…>>：回调里要改视图的状态，应用层也要持有它来更新内容。
    /// 回调在 Slint 的事件处理里调用，这时应用层不会同时借用视图（两者都在主线程上、不重入）。
    pub fn attach(window: OverlayWindow, language: AppLanguage) -> Rc<RefCell<Self>> {
        // 行的模型只建一次，之后增删改都在这个模型上做，Slint 只重建变化的行。
        let rows = Rc::new(VecModel::default());
        window.set_rows(rows.clone().into());
        let view = Rc::new(RefCell::new(Self {
            window,
            rows,
            lines: Vec::new(),
            context_key: None,
            scroll: OverlayScrollState::INITIAL,
            language,
            placeholder: None,
            channel_switcher_clicked: false,
        }));
        let window = view.borrow().window.clone_strong();
        let weak = Rc::downgrade(&view);
        window.on_scrolled(move |distance| {
            if let Some(view) = weak.upgrade() {
                view.borrow_mut().user_scrolled(f64::from(distance));
            }
        });
        let weak = Rc::downgrade(&view);
        window.on_new_messages_clicked(move || {
            if let Some(view) = weak.upgrade() {
                view.borrow_mut().scroll_to_latest();
            }
        });
        let weak = Rc::downgrade(&view);
        window.on_channel_switcher_clicked(move || {
            if let Some(view) = weak.upgrade() {
                view.borrow_mut().channel_switcher_clicked = true;
            }
        });
        view
    }

    /// 取走「点击了频道切换按钮」的标志。
    pub fn take_channel_switcher_clicked(&mut self) -> bool {
        std::mem::take(&mut self.channel_switcher_clicked)
    }

    /// 浮窗。
    pub fn window(&self) -> &OverlayWindow {
        &self.window
    }

    /// 当前的滚动状态。
    pub fn scroll_state(&self) -> OverlayScrollState {
        self.scroll
    }

    /// 列表第 index 行对应的消息（右键菜单的「复制这一条」「在浏览器中打开」用）。
    pub fn line(&self, index: usize) -> Option<&OverlayLine> {
        self.lines.get(index)
    }

    /// 背景不透明度与第一行的字号。
    /// 字号按逻辑像素给 Slint，Slint 再乘屏幕缩放，所以 150% 屏幕上字也是同样大小。
    pub fn set_appearance(&self, opacity: f64, font_size: f64) {
        self.window.set_background_opacity(opacity.clamp(0.0, 1.0) as f32);
        self.window.set_font_size(font_size as f32);
    }

    /// 布局锁定状态：开启时在 1px 白色边线内侧叠加青蓝锁扣与内圈微光。
    pub fn set_locked(&self, locked: bool) {
        self.window.set_is_locked(locked);
    }

    /// 换界面语言：重填说明与新消息条。
    pub fn set_language(&mut self, language: AppLanguage) {
        self.language = language;
        self.refresh_labels();
    }

    /// 显示新的内容（8.5 节的「内容更新」）。
    ///
    /// 控制器每次刷新都给一份完整的内容（几秒一次，或者有新消息时）。这里按 diff 只改变化的行，
    /// 没变化的行不重新解析、不重新排版，滚动位置也不跳动。
    pub fn set_content(&mut self, content: &OverlayContent) {
        // 标题、频道切换按钮与状态行每次都照填：它们很短，比较是否变化不比直接设值省事；值没变时 Slint 不会重画。
        self.window.set_title_text(content.title.as_str().into());
        self.window
            .set_channel_label(content.channel_label.as_deref().unwrap_or("").into());
        let (status, level) = content.status.as_ref().map_or((String::new(), 0), |status| {
            let level = match status.level {
                OverlayStatusLevel::Info => 0,
                OverlayStatusLevel::Warning => 1,
                OverlayStatusLevel::Error => 2,
            };
            (status.text.clone(), level)
        });
        self.window.set_status_text(status.into());
        self.window.set_status_level(level);

        if self.context_key.as_deref() != Some(content.context_key.as_str()) {
            // 换了角色：整表替换，回到底部。
            self.replace_all(&content.lines);
            self.context_key = Some(content.context_key.clone());
            self.scroll = OverlayScrollState::INITIAL;
            self.window.invoke_scroll_to_bottom();
        } else {
            let change = diff(&self.lines, &content.lines);
            if change.is_reload {
                // 对不上：整表替换。不贴底部时保留滚动位置（收进新的内容范围）。
                let offset = self.window.get_content_y();
                self.replace_all(&content.lines);
                if !self.scroll.is_pinned_to_bottom {
                    self.restore_offset(offset);
                }
            } else {
                self.apply_diff(content, change.removed_from_head, &change.changed);
            }
            // 新消息只按尾部追加的条数计；中间改了内容（译文晚到）不算新消息。
            self.scroll = after_append(self.scroll, change.appended);
        }
        // 记下这份内容，下一次按它算 diff；说明的种类也记下，换语言时不需要内容就能重填。
        self.lines = content.lines.clone();
        self.placeholder = placeholder(content);
        self.window.set_pinned(self.scroll.is_pinned_to_bottom);
        self.refresh_labels();
    }

    /// 用户滚动了列表。
    /// 距离由 Slint 按「内容高度 + 滚动位置 - 可见高度」算出；程序自己滚动时 Slint 不报，不会误判为用户离开底部。
    pub fn user_scrolled(&mut self, distance_from_bottom: f64) {
        self.scroll = after_user_scroll(self.scroll, distance_from_bottom);
        self.window.set_pinned(self.scroll.is_pinned_to_bottom);
        self.refresh_labels();
    }

    /// 回到最新：滚到底部，状态回到初始。
    pub fn scroll_to_latest(&mut self) {
        self.scroll = OverlayScrollState::INITIAL;
        self.window.set_pinned(true);
        self.window.invoke_scroll_to_bottom();
        self.refresh_labels();
    }

    /// 一般情况：去掉头部、改中间、接上尾部。
    /// 三步的顺序不能换：先去掉头部（读高度差要在追加之前），再改中间（下标按去掉后的模型），最后追加。
    fn apply_diff(&mut self, content: &OverlayContent, removed: usize, changed: &[usize]) {
        if removed > 0 {
            // 不贴底部时，按去掉前后的内容高度差把滚动位置挪回，正在看的那一行停在原处。
            let before = self.window.get_content_height();
            let offset = self.window.get_content_y();
            for _ in 0..removed.min(self.rows.row_count()) {
                self.rows.remove(0);
            }
            if !self.scroll.is_pinned_to_bottom {
                let after = self.window.get_content_height();
                self.restore_offset(offset + (before - after));
            }
        }
        // changed 的下标是新列表里的；去掉头部之后，模型与新列表的前一部分逐行对齐。
        for &index in changed {
            if let Some(line) = content.lines.get(index)
                && index < self.rows.row_count()
            {
                self.rows.set_row_data(index, row(line));
            }
        }
        // 模型此时的行数就是新列表里已经对齐的前缀长度，其后都是新到的行。
        for line in content.lines.iter().skip(self.rows.row_count()) {
            self.rows.push(row(line));
        }
    }

    /// 整表替换。
    fn replace_all(&self, lines: &[OverlayLine]) {
        self.rows.set_vec(lines.iter().map(row).collect::<Vec<_>>());
    }

    /// 把滚动位置设为 offset，收进 [可见高度 - 内容高度, 0]：内容变矮后不留空白。
    /// 滚动位置是内容相对可见区域的偏移，向上滚时为负；0 是顶部，可见高度减内容高度是底部。
    fn restore_offset(&self, offset: f32) {
        let lowest = (self.window.get_visible_height() - self.window.get_content_height()).min(0.0);
        self.window.set_content_y(offset.clamp(lowest, 0.0));
    }

    /// 按当前状态填说明与新消息条的文字。
    /// 两处文字都随语言变；新消息条只在离开底部且有新条数时显示，贴住底部时新消息本来就看得见。
    fn refresh_labels(&self) {
        let text = eveo_l10n::overlay(self.language);
        let placeholder = match self.placeholder {
            Some(OverlayListPlaceholder::NoActiveCharacter) => text.no_active_character(),
            Some(OverlayListPlaceholder::Empty) => text.empty_list(),
            None => "",
        };
        self.window.set_placeholder(placeholder.into());
        let pill = if !self.scroll.is_pinned_to_bottom && self.scroll.unseen_count > 0 {
            text.new_messages(self.scroll.unseen_count as i64)
        } else {
            String::new()
        };
        self.window.set_new_messages(pill.into());
    }
}

pub mod host;

#[cfg(test)]
mod tests;
