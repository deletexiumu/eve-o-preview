// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗的一行：表里的 5 种阶段；多于一个频道时显示频道名；foreign_only 隐藏的两种情形；复制的文字。
// 说话人与频道名是虚构的。

use super::message_at;
use crate::model::{ChannelRef, TranslationSettings};
use crate::overlay::{OverlayEmphasis, OverlayLine, OverlaySpan, OverlaySpanStyle as S};
use crate::translation::presenter::{TranslationLineFormatting, line};
use crate::translation::{Phase, SkipReason, TranslationItem};

/// 测试用的格式器：时间写成秒数，状态词固定。
struct Stub;

impl TranslationLineFormatting for Stub {
    fn time(&self, utc: f64) -> String {
        format!("T{utc}")
    }
    fn pending(&self) -> String {
        "PENDING".to_owned()
    }
    fn failed(&self) -> String {
        "FAILED".to_owned()
    }
}

/// 设置：几个频道、是否显示原文、是否只显示翻译过的消息。
fn settings(channels: usize, show_original: bool, foreign_only: bool) -> TranslationSettings {
    TranslationSettings {
        channels: (0..channels)
            .map(|n| ChannelRef::new(&format!("chat{n}.Demo"), None))
            .collect(),
        show_original,
        foreign_only,
        ..TranslationSettings::default()
    }
}

/// 一个频道、显示原文、显示全部消息的设置。
fn default_settings() -> TranslationSettings {
    settings(1, true, false)
}

/// 一行：编号 5，消息「hola amigos」，时间 60。
fn row(phase: Phase, settings: &TranslationSettings) -> Option<OverlayLine> {
    let item = TranslationItem {
        id: 5,
        message: message_at("hola amigos", "Pilot Alpha", 60.0),
        phase,
    };
    line(&item, settings, &Stub)
}

/// 第一行开头的固定部分：时间、空格、说话人、冒号，再接上 rest。
fn head(rest: &[OverlaySpan]) -> Vec<OverlaySpan> {
    let mut spans = vec![
        OverlaySpan::new("T60", S::Dim),
        OverlaySpan::new(" ", S::Plain),
        OverlaySpan::new("Vex Oran", S::Speaker),
        OverlaySpan::new(": ", S::Dim),
    ];
    spans.extend_from_slice(rest);
    spans
}

/// 已翻译的阶段。
fn done(text: &str) -> Phase {
    Phase::Done {
        text: text.to_owned(),
        source_language: None,
    }
}

/// Done：译文用 Translated，显示原文时第二行是原文；替换过术语的 Skipped 同样有第二行。
#[test]
fn done_and_rendered_rows() {
    let done_row = row(done("hello friends"), &default_settings()).unwrap();
    assert_eq!(done_row.id, 5);
    assert_eq!(
        done_row.primary,
        head(&[OverlaySpan::new("hello friends", S::Translated)])
    );
    assert_eq!(done_row.secondary, vec![OverlaySpan::new("hola amigos", S::Dim)]);
    assert!(done_row.emphasis == OverlayEmphasis::None && done_row.links.is_empty());
    // 关掉「显示原文」：只有译文一行。
    let hidden = row(done("hello friends"), &settings(1, false, false)).unwrap();
    assert!(hidden.secondary.is_empty());

    // 只有术语的消息替换后显示，原文仍在第二行，方便对照。
    let rendered = Phase::Skipped(SkipReason::TermsOnly, Some("吉他 2".to_owned()));
    let rendered_row = row(rendered, &default_settings()).unwrap();
    assert_eq!(
        rendered_row.primary,
        head(&[OverlaySpan::new("吉他 2", S::Plain)])
    );
    assert_eq!(
        rendered_row.secondary,
        vec![OverlaySpan::new("hola amigos", S::Dim)]
    );
}

/// 没有替换的 Skipped 与 Off：原文用 Plain，没有第二行；Pending、InFlight 加「翻译中…」，Failed 加「未翻译」。
#[test]
fn plain_pending_and_failed_rows() {
    let original = OverlaySpan::new("hola amigos", S::Plain);
    // 本来就是目标语言、或不排队的旧消息：原样显示一行。
    for phase in [Phase::Skipped(SkipReason::SameLanguage, None), Phase::Off] {
        let plain = row(phase, &default_settings()).unwrap();
        assert_eq!(plain.primary, head(std::slice::from_ref(&original)));
        assert!(plain.secondary.is_empty());
    }
    // 排队与在途对用户来说都是「翻译中」。
    for phase in [Phase::Pending, Phase::InFlight] {
        let pending = row(phase, &default_settings()).unwrap();
        let expected = head(&[original.clone(), OverlaySpan::new(" PENDING", S::Pending)]);
        assert_eq!(pending.primary, expected);
        assert!(pending.secondary.is_empty());
    }
    let failed = row(Phase::Failed, &default_settings()).unwrap();
    assert_eq!(
        failed.primary.last(),
        Some(&OverlaySpan::new(" FAILED", S::Failed))
    );
    assert!(failed.secondary.is_empty());
}

/// 多于一个频道时，说话人前面加 [频道名]（Channel 样式）。
#[test]
fn channel_shown_when_several() {
    // 下标 2 是频道名，4 是说话人（中间隔一个空格）。
    let several = row(Phase::Off, &settings(2, true, false)).unwrap();
    assert_eq!(several.primary[2], OverlaySpan::new("[chat.Demo]", S::Channel));
    assert_eq!(several.primary[4], OverlaySpan::new("Vex Oran", S::Speaker));
    let one = row(Phase::Off, &default_settings()).unwrap();
    assert_eq!(one.primary[2], OverlaySpan::new("Vex Oran", S::Speaker));
}

/// foreign_only：已是目标语言与空消息不显示；只有术语的消息与译文照常显示。
#[test]
fn foreign_only_hides() {
    // 打开「只显示翻译过的消息」。
    let only = settings(1, true, true);
    assert!(row(Phase::Skipped(SkipReason::SameLanguage, None), &only).is_none());
    assert!(row(Phase::Skipped(SkipReason::Empty, None), &only).is_none());
    assert!(row(Phase::Skipped(SkipReason::TermsOnly, None), &only).is_some());
    assert!(row(done("x"), &only).is_some());
    assert!(
        row(
            Phase::Skipped(SkipReason::SameLanguage, None),
            &default_settings()
        )
        .is_some()
    );
}

/// 复制的文字：说话人与原文；有译文时另起一行。
#[test]
fn copy_text() {
    // 复制的文字不带时间与频道名。
    let copy = |phase| row(phase, &default_settings()).unwrap().copy_text;
    assert_eq!(copy(Phase::Off), "Vex Oran: hola amigos");
    assert_eq!(
        copy(done("hello friends")),
        "Vex Oran: hola amigos\nhello friends"
    );
    let rendered = Phase::Skipped(SkipReason::TermsOnly, Some("吉他".to_owned()));
    assert_eq!(copy(rendered), "Vex Oran: hola amigos\n吉他");
}
