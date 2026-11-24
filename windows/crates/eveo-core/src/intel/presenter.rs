// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警浮窗每一行的内容，对应 macOS 的 IntelPresenter.swift（设计文档 6.7 节，6.9 节改了数量与人名两部分）。
// 界面文字由界面层实现 IntelLineFormatting 交进来，核心层不碰界面文字（多语言字符串在 eveo-l10n）。
//
// 一条情报（is_intel_like）的第一行，各部分之间隔一个空格：
// | 时间       | 不足 60 秒时向下取到 10 秒的倍数；不足 120 秒 AgeFresh，不足 300 秒 AgeRecent，其余 AgeOld |
// | 每个星系   | 名称加显示用的安全等级；≥0.5 SystemHigh，0.1～0.4 SystemLow，≤0.0 SystemNull，没有或虫洞 SystemUnknown |
// | 星系的跳数 | 跟在星系后面；alert_jumps>0 且不超过它 JumpsNear，不超过 2 倍 JumpsMid，更远 JumpsFar，其余 JumpsUnknown |
// | 数量       | segmenter::resolve 给出的 hostile_count 大于 0 时显示，Count 样式                          |
// | 舰船       | 名称；数量大于 1 时加「×数量」，Ship 样式                                                   |
// | 人名       | 查到的总是列出（Pilot）；未核对的只在不显示原文时列出（Pilot）；没查到的只在不显示原文时列出，加「?」（Dim） |
// | 用语       | Clear、NoVisual                                                                           |
// 相邻两个人名之间加「 · 」（Dim）：人名里有空格，只隔一个空格分不清。
// 第二行：显示原文时是「说话人: 原文」。不是情报的消息：第一行是时间、说话人与原文，没有第二行。
// emphasis：alert_jumps>0 且某个星系的跳数不超过它，并且消息里有舰船、人名或大于 0 的数量时 Alert；
// 否则 is_clear 时 Clear；否则在高亮距离内时 Alert；其余 None。有敌对的消息里夹着「安全」时，Alert 优先。
// copy_text：「[HH:mm:ss] 说话人 > 原文」，时间是日志里的 EVE 时间（UTC）。
// links：每个查到的、角色 ID 大于 0 的人名一项，指向 zKillboard 的角色页；地址里只有数字 ID。

//! 预警浮窗的行：把解析结果排成带样式的文字。

use std::collections::HashMap;

use super::feed::IntelItem;
use super::pilots::segmenter::{IntelPilot, PilotDirectory, PilotStatus, resolve};
use crate::chat_log::ChatMessage;
use crate::model::{AppLanguage, IntelSettings};
use crate::overlay::{OverlayEmphasis, OverlayLine, OverlayLink, OverlaySpan, OverlaySpanStyle};
use crate::static_data::jumps::{JumpDistance, distance};
use crate::static_data::matcher::TermKind;
use crate::static_data::{EveStaticData, SolarSystem, SpaceKind};

/// 不足这么多秒是「新」。
pub const FRESH_SECONDS: f64 = 120.0;
/// 不足这么多秒是「较新」。
pub const RECENT_SECONDS: f64 = 300.0;

/// 消息的新旧。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntelFreshness {
    /// 不足 120 秒。
    Fresh,
    /// 不足 300 秒。
    Recent,
    /// 更早。
    Old,
}

/// 预警行里随界面语言变的文字，由界面层用本地化字符串实现。
pub trait IntelLineFormatting {
    /// 多久以前，如「40 秒」「3 分钟」。
    fn age(&self, seconds: i64) -> String;
    /// 跳数。
    fn jumps(&self, distance: JumpDistance) -> String;
    /// 敌对数量；is_explicit 为假时显示成「约 ×N」。
    fn count(&self, value: i64, is_explicit: bool) -> String;
    /// 「安全」。
    fn clear(&self) -> String;
    /// 「未见」。
    fn no_visual(&self) -> String;
}

