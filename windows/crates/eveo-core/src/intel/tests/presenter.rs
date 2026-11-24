// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警行，对应 macOS 的 IntelPresenterTests（6.7 节、6.9 节）。说话人与人名是虚构的；文字由固定输出的
// FixedFormatter 给出（年龄写成「Ns」，跳数写成「Nj」），便于逐段比较。星系与舰船取自星图数据的夹具。

use std::collections::HashMap;

use crate::chat_log::ChatMessage;
use crate::intel::feed::IntelItem;
use crate::intel::parser::parse_with;
use crate::intel::pilots::segmenter::{PilotDirectory, combinations};
use crate::intel::pilots::{PilotLookupOutcome, key};
use crate::intel::presenter::{
    IntelFreshness, IntelLineFormatting, IntelPresentationContext, emphasis, freshness, line, next_refresh,
};
use crate::model::{AppLanguage, IntelSettings};
use crate::overlay::{OverlayEmphasis, OverlayLine, OverlayLink, OverlaySpan, OverlaySpanStyle as S};
use crate::static_data::EveStaticData;
use crate::static_data::jumps::{JumpDistance, distances};
use crate::static_data::tests::{JITA, data};

/// 固定输出的文字。
struct FixedFormatter;

impl IntelLineFormatting for FixedFormatter {
    fn age(&self, seconds: i64) -> String {
        format!("{seconds}s")
    }
    fn jumps(&self, distance: JumpDistance) -> String {
        match distance {
            JumpDistance::Jumps(count) => format!("{count}j"),
            JumpDistance::Beyond(limit) => format!(">{limit}j"),
            JumpDistance::Unreachable => "nogate".into(),
            JumpDistance::UnknownOrigin => "?".into(),
        }
    }
    fn count(&self, value: i64, is_explicit: bool) -> String {
        if is_explicit {
            format!("×{value}")
        } else {
            format!("~×{value}")
        }
    }
    fn clear(&self) -> String {
        "CLR".into()
    }
    fn no_visual(&self) -> String {
        "NV".into()
    }
}

/// 消息时间（1970-01-12 13:46:40 UTC）；上下文的 now 默认比它晚 45 秒。
const MESSAGE_TIME: f64 = 1_000_000.0;

/// 生成一行用到的选项，每个用例只改需要的几项。
struct Options {
    /// 是否显示原文。
    show_original: bool,
    /// 高亮距离。
    alert_jumps: i64,
    /// 出发星系；None 表示不知道位置。
    origin: Option<i64>,
    /// now 比消息晚几秒。
    age: f64,
    /// 界面语言。
    language: AppLanguage,
    /// 人名核对结果。
    pilots: PilotDirectory,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            show_original: true,
            alert_jumps: 5,
            origin: Some(JITA),
            age: 45.0,
            language: AppLanguage::En,
            pilots: PilotDirectory::default(),
        }
    }
}

/// 测试用的环境：夹具的星图数据。
struct Fixture {
    /// 夹具的星图数据。
    data: EveStaticData,
}

impl Fixture {
    /// 读夹具。
    fn new() -> Self {
        Self { data: data() }
    }

    /// 解析一条消息放进缓冲项（说话人 Mira Voss）。
    fn item(&self, text: &str, time: f64) -> IntelItem {
        let message = ChatMessage {
            listener: "Kael Doran".into(),
            channel_id: "player_00".into(),
            channel_name: "intel.Demo".into(),
            time,
            speaker: "Mira Voss".into(),
            text: text.into(),
            is_backfill: false,
        };
        IntelItem {
            id: 1,
            report: parse_with(text, &self.data),
            message,
        }
    }

