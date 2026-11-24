// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗内容视图的用例：富文本的转义与样式、按 diff 更新行、新消息条与说明的文字、阅读位置。
// 视图的用例用软件渲染平台建真的 OverlayWindow（每个测试线程各设一次平台），读 Slint 算出的内容高度。

use super::*;
use eveo_core::overlay::{OverlayStatus, OverlayStatusLevel};
use i_slint_core::styled_text::get_raw_text;
use slint::platform::software_renderer::PremultipliedRgbaColor;

/// 一段普通文字。
fn plain(text: &str) -> OverlaySpan {
    OverlaySpan::new(text, OverlaySpanStyle::Plain)
}

/// 编号为 id 的一行，正文是 `message {id}` 加 suffix。
fn line(id: u64, suffix: &str) -> OverlayLine {
    OverlayLine {
        id,
        primary: vec![
            OverlaySpan::new("12s ", OverlaySpanStyle::AgeFresh),
            OverlaySpan::new("Jita", OverlaySpanStyle::SystemHigh),
            plain(&format!(" message {id}{suffix}")),
        ],
        secondary: vec![OverlaySpan::new(
            format!("Pilot > raw {id}"),
            OverlaySpanStyle::Dim,
        )],
        copy_text: format!("raw {id}"),
        ..OverlayLine::default()
    }
}

/// 角色 key 的一份内容，含编号 ids 的各行。
fn content(key: &str, ids: impl IntoIterator<Item = u64>) -> OverlayContent {
    OverlayContent {
        context_key: key.to_owned(),
        title: "Intel · Pilot Alpha".to_owned(),
        status: None,
        lines: ids.into_iter().map(|id| line(id, "")).collect(),
    }
}

/// 建一个 380×260 的浮窗视图（英文）。
///
/// 尺寸与默认的浮窗相同；显示后 Slint 才按窗口尺寸排版，读到的可见高度才对。
fn view() -> Rc<RefCell<OverlayView>> {
    crate::screenshot::ensure_platform().expect("软件渲染平台");
    let window = OverlayWindow::new().expect("建浮窗");
    window.window().set_size(slint::LogicalSize::new(380.0, 260.0));
    window.show().expect("显示浮窗");
    OverlayView::attach(window, AppLanguage::En)
}

/// 用软件渲染器画一帧（380×260，按 1 倍缩放）。
///
/// 测试线程的软件渲染窗口与截图共用一个；缩放是 1，像素尺寸就是逻辑尺寸。
fn render() {
    let window = crate::screenshot::window().expect("软件渲染窗口");
    let mut pixels = vec![PremultipliedRgbaColor::default(); 380 * 260];
    window.request_redraw();
    window.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, 380);
    });
}

/// 富文本去掉标记后的文字。
fn raw(text: &StyledText) -> String {
    get_raw_text(text).into_owned()
}

/// 任何人都能写的消息正文：Markdown 与 HTML 的标记、实体、列表与标题的写法都按原样显示，不报错。
#[test]
fn markup_escapes_chat_text() {
    let hostile = [
        "**bold** _em_ ~~del~~ `code`",
        "<b>x</b> <font color=\"red\">y</font> <u>z</u>",
        "[link](https://example.test) ![img](a.png)",
        "# heading",
        "1. first",
        "- item",
        "&amp; &lt; \\ backslash",
        "> quote",
        "    four spaces",
        "line\nbreak\ttab",
        "中文 · 「引号」 ***",
    ];
    for text in hostile {
        let spans = [plain(text)];
        let parsed = StyledText::from_markdown(&markup(&spans));
        assert!(parsed.is_ok(), "{text:?} 解析失败：{:?}", parsed.err());
        // 段首的空白在 Markdown 里会被去掉，比较时两边都去掉两端空白；换行与制表符换成了空格。
        let expected = text.replace(['\n', '\t'], " ");
        assert_eq!(raw(&styled(&spans)).trim(), expected.trim(), "{text:?}");
    }
}

/// 每段都带颜色；粗体只给跳数（近）与数量，两端的空白放在粗体外面，文字不变。
#[test]
fn markup_colors_and_bold() {
    let spans = [
        OverlaySpan::new("3j", OverlaySpanStyle::JumpsNear),
        plain(" · "),
        OverlaySpan::new(" 5 ", OverlaySpanStyle::Count),
        OverlaySpan::new("", OverlaySpanStyle::Ship),
        OverlaySpan::new("Sabre*", OverlaySpanStyle::Ship),
    ];
    // 粗体在颜色标签里面，`**` 紧贴文字；数量两端的空格留在粗体外面。
    let text = markup(&spans);
    assert!(text.contains("<font color=\"#ff5252ff\">**3j**</font>"));
    assert!(text.contains(" **5** "));
    // 空的段不出现。
    assert_eq!(text.matches("<font").count(), 4);
    let styled = styled(&spans);
    assert_eq!(raw(&styled), "3j ·  5 Sabre*");
    // 样式不是公开字段，只能从 Debug 输出里确认粗体与颜色都解析出来了。
    let debug = format!("{styled:?}");
    assert!(debug.contains("Strong"));
    assert!(debug.contains("Color"));
    assert!(is_bold(OverlaySpanStyle::Count));
    assert!(!is_bold(OverlaySpanStyle::SystemHigh));
}

/// 一行：强调背景与第二行。
#[test]
fn rows_map_emphasis_and_secondary() {
    let mut alert = line(1, "");
    alert.emphasis = OverlayEmphasis::Alert;
    let data = row(&alert);
    assert_eq!(data.emphasis, 1);
    assert!(data.has_secondary);
    assert_eq!(raw(&data.secondary), "Pilot > raw 1");
    let clear = OverlayLine {
        emphasis: OverlayEmphasis::Clear,
        primary: vec![plain("clear")],
        ..OverlayLine::default()
    };
    let data = row(&clear);
    assert_eq!((data.emphasis, data.has_secondary), (2, false));
}