/// 生成一行时用到的上下文。都是借用：控制器每次刷新建一个，生成完整个浮窗就丢掉。
#[derive(Debug, Clone, Copy)]
pub struct IntelPresentationContext<'a> {
    /// 从出发点算出的跳数表；出发点未知时为 None（跳数显示成「?」）。
    pub distances: Option<&'a HashMap<i64, i64>>,
    /// 预警设置。
    pub settings: &'a IntelSettings,
    /// 舰船与星系名的显示语言（界面语言）。
    pub language: AppLanguage,
    /// 当前时刻（墙上时钟）。
    pub now: f64,
    /// 人名核对的结果；开关关闭时是空目录（6.9 节）。
    pub pilots: &'a PilotDirectory,
}

/// 按消息的年龄分档。
pub fn freshness(age: f64) -> IntelFreshness {
    if age < FRESH_SECONDS {
        IntelFreshness::Fresh
    } else if age < RECENT_SECONDS {
        IntelFreshness::Recent
    } else {
        IntelFreshness::Old
    }
}

/// 一条消息的一行。
pub fn line(
    item: &IntelItem,
    context: &IntelPresentationContext<'_>,
    data: &EveStaticData,
    formatter: &dyn IntelLineFormatting,
) -> OverlayLine {
    let report = &item.report;
    // 闲聊、问话等不是情报的消息也显示（频道里的上下文有用），但不排星系、跳数这些部分。
    if !report.is_intel_like() {
        return plain_line(item, context.now, formatter);
    }
    let settings = context.settings;
    // 人名与数量按核对结果重算；目录为空时与解析结果相同。
    let resolved = resolve(report, context.pilots);
    // 每一部分是一组段；部分之间插一个空格，部分内部（如几个人名）不插。
    let mut parts: Vec<Vec<OverlaySpan>> = vec![vec![age_span(item, context.now, formatter)]];
    // 任何一个星系在高亮距离以内就算「近」；一条消息常同时提到几个星系（如「Jita -> Perimeter」）。
    let mut is_alert = false;
    for &system_id in &report.system_ids {
        // 星图数据里没有的星系（理论上不会发生，解析时就是用这份数据认出的）跳过。
        let Some(system) = data.system(system_id) else {
            continue;
        };
        let jump = distance(system_id, context.distances, settings.max_jumps, data);
        if let JumpDistance::Jumps(jumps) = jump
            && settings.alert_jumps > 0
            && jumps <= settings.alert_jumps
        {
            is_alert = true;
        }
        parts.push(vec![system_span(system, context.language)]);
        parts.push(vec![OverlaySpan::new(
            formatter.jumps(jump),
            jump_style(jump, settings.alert_jumps),
        )]);
    }
    if let Some(count) = resolved.hostile_count
        && count > 0
    {
        parts.push(vec![OverlaySpan::new(
            formatter.count(count, resolved.count_is_explicit),
            OverlaySpanStyle::Count,
        )]);
    }
    // 舰船按出现顺序列出，同一种船写了两次就列两次：消息里分开写通常是两拨人。
    for mention in &report.ships {
        let Some(name) = ship_name(mention.kind, data, context.language) else {
            continue;
        };
        let text = if mention.count > 1 {
            format!("{name}×{}", mention.count)
        } else {
            name.to_owned()
        };
        parts.push(vec![OverlaySpan::new(text, OverlaySpanStyle::Ship)]);
    }
    let pilots = pilot_spans(&resolved.pilots, settings.show_original);
    if !pilots.is_empty() {
        parts.push(pilots);
    }
    if report.is_clear {
        parts.push(vec![OverlaySpan::new(formatter.clear(), OverlaySpanStyle::Clear)]);
    }
    if report.is_no_visual {
        parts.push(vec![OverlaySpan::new(
            formatter.no_visual(),
            OverlaySpanStyle::NoVisual,
        )]);
    }

    // 拼第一行：部分之间插 Plain 空格。空格单独成段，界面层不必猜哪里该留空。
    let mut primary = Vec::new();
    for (index, part) in parts.into_iter().enumerate() {
        if index > 0 {
            primary.push(OverlaySpan::new(" ", OverlaySpanStyle::Plain));
        }
        primary.extend(part);
    }
    let message = &item.message;
    // 第二行是原文：解析难免出错，原文让用户能自己核对；关掉后浮窗更紧凑。
    let secondary = if settings.show_original {
        vec![
            OverlaySpan::new(message.speaker.as_str(), OverlaySpanStyle::Speaker),
            OverlaySpan::new(format!(": {}", message.text), OverlaySpanStyle::Dim),
        ]
    } else {
        Vec::new()
    };
    // 「有敌对」：提到了船、人名或大于 0 的数量；只有星系与「安全」的消息不算。
    let has_hostiles =
        !report.ships.is_empty() || !resolved.pilots.is_empty() || resolved.hostile_count.unwrap_or(0) > 0;
    // 只给查到的、ID 为正的角色出链接：ID 0 是演示模式的假核对服务，没有真实的角色页。
    let links = resolved
        .pilots
        .iter()
        .filter_map(|pilot| match pilot.status {
            PilotStatus::Matched(id) if id > 0 => Some(OverlayLink {
                title: format!("{} · zKillboard", pilot.name),
                url: format!("https://zkillboard.com/character/{id}/"),
            }),
            _ => None,
        })
        .collect();
    OverlayLine {
        id: item.id,
        primary,
        secondary,
        emphasis: emphasis(report.is_clear, is_alert, has_hostiles),
        copy_text: copy_text(message),
        links,
    }
}