    /// 用选项生成一行。
    fn line_with(&self, text: &str, options: &Options) -> OverlayLine {
        // 其余设置（跳数上限 15 等）取默认值，与用户第一次打开预警时相同。
        let settings = IntelSettings {
            show_original: options.show_original,
            alert_jumps: options.alert_jumps,
            ..IntelSettings::default()
        };
        // 跳数表由控制器在位置变化时算好；这里每行算一次，夹具很小，不影响测试速度。
        let table = options
            .origin
            .map(|origin| distances(origin, settings.max_jumps, &self.data));
        let context = IntelPresentationContext {
            distances: table.as_ref(),
            settings: &settings,
            language: options.language,
            now: MESSAGE_TIME + options.age,
            pilots: &options.pilots,
        };
        line(
            &self.item(text, MESSAGE_TIME),
            &context,
            &self.data,
            &FixedFormatter,
        )
    }

    /// 默认选项生成一行。
    fn line(&self, text: &str) -> OverlayLine {
        self.line_with(text, &Options::default())
    }
}

/// 去掉分隔用的空格，只看有内容的段。
fn spans(line: &OverlayLine) -> Vec<OverlaySpan> {
    line.primary.iter().filter(|s| s.text != " ").cloned().collect()
}

/// 只看各段的文字。
fn texts(line: &OverlayLine) -> Vec<String> {
    spans(line).into_iter().map(|s| s.text).collect()
}

/// 段的简写。
fn span(text: &str, style: S) -> OverlaySpan {
    OverlaySpan::new(text, style)
}

/// 一条情报的各部分与样式；第二行是说话人与原文；复制文字用 UTC 时间。
#[test]
fn intel_line_parts() {
    let fixture = Fixture::new();
    // Hek 离 Jita 4 跳，在默认高亮距离 5 以内；3x 是前置数量，归给后面的 Naga。
    let value = fixture.line("Hek* 3x Naga");
    let expected = [
        span("40s", S::AgeFresh),
        span("Hek 0.8", S::SystemHigh),
        span("4j", S::JumpsNear),
        span("×3", S::Count),
        span("Naga×3", S::Ship),
    ];
    assert_eq!(spans(&value), expected);
    // 各部分之间的分隔是一个 Plain 空格，spans 把它们滤掉了，这里单独核对一次。
    assert_eq!(value.primary[1], span(" ", S::Plain));
    assert_eq!(
        value.secondary,
        [span("Mira Voss", S::Speaker), span(": Hek* 3x Naga", S::Dim)]
    );
    assert_eq!(value.emphasis, OverlayEmphasis::Alert);
    // 1,000,000 秒是 11 天又 49,600 秒，即 13:46:40。
    assert_eq!(value.copy_text, "[13:46:40] Mira Voss > Hek* 3x Naga");
    assert!(value.links.is_empty());
}

/// 3 档新旧；不足 60 秒时向下取到 10 秒。
#[test]
fn freshness_bands() {
    assert_eq!(freshness(119.0), IntelFreshness::Fresh);
    assert_eq!(freshness(120.0), IntelFreshness::Recent);
    assert_eq!(freshness(299.0), IntelFreshness::Recent);
    assert_eq!(freshness(300.0), IntelFreshness::Old);
    let fixture = Fixture::new();
    let first = |age: f64| {
        spans(&fixture.line_with(
            "Jita",
            &Options {
                age,
                ..Options::default()
            },
        ))[0]
            .clone()
    };
    // 59 秒向下取到 50 秒；60 秒以上原样显示（由界面层换成「N 分钟」）。
    assert_eq!(first(59.0), span("50s", S::AgeFresh));
    assert_eq!(first(200.0), span("200s", S::AgeRecent));
    assert_eq!(first(400.0), span("400s", S::AgeOld));
}

