// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布说明的用例，移植 macOS 的 ReleaseNotesTests：按界面语言取段落、去掉折叠标签、回退到英文与全文、
// CRLF、标记的写法，以及 `blocks` 表的每种行。另用仓库里真实的 docs/release-notes/macos/v1.0.0.md 核对一遍
// （Windows 版的说明格式相同）。

use super::*;
use crate::support::StringEnum;
use ReleaseNotesBlock::{Bullet, Code, Heading, Numbered, Paragraph};

/// 8.2 节格式的完整样例：英文在前，其余 7 种语言各一个可折叠的块。
const SAMPLE: &str = "<!-- lang:en -->\n## What's new\n\n- English item.\n<!-- /lang:en -->\n\n\
<!-- lang:zh -->\n<details><summary>简体中文</summary>\n\n## 新内容\n\n- 中文条目。\n\n</details>\n<!-- /lang:zh -->\n\n\
<!-- lang:ja -->\n<details><summary>日本語</summary>\n\n## 新機能\n\n- 日本語の項目。\n\n</details>\n<!-- /lang:ja -->\n\n\
<!-- lang:ko -->\n<details><summary>한국어</summary>\n\n## 새로운 기능\n\n- 한국어 항목.\n\n</details>\n<!-- /lang:ko -->\n\n\
<!-- lang:ru -->\n<details><summary>Русский</summary>\n\n## Что нового\n\n- Русский пункт.\n\n</details>\n<!-- /lang:ru -->\n\n\
<!-- lang:fr -->\n<details><summary>Français</summary>\n\n## Nouveautés\n\n- Élément en français.\n\n</details>\n<!-- /lang:fr -->\n\n\
<!-- lang:de -->\n<details><summary>Deutsch</summary>\n\n## Neu\n\n- Deutscher Eintrag.\n\n</details>\n<!-- /lang:de -->\n\n\
<!-- lang:es -->\n<details><summary>Español</summary>\n\n## Novedades\n\n- Elemento en español.\n\n</details>\n<!-- /lang:es -->";

/// 各语言应取到的正文。
fn expected(language: AppLanguage) -> &'static str {
    match language {
        AppLanguage::En => "## What's new\n\n- English item.",
        AppLanguage::Zh => "## 新内容\n\n- 中文条目。",
        AppLanguage::Ja => "## 新機能\n\n- 日本語の項目。",
        AppLanguage::Ko => "## 새로운 기능\n\n- 한국어 항목.",
        AppLanguage::Ru => "## Что нового\n\n- Русский пункт.",
        AppLanguage::Fr => "## Nouveautés\n\n- Élément en français.",
        AppLanguage::De => "## Neu\n\n- Deutscher Eintrag.",
        AppLanguage::Es => "## Novedades\n\n- Elemento en español.",
    }
}

/// 不应留下的标签与标记。
const LEFTOVERS: [&str; 6] = [
    "<details",
    "</details>",
    "<summary",
    "</summary>",
    "lang:",
    "<!--",
];

/// 完整样例按每种界面语言取到各自的块，不留标签与标记；CRLF 的正文结果相同且没有回车。
#[test]
fn picks_each_language() {
    // 同一份正文的 CRLF 版本，每种语言也取一次。
    let crlf = SAMPLE.replace('\n', "\r\n");
    for &language in AppLanguage::ALL {
        let text = section(language, SAMPLE);
        assert_eq!(text, expected(language), "{language:?}");
        for leftover in LEFTOVERS {
            assert!(!text.contains(leftover));
        }
        let from_crlf = section(language, &crlf);
        assert_eq!(from_crlf, expected(language));
        assert!(!from_crlf.contains('\r'));
    }
}

/// 缺界面语言的块时取英文的块。
#[test]
fn missing_language_falls_back_to_english() {
    let body = SAMPLE
        .replace("<!-- lang:ko -->", "")
        .replace("<!-- /lang:ko -->", "");
    assert_eq!(section(AppLanguage::Ko, &body), expected(AppLanguage::En));
    assert_eq!(section(AppLanguage::Zh, &body), expected(AppLanguage::Zh));
}

