// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗截图的示例内容：几条典型的预警消息，覆盖各种样式（时间的三档、安全等级、跳数、舰船、人名、数量、
// 安全与未见），以及一条红色强调、一条绿色强调的行。星系与角色名取自游戏里常见的地名与虚构的名字。

//! 浮窗截图的示例内容。

use eveo_core::overlay::{OverlayContent, OverlayEmphasis, OverlayLine, OverlaySpan, OverlaySpanStyle as S};

/// 一段文字。
fn span(text: &str, style: S) -> OverlaySpan {
    OverlaySpan::new(text, style)
}

/// 一条消息：第一行是要点，第二行是「说话人 > 原文」。
fn line(
    id: u64,
    primary: Vec<OverlaySpan>,
    speaker: &str,
    raw: &str,
    emphasis: OverlayEmphasis,
) -> OverlayLine {
    OverlayLine {
        id,
        primary,
        secondary: vec![span(speaker, S::Speaker), span(" > ", S::Dim), span(raw, S::Dim)],
        emphasis,
        copy_text: raw.to_owned(),
        links: Vec::new(),
    }
}

/// 预警浮窗的示例内容，最新的在最后。
///
/// 四条从旧到新：绿色的「安全」、两条普通消息（一条有数量与船型、一条在虫洞里算不出跳数），
/// 最后一条是 1 跳外 5 个敌对，红色强调。时间分别落在「较早」「近期」「刚刚」三档，颜色都能在图上看到。
pub(super) fn content() -> OverlayContent {
    let none = OverlayEmphasis::None;
    // 各部分之间的分隔符与呈现器一致：暗色的中点，两边各一个空格。
    let sep = || span(" · ", S::Dim);
    let lines = vec![
        line(
            1,
            vec![
                span("14m", S::AgeOld),
                sep(),
                span("Amamake", S::SystemLow),
                sep(),
                span("9j", S::JumpsFar),
                sep(),
                span("clear", S::Clear),
            ],
            "Scout Two",
            "Amamake clr",
            OverlayEmphasis::Clear,
        ),
        line(
            2,
            vec![
                span("4m", S::AgeRecent),
                sep(),
                span("Tama", S::SystemLow),
                sep(),
                span("4j", S::JumpsMid),
                sep(),
                span("2", S::Count),
                span(" ", S::Plain),
                span("Loki", S::Ship),
            ],
            "Kestrel Nine",
            "Tama gate 2x loki",
            none,
        ),
        line(
            3,
            vec![
                span("2m", S::AgeRecent),
                sep(),
                span("J105433", S::SystemUnknown),
                sep(),
                span("?j", S::JumpsUnknown),
                sep(),
                span("no visual", S::NoVisual),
            ],
            "Aria Voss",
            "J105433 nv",
            none,
        ),
        line(
            4,
            vec![
                span("38s", S::AgeFresh),
                sep(),
                span("Nourvukaiken", S::SystemLow),
                sep(),
                span("1j", S::JumpsNear),
                sep(),
                span("5", S::Count),
                span(" ", S::Plain),
                span("Sabre", S::Ship),
                span(", ", S::Dim),
                span("Hecate", S::Ship),
                sep(),
                span("Red Baron", S::Pilot),
            ],
            "Scout One",
            "Nourvukaiken 5 sabre hecate Red Baron",
            OverlayEmphasis::Alert,
        ),
    ];
    OverlayContent {
        context_key: "intel:Aria Voss".to_owned(),
        title: "Intel · Aria Voss".to_owned(),
        status: None,
        lines,
    }
}