/// 4 档安全等级：高安、低安、零安与虫洞；显示语言是上下文里的界面语言。
#[test]
fn security_styles() {
    let fixture = Fixture::new();
    let system = |text: &str| spans(&fixture.line(text))[1].clone();
    assert_eq!(system("Jita"), span("Jita 0.9", S::SystemHigh));
    // 中文消息里认出的星系，在英文界面里显示英文名。
    assert_eq!(system("纳伽"), span("Naga 0.1", S::SystemLow));
    assert_eq!(system("1DQ1-A"), span("1DQ1-A -0.4", S::SystemNull));
    // Thera 是虫洞星系：不显示安全等级。
    assert_eq!(system("Thera"), span("Thera", S::SystemUnknown));
    let chinese = Options {
        language: AppLanguage::Zh,
        ..Options::default()
    };
    assert_eq!(
        spans(&fixture.line_with("Jita", &chinese))[1],
        span("吉他 0.9", S::SystemHigh)
    );
}

/// 跳数的 4 种样式；不知道位置时是「?」；alert_jumps 为 0 时不高亮。
#[test]
fn jump_styles() {
    let fixture = Fixture::new();
    let near = Options {
        alert_jumps: 2,
        ..Options::default()
    };
    let jump = |text: &str, options: &Options| spans(&fixture.line_with(text, options))[2].clone();
    assert_eq!(jump("Perimeter", &near), span("1j", S::JumpsNear));
    // 高亮距离 2：1 跳是近，4 跳在两倍以内是中，5 跳是远。
    assert_eq!(jump("Hek", &near), span("4j", S::JumpsMid));
    assert_eq!(jump("Amarr", &near), span("5j", S::JumpsFar));
    // 夹具里 Onsooh 没有星门：到不了。
    assert_eq!(jump("Onsooh", &near), span("nogate", S::JumpsUnknown));
    let unknown = Options {
        origin: None,
        ..Options::default()
    };
    assert_eq!(jump("Jita", &unknown), span("?", S::JumpsUnknown));
    let off = Options {
        alert_jumps: 0,
        ..Options::default()
    };
    let value = fixture.line_with("Perimeter", &off);
    assert_eq!(spans(&value)[2], span("1j", S::JumpsFar));
    assert_eq!(value.emphasis, OverlayEmphasis::None);
}

/// 不显示原文时没有第二行，推断的人名列在第一行，人名之间有分隔；显示原文时推断的人名不列。
#[test]
fn show_original_off() {
    let fixture = Fixture::new();
    let hidden = Options {
        show_original: false,
        ..Options::default()
    };
    // 不显示原文时，人名只能在第一行看到，所以推断的人名也要列出。
    let value = fixture.line_with("T5ZI-S  Jorn Halden  Tarn Vex nv", &hidden);
    assert!(value.secondary.is_empty());
    let words = texts(&value);
    assert!(words.contains(&"Jorn Halden".to_owned()));
    assert!(words.contains(&" · ".to_owned()));
    assert_eq!(words.last().map(String::as_str), Some("NV"));
    let pilot = spans(&value).into_iter().find(|s| s.text == "Jorn Halden");
    assert_eq!(pilot.map(|s| s.style), Some(S::Pilot));
    // 显示原文时，第二行已有人名，第一行不重复列出没核对的人名。
    assert!(!texts(&fixture.line("T5ZI-S  Jorn Halden")).contains(&"Jorn Halden".to_owned()));
}

/// 不是情报的消息：时间、说话人与原文，没有第二行，没有背景。
#[test]
fn plain_message() {
    // 没有星系、舰船与用语的闲聊：不是情报，按普通消息显示。
    let value = Fixture::new().line("hello there");
    let expected = [
        span("40s", S::AgeFresh),
        span(" ", S::Plain),
        span("Mira Voss", S::Speaker),
        span(": hello there", S::Plain),
    ];
    assert_eq!(value.primary, expected);
    assert!(value.secondary.is_empty());
    assert_eq!(value.emphasis, OverlayEmphasis::None);
}