/// 一行的强调：在高亮距离内且有敌对（舰船、人名或数量）时 Alert 优先于 Clear；否则 Clear 优先于 Alert。
/// 「Perimeter Rifter clr」多半是「门口那艘 Rifter 走了没」之类的口语，红色更安全。
pub fn emphasis(is_clear: bool, is_alert: bool, has_hostiles: bool) -> OverlayEmphasis {
    if is_alert && has_hostiles {
        OverlayEmphasis::Alert
    } else if is_clear {
        OverlayEmphasis::Clear
    } else if is_alert {
        OverlayEmphasis::Alert
    } else {
        OverlayEmphasis::None
    }
}

/// 不是情报的消息（或没有星图数据时）的一行：时间、说话人与原文，原文用 Plain 样式，没有第二行。
pub fn plain_line(item: &IntelItem, now: f64, formatter: &dyn IntelLineFormatting) -> OverlayLine {
    let message = &item.message;
    OverlayLine {
        id: item.id,
        primary: vec![
            age_span(item, now, formatter),
            OverlaySpan::new(" ", OverlaySpanStyle::Plain),
            OverlaySpan::new(message.speaker.as_str(), OverlaySpanStyle::Speaker),
            OverlaySpan::new(format!(": {}", message.text), OverlaySpanStyle::Plain),
        ],
        copy_text: copy_text(message),
        ..OverlayLine::default()
    }
}

/// 下一次要按时间刷新的时刻：有不足 60 秒的消息时 now + 10（时间按 10 秒一档变）；否则有消息时 now + 30；
/// 没有消息时 None（不必定时刷新）。
pub fn next_refresh<'a>(items: impl IntoIterator<Item = &'a IntelItem>, now: f64) -> Option<f64> {
    // 只要有一条不足 60 秒就可以提前返回；any 记下是否至少有一条消息。
    let mut any = false;
    for item in items {
        if now - item.message.time < 60.0 {
            return Some(now + 10.0);
        }
        any = true;
    }
    any.then_some(now + 30.0)
}

/// 时间：不足 60 秒时向下取到 10 秒的倍数，免得每秒都要重画。钟面差异造成的负年龄按 0 算。
pub(crate) fn age_span(item: &IntelItem, now: f64, formatter: &dyn IntelLineFormatting) -> OverlaySpan {
    let age = (now - item.message.time).max(0.0);
    let whole = if age.is_finite() { age.min(1e9) as i64 } else { 0 };
    // 60 秒以上原样交给界面层，由它换成「N 分钟」；分档在这里做，界面层只管措辞。
    let seconds = if whole < 60 { whole / 10 * 10 } else { whole };
    let style = match freshness(age) {
        IntelFreshness::Fresh => OverlaySpanStyle::AgeFresh,
        IntelFreshness::Recent => OverlaySpanStyle::AgeRecent,
        IntelFreshness::Old => OverlaySpanStyle::AgeOld,
    };
    OverlaySpan::new(formatter.age(seconds), style)
}