/// 没有任何标记时返回全文，只去掉首尾空白行；只有非英文的块、界面语言又不是它时也返回全文。
#[test]
fn whole_body_fallbacks() {
    let body = "\n\nFirst release.\n\n## Install\n\n1. Download.\n\n";
    for &language in AppLanguage::ALL {
        assert_eq!(
            section(language, body),
            "First release.\n\n## Install\n\n1. Download."
        );
    }
    // 只有中文块：日文界面两块都找不到，返回全文；中文界面取中文块。
    let zh_only = "<!-- lang:zh -->\n中文\n<!-- /lang:zh -->";
    assert_eq!(section(AppLanguage::Ja, zh_only), zh_only);
    assert_eq!(section(AppLanguage::Zh, zh_only), "中文");
}

/// 标记里多空格、少空格、大写都能认出；代码不区分大小写。
#[test]
fn lenient_markers() {
    let body = "<!--LANG:EN-->\nEnglish.\n<!--   /Lang:En   -->\n<!--  lang : ZH  -->\n\
<DETAILS><Summary>简体中文</SUMMARY>\n\n中文。\n\n</Details>\n<!--/lang:zh-->";
    assert_eq!(section(AppLanguage::En, body), "English.");
    assert_eq!(section(AppLanguage::Zh, body), "中文。");
    assert_eq!(section(AppLanguage::Ru, body), "English.");
}

/// 只取开始标记之后的第一个结束标记；别的 HTML 注释不算标记。
#[test]
fn first_closing_marker_and_other_comments() {
    let body =
        "<!-- note -->\n<!-- lang:en -->\nA <!-- inline --> B\n<!-- /lang:en -->\nC\n<!-- /lang:en -->";
    assert_eq!(section(AppLanguage::En, body), "A <!-- inline --> B");
}

/// 没有结束标记的块、内容为空的块都按不存在处理，改取英文。
#[test]
fn unclosed_or_empty_blocks() {
    let unclosed = "<!-- lang:en -->\nEnglish.\n<!-- /lang:en -->\n<!-- lang:ja -->\n日本語";
    assert_eq!(section(AppLanguage::Ja, unclosed), "English.");
    let empty = "<!-- lang:en -->\nEnglish.\n<!-- /lang:en -->\n<!-- lang:ru -->\n<details><summary>Русский</summary>\n\n</details>\n<!-- /lang:ru -->";
    assert_eq!(section(AppLanguage::Ru, empty), "English.");
}

/// 只有以 `<details>` 开头时才去掉折叠标签；去掉最后一个 `</details>`；没有 `</summary>` 时只去掉开头的标签。
#[test]
fn details_rules() {
    let middle = "<!-- lang:en -->\nSee <details> below.\n</details>\n<!-- /lang:en -->";
    assert_eq!(
        section(AppLanguage::En, middle),
        "See <details> below.\n</details>"
    );
    let nested = "<!-- lang:zh -->\n<details open><summary>中文</summary>\n\n<details>x</details>\n\n</details>\n<!-- /lang:zh -->";
    assert_eq!(section(AppLanguage::Zh, nested), "<details>x</details>");
    let no_summary = "<!-- lang:zh -->\n<details>\n中文\n</details>\n<!-- /lang:zh -->";
    assert_eq!(section(AppLanguage::Zh, no_summary), "中文");
}

