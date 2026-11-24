// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译浮窗的一行，对应 macOS 的 TranslationPresenter.swift（设计文档 7.10 节）：
// | 阶段                      | 第一行                                   | 第二行                       |
// | Done                      | 时间、频道、说话人、译文（Translated）    | show_original 时是原文（Dim）|
// | Skipped，有替换后的文字   | 时间、频道、说话人、替换后的文字（Plain） | show_original 时是原文（Dim）|
// | Skipped 无替换；Off       | 时间、频道、说话人、原文（Plain）         | 无                           |
// | Pending、InFlight         | 同上，后面加「翻译中…」（Pending）        | 无                           |
// | Failed                    | 同上，后面加「未翻译」（Failed）          | 无                           |
// 频道名只在翻译频道多于一个时显示。foreign_only 为真时，已是目标语言与空消息不显示。
// 时间与两个状态词由应用的格式器给出（界面语言），核心里不含界面文字。

//! 翻译条目到浮窗行的转换。

use super::{Phase, SkipReason, TranslationItem};
use crate::model::TranslationSettings;
use crate::overlay::{OverlayLine, OverlaySpan, OverlaySpanStyle};

/// 翻译浮窗的格式器：时间与两个状态词。
pub trait TranslationLineFormatting {
    /// EVE 时间（UTC）的 HH:mm。
    fn time(&self, utc: f64) -> String;
    /// 「翻译中…」。
    fn pending(&self) -> String;
    /// 「未翻译」。
    fn failed(&self) -> String;
}

/// 一条的显示；foreign_only 隐藏的条目返回 None。
pub fn line(
    item: &TranslationItem,
    settings: &TranslationSettings,
    formatter: &dyn TranslationLineFormatting,
) -> Option<OverlayLine> {
    let message = &item.message;
    // 只显示翻译过的消息时，本来就是目标语言的与空消息不占一行；只有术语的消息照常显示。
    if settings.foreign_only
        && matches!(
            item.phase,
            Phase::Skipped(SkipReason::SameLanguage | SkipReason::Empty, _)
        )
    {
        return None;
    }
    let mut primary = vec![
        OverlaySpan::new(formatter.time(message.time), OverlaySpanStyle::Dim),
        OverlaySpan::new(" ", OverlaySpanStyle::Plain),
    ];
    // 只翻译一个频道时频道名是多余的，省下宽度给正文。
    if settings.channels.len() > 1 {
        primary.push(OverlaySpan::new(
            format!("[{}]", message.channel_name),
            OverlaySpanStyle::Channel,
        ));
        primary.push(OverlaySpan::new(" ", OverlaySpanStyle::Plain));
    }
    primary.push(OverlaySpan::new(
        message.speaker.clone(),
        OverlaySpanStyle::Speaker,
    ));
    primary.push(OverlaySpan::new(": ", OverlaySpanStyle::Dim));

    let mut secondary = Vec::new();
    let mut translation: Option<&str> = None;
    let original = || vec![OverlaySpan::new(message.text.clone(), OverlaySpanStyle::Dim)];
    let plain = || OverlaySpan::new(message.text.clone(), OverlaySpanStyle::Plain);
    match &item.phase {
        Phase::Done { text, .. } => {
            primary.push(OverlaySpan::new(text.clone(), OverlaySpanStyle::Translated));
            translation = Some(text);
            if settings.show_original {
                secondary = original();
            }
        }
        Phase::Skipped(_, Some(rendered)) => {
            primary.push(OverlaySpan::new(rendered.clone(), OverlaySpanStyle::Plain));
            translation = Some(rendered);
            if settings.show_original {
                secondary = original();
            }
        }
        Phase::Skipped(_, None) | Phase::Off => primary.push(plain()),
        Phase::Pending | Phase::InFlight => {
            primary.push(plain());
            primary.push(OverlaySpan::new(
                format!(" {}", formatter.pending()),
                OverlaySpanStyle::Pending,
            ));
        }
        Phase::Failed => {
            primary.push(plain());
            primary.push(OverlaySpan::new(
                format!(" {}", formatter.failed()),
                OverlaySpanStyle::Failed,
            ));
        }
    }
    // 复制的文字：说话人与原文；有译文（或术语替换后的文字）时另起一行。
    let mut copy_text = format!("{}: {}", message.speaker, message.text);
    if let Some(translation) = translation {
        copy_text.push('\n');
        copy_text.push_str(translation);
    }
    Some(OverlayLine {
        id: item.id,
        primary,
        secondary,
        copy_text,
        ..OverlayLine::default()
    })
}