/// emphasis 的 3 种取值；HED-GP 离 Jita 很远，高亮距离 3 时不高亮。
#[test]
fn emphasis_values() {
    let fixture = Fixture::new();
    assert_eq!(fixture.line("Hek* clr").emphasis, OverlayEmphasis::Clear);
    assert_eq!(fixture.line("Perimeter Rifter").emphasis, OverlayEmphasis::Alert);
    let three = Options {
        alert_jumps: 3,
        ..Options::default()
    };
    assert_eq!(
        fixture.line_with("HED-GP Rifter", &three).emphasis,
        OverlayEmphasis::None
    );
    assert_eq!(
        spans(&fixture.line("Hek* clr")).last(),
        Some(&span("CLR", S::Clear))
    );
}

/// 在高亮距离内、又有舰船、人名或数量时，Alert 优先于 Clear；没有敌对时 Clear 优先；远处的仍是 Clear。
#[test]
fn alert_beats_clear_with_hostiles() {
    let fixture = Fixture::new();
    assert_eq!(
        fixture.line("Perimeter Rifter clr").emphasis,
        OverlayEmphasis::Alert
    );
    // 写了人数也算有敌对。
    assert_eq!(fixture.line("Perimeter clr 3").emphasis, OverlayEmphasis::Alert);
    assert_eq!(
        fixture.line("Perimeter Kael Doran clr").emphasis,
        OverlayEmphasis::Alert
    );
    // 只报近处安全：绿色。
    assert_eq!(fixture.line("Perimeter clr").emphasis, OverlayEmphasis::Clear);
    let three = Options {
        alert_jumps: 3,
        ..Options::default()
    };
    assert_eq!(
        fixture.line_with("HED-GP Rifter clr", &three).emphasis,
        OverlayEmphasis::Clear
    );
    assert_eq!(emphasis(true, false, true), OverlayEmphasis::Clear);
    assert_eq!(emphasis(false, true, false), OverlayEmphasis::Alert);
}

/// next_refresh：没有消息时 None；有不足 60 秒的消息时 10 秒后；否则 30 秒后。
#[test]
fn refresh_schedule() {
    let fixture = Fixture::new();
    let recent = fixture.item("Jita", 100.0);
    assert_eq!(next_refresh(&[], 0.0), None);
    // 消息 30 秒前：时间按 10 秒一档变，10 秒后刷新。
    assert_eq!(next_refresh([&recent], 130.0), Some(140.0));
    // 消息 100 秒前：之后按分钟变，30 秒刷新一次足够。
    assert_eq!(next_refresh([&recent], 200.0), Some(230.0));
}