/// 第一次显示、追加、头部去掉、中间改：模型与消息逐行对齐；贴住底部时不计新消息。
#[test]
fn view_applies_diffs() {
    let view = view();
    let mut view = view.borrow_mut();
    // 第一次显示：整表建出 20 行，标题照填，列表不空所以没有说明。
    view.set_content(&content("intel:Pilot Alpha", 1..=20));
    assert_eq!(view.rows.row_count(), 20);
    assert_eq!(view.window().get_title_text(), "Intel · Pilot Alpha");
    assert_eq!(view.window().get_placeholder(), "");

    // 最旧的两条过期、新到三条，第 5 条的内容变了（例如人名核对的结果到达）。
    let mut next = content("intel:Pilot Alpha", 3..=23);
    next.lines[2] = line(5, " (resolved)");
    view.set_content(&next);
    assert_eq!(view.rows.row_count(), 21);
    assert_eq!(view.line(0).map(|l| l.id), Some(3));
    assert!(raw(&view.rows.row_data(2).unwrap().primary).ends_with("(resolved)"));
    assert!(raw(&view.rows.row_data(20).unwrap().primary).ends_with("message 23"));
    assert_eq!(view.scroll_state(), OverlayScrollState::INITIAL);
    assert!(view.window().get_pinned());
    assert_eq!(view.window().get_new_messages(), "");
}

/// 离开底部后新到的条数显示在新消息条上；点它回到底部并清零；换角色时回到初始状态。
#[test]
fn view_counts_unseen_messages() {
    let view = view();
    let mut view = view.borrow_mut();
    view.set_content(&content("intel:Pilot Alpha", 1..=30));
    // 往上翻了 400：离开底部，但还没有新消息，新消息条不出现。
    view.user_scrolled(400.0);
    assert!(!view.window().get_pinned());
    assert_eq!(view.window().get_new_messages(), "");

    view.set_content(&content("intel:Pilot Alpha", 1..=33));
    assert_eq!(view.scroll_state().unseen_count, 3);
    assert!(view.window().get_new_messages().contains('3'));

    // 点新消息条：回到底部，条数清零，新消息条消失。
    view.scroll_to_latest();
    assert_eq!(view.scroll_state(), OverlayScrollState::INITIAL);
    assert_eq!(view.window().get_new_messages(), "");

    view.user_scrolled(400.0);
    view.set_content(&content("intel:Pilot Alpha", 1..=34));
    // 换了角色：即使离开过底部、累计过条数，也整表替换并回到初始状态。
    view.set_content(&content("intel:Pilot Beta", 1..=2));
    assert_eq!(view.scroll_state(), OverlayScrollState::INITIAL);
    assert_eq!(view.rows.row_count(), 2);
}

/// 不贴底部时去掉头部的行：滚动位置挪回去掉的高度，正在看的内容停在原处。
#[test]
fn view_keeps_reading_position() {
    let view = view();
    let mut view = view.borrow_mut();
    view.set_content(&content("intel:Pilot Alpha", 1..=40));
    // 列表的行在第一次绘制时才建出来，之前读到的内容高度是 0；应用里窗口一直在绘制，没有这个问题。
    render();
    let total = view.window().get_content_height();
    let visible = view.window().get_visible_height();
    assert!(total > visible, "内容应比可见区域高");
    // 贴住底部：内容高度变化后由 Slint 的 changed 回调滚到底部。
    render();
    assert!((view.window().get_content_y() - (visible - total)).abs() < 0.5);
    // 停在中间往上翻看。
    view.window().set_content_y(-total / 2.0);
    view.user_scrolled(f64::from(total / 2.0));
    let before = view.window().get_content_y();
    // 最旧的四条过期：内容变矮了 removed，滚动位置同样往下挪 removed，屏幕上看到的那几行不动。
    view.set_content(&content("intel:Pilot Alpha", 5..=40));
    let removed = total - view.window().get_content_height();
    assert!(removed > 0.0);
    assert!((view.window().get_content_y() - (before + removed)).abs() < 0.5);
}

/// 说明：没有角色与还没有消息两种；状态行的文字与级别；换语言后文字跟着换。
#[test]
fn view_placeholder_status_and_language() {
    let view = view();
    let mut view = view.borrow_mut();
    let mut empty = content("intel:", []);
    empty.status = Some(OverlayStatus {
        text: "Chat logs not found".to_owned(),
        level: OverlayStatusLevel::Warning,
    });
    view.set_content(&empty);
    let english = view.window().get_placeholder();
    assert_eq!(english, eveo_l10n::overlay(AppLanguage::En).no_active_character());
    assert_eq!(view.window().get_status_text(), "Chat logs not found");
    assert_eq!(view.window().get_status_level(), 1);

    // 换成中文：不等下一次内容更新，说明立即换成中文。
    view.set_language(AppLanguage::Zh);
    assert_eq!(
        view.window().get_placeholder(),
        eveo_l10n::overlay(AppLanguage::Zh).no_active_character()
    );
    // 有角色但还没有消息：换成另一种说明；这份内容没有状态行，状态行清空。
    view.set_content(&content("intel:Pilot Alpha", []));
    assert_eq!(
        view.window().get_placeholder(),
        eveo_l10n::overlay(AppLanguage::Zh).empty_list()
    );
    assert_eq!(view.window().get_status_text(), "");
}