/// 星系：名称加显示用的安全等级，保留一位小数（虫洞星系不加，它们的安全等级没有意义）。
pub(crate) fn system_span(system: &SolarSystem, language: AppLanguage) -> OverlaySpan {
    // 名称取界面语言；中文界面显示「吉他」这类官方译名，没有译名时回退英文。
    let name = system.name_in(language);
    match (system.kind, system.display_security()) {
        (SpaceKind::Known, Some(security)) => {
            let style = if security >= 0.5 {
                OverlaySpanStyle::SystemHigh
            } else if security > 0.0 {
                OverlaySpanStyle::SystemLow
            } else {
                OverlaySpanStyle::SystemNull
            };
            OverlaySpan::new(format!("{name} {security:.1}"), style)
        }
        _ => OverlaySpan::new(name, OverlaySpanStyle::SystemUnknown),
    }
}

/// 跳数的样式：算得出时按高亮距离分三档；高亮关闭（0）时都是 JumpsFar，不吸引注意。
pub(crate) fn jump_style(jump: JumpDistance, alert_jumps: i64) -> OverlaySpanStyle {
    let JumpDistance::Jumps(jumps) = jump else {
        return OverlaySpanStyle::JumpsUnknown;
    };
    if alert_jumps <= 0 {
        OverlaySpanStyle::JumpsFar
    } else if jumps <= alert_jumps {
        OverlaySpanStyle::JumpsNear
    } else if jumps <= alert_jumps * 2 {
        OverlaySpanStyle::JumpsMid
    } else {
        OverlaySpanStyle::JumpsFar
    }
}

/// 舰船或舰船分组在界面语言里的名称；其他种类的术语没有。
fn ship_name(kind: TermKind, data: &EveStaticData, language: AppLanguage) -> Option<&str> {
    match kind {
        TermKind::Ship(id) => data.ship(id).map(|ship| ship.name_in(language)),
        TermKind::ShipGroup(id) => data.ship_group(id).map(|group| group.name_in(language)),
        _ => None,
    }
}

/// 人名：查到的总是列出；未核对与没查到的只在不显示原文时列出（显示原文时原文里已有，不重复），
/// 没查到的加「?」并用 Dim。人名之间隔「 · 」。
pub(crate) fn pilot_spans(pilots: &[IntelPilot], show_original: bool) -> Vec<OverlaySpan> {
    // 被跳过的人名不留分隔符：只在已有段之后、追加下一个人名之前插「 · 」。
    let mut spans = Vec::new();
    for pilot in pilots {
        let span = match pilot.status {
            PilotStatus::Matched(_) => OverlaySpan::new(pilot.name.as_str(), OverlaySpanStyle::Pilot),
            PilotStatus::Unchecked if !show_original => {
                OverlaySpan::new(pilot.name.as_str(), OverlaySpanStyle::Pilot)
            }
            PilotStatus::NotFound if !show_original => {
                OverlaySpan::new(format!("{}?", pilot.name), OverlaySpanStyle::Dim)
            }
            _ => continue,
        };
        if !spans.is_empty() {
            spans.push(OverlaySpan::new(" · ", OverlaySpanStyle::Dim));
        }
        spans.push(span);
    }
    spans
}

/// 右键「复制」的文字：「[HH:mm:ss] 说话人 > 原文」，时间是 UTC（与游戏内聊天的时间一致）。
pub(crate) fn copy_text(message: &ChatMessage) -> String {
    let seconds = if message.time.is_finite() && message.time.abs() < 1e15 {
        message.time.floor() as i64
    } else {
        0
    };
    // rem_euclid 让 1970 年以前（负数）的时刻也落在 0～86399。
    let day = seconds.rem_euclid(86_400);
    format!(
        "[{:02}:{:02}:{:02}] {} > {}",
        day / 3_600,
        day / 60 % 60,
        day % 60,
        message.speaker,
        message.text
    )
}