/// 查到的人名在显示原文时也列出；没查到的带「?」用 Dim（只在不显示原文时）；数量取核对后的值；
/// 每个查到的、ID 为正的角色一个 zKillboard 链接。
#[test]
fn resolved_pilots() {
    let fixture = Fixture::new();
    let text = "HED-GP  Brenn Ostvar Tyra Kelloway  Kael Dorann";
    let not_found = PilotLookupOutcome::NotFound;
    // 第一段 4 个词的 9 个组合与第二段 2 个词的 3 个组合都有结果：两段都能分人。
    // Kael 的角色 ID 是 0，查到但没有链接。
    let directory = PilotDirectory::new(HashMap::from([
        ("brenn".to_owned(), not_found.clone()),
        ("ostvar".to_owned(), not_found.clone()),
        ("tyra".to_owned(), not_found.clone()),
        ("kelloway".to_owned(), not_found.clone()),
        (
            "brenn ostvar".to_owned(),
            PilotLookupOutcome::matched(91, "Brenn Ostvar"),
        ),
        ("ostvar tyra".to_owned(), not_found.clone()),
        (
            "tyra kelloway".to_owned(),
            PilotLookupOutcome::matched(92, "Tyra Kelloway"),
        ),
        ("brenn ostvar tyra".to_owned(), not_found.clone()),
        ("ostvar tyra kelloway".to_owned(), not_found.clone()),
        ("kael".to_owned(), PilotLookupOutcome::matched(0, "Kael")),
        ("dorann".to_owned(), not_found.clone()),
        ("kael dorann".to_owned(), not_found),
    ]));
    let shown_options = Options {
        pilots: directory.clone(),
        ..Options::default()
    };
    let shown = fixture.line_with(text, &shown_options);
    let words = texts(&shown);
    assert!(words.contains(&"Brenn Ostvar".to_owned()) && words.contains(&"Tyra Kelloway".to_owned()));
    // 显示原文时没查到的人名不列。
    assert!(!words.contains(&"Kael Dorann?".to_owned()));
    // 两个查到的人加一个没查到的人：约 3 人。
    assert!(words.contains(&"~×3".to_owned()));
    let expected = [
        OverlayLink {
            title: "Brenn Ostvar · zKillboard".into(),
            url: "https://zkillboard.com/character/91/".into(),
        },
        OverlayLink {
            title: "Tyra Kelloway · zKillboard".into(),
            url: "https://zkillboard.com/character/92/".into(),
        },
    ];
    assert_eq!(shown.links, expected);
    let hidden_options = Options {
        show_original: false,
        pilots: directory,
        ..Options::default()
    };
    let hidden = fixture.line_with(text, &hidden_options);
    assert!(spans(&hidden).contains(&span("Kael Dorann?", S::Dim)));
    // 角色 ID 是 0 时没有链接（演示模式的假核对服务）。
    let fake = Options {
        pilots: PilotDirectory::new(HashMap::from([
            ("kael".to_owned(), PilotLookupOutcome::NotFound),
            ("doran".to_owned(), PilotLookupOutcome::NotFound),
            (
                "kael doran".to_owned(),
                PilotLookupOutcome::matched(0, "Kael Doran"),
            ),
        ])),
        ..Options::default()
    };
    assert!(fixture.line_with("HED-GP Kael Doran", &fake).links.is_empty());
}

/// 数量取核对后的值：推断是 2 人（「Brenn Ostvar Tyra」与「Kelloway」），4 个单个词都查到时是约 ×4。
#[test]
fn count_uses_resolved_pilots() {
    let fixture = Fixture::new();
    let text = "HED-GP  Brenn Ostvar Tyra Kelloway";
    assert_eq!(fixture.item(text, MESSAGE_TIME).report.hostile_count, Some(2));
    let run: Vec<String> = ["Brenn", "Ostvar", "Tyra", "Kelloway"].map(String::from).to_vec();
    // 多词组合都没查到，4 个单词名字都查到：空缺里每词一人。
    let mut outcomes: HashMap<String, PilotLookupOutcome> = combinations(&run)
        .iter()
        .map(|name| (key(name), PilotLookupOutcome::NotFound))
        .collect();
    for (index, name) in run.iter().enumerate() {
        outcomes.insert(key(name), PilotLookupOutcome::matched(10 + index as i64, name));
    }
    let options = Options {
        pilots: PilotDirectory::new(outcomes),
        ..Options::default()
    };
    let value = fixture.line_with(text, &options);
    let words = texts(&value);
    assert!(words.contains(&"~×4".to_owned()));
    assert!(!words.contains(&"~×2".to_owned()));
    assert_eq!(value.links.len(), 4);
}

/// 目录为空时与核对前的输出相同：人名未核对，数量取解析结果，没有链接。
#[test]
fn empty_directory_matches_inference() {
    let hidden = Options {
        show_original: false,
        ..Options::default()
    };
    let value = Fixture::new().line_with("HED-GP  Brenn Ostvar Tyra Kelloway", &hidden);
    let words = texts(&value);
    assert!(words.contains(&"Brenn Ostvar Tyra".to_owned()));
    assert!(words.contains(&"Kelloway".to_owned()));
    assert!(words.contains(&"~×2".to_owned()));
    assert!(value.links.is_empty());
}