/// 仓库里真实的 v1.0.0 说明：每种语言取到自己的块，不留标签与标记，开头是该语言的正文，能切出块。
#[test]
fn repository_notes() {
    let notes = include_str!("../../../../../docs/release-notes/macos/v1.0.0.md");
    for &language in AppLanguage::ALL {
        let text = section(language, notes);
        for leftover in LEFTOVERS {
            assert!(!text.contains(leftover));
        }
        let opening = match language {
            AppLanguage::Zh => "EVE-O Preview for macOS 的首个正式版",
            AppLanguage::Ja => "EVE-O Preview for macOS の最初のリリース",
            AppLanguage::Ko => "EVE-O Preview for macOS의 첫 정식 릴리스",
            AppLanguage::Ru => "Первый выпуск EVE-O Preview for macOS",
            // 1.0.0 的说明没有法、德、西文的块，这三种语言退回英文的块。
            _ => "First release of EVE-O Preview for macOS",
        };
        assert!(text.starts_with(opening), "{language:?}");
        assert!(!blocks(&text).is_empty());
    }
    // 英文块切出的结构：有「Highlights」二级标题、顶层列表与第 3 步的编号。
    let english = blocks(&section(AppLanguage::En, notes));
    assert!(english.contains(&Heading {
        level: 2,
        text: "Highlights".into()
    }));
    assert!(english.iter().any(|b| matches!(b, Bullet { depth: 0, .. })));
    assert!(english.iter().any(|b| matches!(b, Numbered { number: 3, .. })));
    // 去掉全部标记后，任何语言都返回全文。
    let stripped: Vec<&str> = notes
        .split('\n')
        .filter(|line| !line.starts_with("<!-- lang:") && !line.starts_with("<!-- /lang:"))
        .collect();
    let stripped = stripped.join("\n");
    assert_eq!(section(AppLanguage::Ja, &stripped), stripped.trim());
}

/// 表里的每种行。
#[test]
fn each_line_kind() {
    let markdown = "# Title\n###### Six\n- dash\n* star\n+ plus\n  - nested\n    - deeper\n1. one\n12. twelve\n```\nlet x = 1\n```\nPlain line.";
    // 无序列表的项，写起来短一些。
    let bullet = |depth, text: &str| Bullet {
        depth,
        text: text.into(),
    };
    assert_eq!(
        blocks(markdown),
        [
            Heading {
                level: 1,
                text: "Title".into()
            },
            Heading {
                level: 6,
                text: "Six".into()
            },
            bullet(0, "dash"),
            bullet(0, "star"),
            bullet(0, "plus"),
            bullet(1, "nested"),
            bullet(2, "deeper"),
            Numbered {
                number: 1,
                text: "one".into()
            },
            Numbered {
                number: 12,
                text: "twelve".into()
            },
            Code("let x = 1".into()),
            Paragraph("Plain line.".into()),
        ]
    );
}

/// 段落合并、代码块保留内容、没有结束的代码块、CRLF 与空输入。
#[test]
fn paragraphs_and_code() {
    assert_eq!(
        blocks("First line\n   second line  \n\nNew paragraph\n- item\nafter item"),
        [
            Paragraph("First line second line".into()),
            Paragraph("New paragraph".into()),
            Bullet {
                depth: 0,
                text: "item".into()
            },
            Paragraph("after item".into()),
        ]
    );
    assert_eq!(
        blocks("```swift\n# not a heading\n- not a bullet\n\n  indented\n```\n# Real"),
        [
            Code("# not a heading\n- not a bullet\n\n  indented".into()),
            Heading {
                level: 1,
                text: "Real".into()
            },
        ]
    );
    assert_eq!(
        blocks("Intro\n```\na\nb"),
        [Paragraph("Intro".into()), Code("a\nb".into())]
    );
    // CRLF 与 LF 切出的结果相同；空正文与只有空白的正文没有块。
    let lf = "## Head\n\n- a\n- b\n\ntext\nmore";
    assert_eq!(blocks(&lf.replace('\n', "\r\n")), blocks(lf));
    assert!(blocks("").is_empty());
    assert!(blocks("\n  \n\n").is_empty());
    assert_eq!(section(AppLanguage::En, ""), "");
}

/// 不算标题或列表的写法都是普通段落。
#[test]
fn lookalikes_are_plain_paragraphs() {
    for line in [
        "#tag",
        "####### seven",
        "**bold** start",
        "-dash",
        "--- rule",
        "1) paren",
        "2024.",
        "v1.1.0 notes",
        "99999999999999999999. huge",
    ] {
        assert_eq!(blocks(line), [Paragraph(line.into())], "{line}");
    }
}
