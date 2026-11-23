// SPDX-License-Identifier: GPL-3.0-or-later
//
// 单行解析的用例，对应 macOS 的 CombatLogParserTests.swift 与 CombatLogEdgeCaseTests.swift 里归类的部分。

use super::*;
use crate::combat_log::parser::{log_time, parse, plain_text};
use crate::combat_log::{CombatLineKind, CombatLineKind::*, CombatLogLine};

/// 解析一行并取归类结果；不是日志行时返回 `None`。
fn kind(line: &str) -> Option<CombatLineKind> {
    parse(line).map(|l| l.kind)
}

/// 解析一行 combat 日志的正文。
fn body(text: &str) -> Option<CombatLineKind> {
    kind(&combat(text))
}

/// 中文的各类行：受到伤害、造成伤害、数字为 0、两种对方未命中、己方未命中、跃迁扰断、hint。
#[test]
fn chinese_lines() {
    assert_eq!(kind(ZH_INCOMING), Some(IncomingDamage(19)));
    assert_eq!(kind(ZH_OUTGOING), Some(OutgoingDamage(117)));
    assert_eq!(kind(ZH_INCOMING_ZERO), Some(IncomingDamage(0)));
    assert_eq!(kind(ZH_INCOMING_MISS), Some(IncomingMiss));
    assert_eq!(kind(ZH_INCOMING_MISS_WEAPON), Some(IncomingMiss));
    assert_eq!(kind(ZH_OUTGOING_MISS), Some(OutgoingMiss));
    assert_eq!(kind(ZH_WARP_SCRAMBLE), Some(OtherCombat));
    assert_eq!(
        parse(ZH_HINT),
        Some(CombatLogLine {
            category: "hint".into(),
            kind: Other
        })
    );
}

/// 类别转成小写，非 combat 类别一律是 Other。
#[test]
fn non_combat_categories() {
    assert_eq!(
        parse(RU_NONE_CATEGORY),
        Some(CombatLogLine {
            category: "none".into(),
            kind: Other
        })
    );
    let upper = "[ 2026.11.20 11:33:51 ] (COMBAT) 灾难皮希伊 粉碎者*完全没有打中你";
    assert_eq!(
        parse(upper),
        Some(CombatLogLine {
            category: "combat".into(),
            kind: IncomingMiss
        })
    );
}

/// 日文两个方向的介词相同，只靠颜色区分；去掉颜色后归为 OtherCombat，不猜方向。
#[test]
fn japanese_uses_color_only() {
    assert_eq!(kind(JA_INCOMING), Some(IncomingDamage(40)));
    assert_eq!(kind(JA_OUTGOING), Some(OutgoingDamage(492)));
    assert_eq!(kind(JA_NO_COLOR), Some(OtherCombat));
    assert_eq!(kind(JA_INCOMING_MISS), Some(IncomingMiss));
    assert_eq!(kind(JA_OUTGOING_MISS), Some(OutgoingMiss));
}

/// 俄文与英文的伤害行与未命中。
#[test]
fn russian_and_english_lines() {
    assert_eq!(kind(RU_INCOMING), Some(IncomingDamage(130)));
    assert_eq!(kind(RU_OUTGOING), Some(OutgoingDamage(983)));
    assert_eq!(kind(RU_INCOMING_MISS), Some(IncomingMiss));
    assert_eq!(kind(RU_OUTGOING_MISS), Some(OutgoingMiss));
    assert_eq!(kind(EN_INCOMING), Some(IncomingDamage(214)));
    assert_eq!(kind(EN_OUTGOING), Some(OutgoingDamage(214)));
    assert_eq!(kind(EN_INCOMING_MISS), Some(IncomingMiss));
    assert_eq!(kind(EN_INCOMING_MISS_WEAPON), Some(IncomingMiss));
    assert_eq!(kind(EN_OUTGOING_MISS), Some(OutgoingMiss));
}

/// 德、法、西、韩：带颜色与不带颜色的两个方向，以及两种未命中。
#[test]
fn template_languages() {
    for lang in &TEMPLATE_LANGUAGES {
        let name = lang.name;
        let incoming = format!("<color=0xffcc0000><b>214</b> {}", lang.incoming_middle);
        assert_eq!(body(&incoming), Some(IncomingDamage(214)), "{name}");
        let outgoing = format!("<color=0xff00ffff><b>214</b> {}", lang.outgoing_middle);
        assert_eq!(body(&outgoing), Some(OutgoingDamage(214)), "{name}");
        // 没有颜色标记时改用方向词或韩文的句尾。
        assert_eq!(
            body(&format!("<b>214</b> {}", lang.incoming_middle)),
            Some(IncomingDamage(214)),
            "{name}"
        );
        assert_eq!(
            body(&format!("<b>214</b> {}", lang.outgoing_middle)),
            Some(OutgoingDamage(214)),
            "{name}"
        );
        assert_eq!(body(lang.incoming_miss), Some(IncomingMiss), "{name}");
        assert_eq!(body(lang.outgoing_miss), Some(OutgoingMiss), "{name}");
    }
}

/// 没有颜色时方向词不区分大小写；没有任何方向词时是 OtherCombat。
#[test]
fn direction_words_without_color() {
    assert_eq!(
        body("<b>50</b> <font size=10>FROM <b>Sample Pilot</b>"),
        Some(IncomingDamage(50))
    );
    assert_eq!(
        body("<b>50</b> <font size=10>来自</font> <b>Sample Pilot</b>"),
        Some(IncomingDamage(50))
    );
    assert_eq!(
        body("<b>50</b> <font size=10>对</font> <b>Sample Pilot</b>"),
        Some(OutgoingDamage(50))
    );
    assert_eq!(body("<b>50</b> <b>Sample Pilot</b>"), Some(OtherCombat));
}

/// 有颜色但不是两种伤害色（远程维修一类）：不猜方向；各种颜色写法、中英文都一样。
#[test]
fn unknown_color_is_other_combat() {
    let repair = "<color=0xff7fffff><b>120</b><color=0x77ffffff><font size=10>来自</font><b><color=0xffffffff>Sample Pilot</b>远程装甲维修";
    assert_eq!(body(repair), Some(OtherCombat));
    assert_eq!(
        body(
            "<color=0xff7fffff><b>350</b><color=0x77ffffff><font size=10> remote armor repaired from </font><b><color=0xffffffff>Sample Pilot</b>"
        ),
        Some(OtherCombat)
    );
    assert_eq!(
        body("<color=#FF7FFFFF><b>350</b> from Sample Pilot"),
        Some(OtherCombat)
    );
    assert_eq!(
        body("<color=\"0xff7fffff\"><b>1,200</b> 来自 Sample Pilot"),
        Some(OtherCombat)
    );
    // 能量中和、能量传输的数字以 `-`、`+` 开头，不是开头的数字。
    assert_eq!(
        body(
            "<color=0xffe57f7f><b>-43 GJ</b><color=0x77ffffff><font size=10> energy neutralized </font><b>Sample Pilot</b>"
        ),
        Some(OtherCombat)
    );
    assert_eq!(
        body(
            "<color=0xff7fffff><b>+43 GJ</b><color=0x77ffffff><font size=10> energy drained from </font><b>Sample Pilot</b>"
        ),
        Some(OtherCombat)
    );
}

/// 数字之间的千分位逗号、不换行空格与窄不换行空格被跳过；分隔符后不是数字时，数字到此结束。
#[test]
fn grouped_numbers() {
    assert_eq!(
        body("<color=0xffcc0000><b>1,265</b> 来自 X"),
        Some(IncomingDamage(1_265))
    );
    assert_eq!(
        body("<color=0xffcc0000><b>12\u{00A0}345</b> 来自 X"),
        Some(IncomingDamage(12_345))
    );
    assert_eq!(
        body("<color=0xffcc0000><b>1\u{202F}000\u{202F}000</b> 来自 X"),
        Some(IncomingDamage(1_000_000))
    );
    assert_eq!(
        body("<color=0xffcc0000><b>12,</b> 来自 X"),
        Some(IncomingDamage(12))
    );
}

/// 颜色值大写、`#` 前缀、引号都能识别；取数字前面跳过的标记里最后一个颜色，数字后面的标记不改变方向。
#[test]
fn color_variants() {
    assert_eq!(body("<color=0xFFCC0000><b>7</b> X"), Some(IncomingDamage(7)));
    assert_eq!(body("<color=#FF00FFFF><b>8</b> X"), Some(OutgoingDamage(8)));
    assert_eq!(
        body("<color=0xff00ffff><font size=10><color=0xffcc0000><b>9</b> X"),
        Some(IncomingDamage(9))
    );
    assert_eq!(
        body("<color=\"0xffcc0000\"><b>42</b> 来自 X"),
        Some(IncomingDamage(42))
    );
    assert_eq!(
        body("<color='#ff00ffff'><b>42</b> to X"),
        Some(OutgoingDamage(42))
    );
    assert_eq!(
        body("<color=0xffcc0000><b>5</b> <color=0xff00ffff>from X"),
        Some(IncomingDamage(5))
    );
    assert_eq!(body("<b>5</b> <color=0xffcc0000>to X"), Some(OutgoingDamage(5)));
}

/// 超出 i64 范围的数字取 i64::MAX，不崩溃。
#[test]
fn huge_number_saturates() {
    let line = "<color=0xffcc0000><b>99999999999999999999999</b> 来自 X";
    assert_eq!(body(line), Some(IncomingDamage(i64::MAX)));
}

/// 不是日志行的输入返回 None：多行条目的后续行、空行、时间不完整、括号缺失、从文件中间读起的半行。
#[test]
fn malformed_lines_return_none() {
    for line in [
        "",
        "  续行文字，不以方括号开头",
        "[ 2026.10.22 10:30 ] (combat) x",
        "[ 2026.10.22 10:30:1x ] (combat) x",
        "[2026.10.22 10:30:13] (combat) x",
        "[ 2026.10.22 10:30:13 ] combat x",
        "[ 2026.10.22 10:30:13 ] (combat x",
        "ffffff>古斯塔斯塔台岗哨 II*</b> - 穿透",
    ] {
        assert_eq!(parse(line), None, "{line}");
    }
}

/// 行首的一个或多个 U+FEFF、行尾的回车与换行被去掉；正文为空的行也能解析。
#[test]
fn bom_and_line_endings() {
    assert_eq!(kind(&format!("\u{FEFF}{ZH_INCOMING_MISS}\r")), Some(IncomingMiss));
    assert_eq!(kind(&format!("{ZH_INCOMING}\r")), Some(IncomingDamage(19)));
    let line = combat("<color=0xffcc0000><b>7</b> 来自 X");
    assert_eq!(kind(&format!("\u{FEFF}\u{FEFF}{line}")), Some(IncomingDamage(7)));
    assert_eq!(kind(&format!("{line}\n")), Some(IncomingDamage(7)));
    assert_eq!(kind(&format!("{line}\r\n")), Some(IncomingDamage(7)));
    let empty = "[ 2026.10.22 10:30:13 ] (notify)";
    assert_eq!(
        parse(empty),
        Some(CombatLogLine {
            category: "notify".into(),
            kind: Other
        })
    );
}

/// 未命中的句尾：尾部空白、全角句号、大写都不影响；句尾后面还有别的文字时归为己方未命中。
#[test]
fn incoming_miss_ending_variants() {
    assert_eq!(body("Sample Pilot misses you completely.  "), Some(IncomingMiss));
    assert_eq!(body("Sample Pilot MISSES YOU COMPLETELY"), Some(IncomingMiss));
    assert_eq!(body("灾难皮希伊 粉碎者*完全没有打中你。"), Some(IncomingMiss));
    assert_eq!(
        body("Sample Pilot misses you completely - Sample Module"),
        Some(OutgoingMiss)
    );
}

/// 武器名以数字开头的未命中（如 125mm 炮塔）仍能识别；数字开头的真实伤害行不受影响。
#[test]
fn digit_leading_weapon_miss() {
    assert_eq!(
        body("125mm Gatling AutoCannon II belonging to Sample Pilot misses you completely"),
        Some(IncomingMiss)
    );
    assert_eq!(
        body("425mm Railgun II von Sample Pilot hat Sie völlig verfehlt"),
        Some(IncomingMiss)
    );
    assert_eq!(
        body("1400mm Howitzer Artillery II, de Sample Pilot, falla por mucho."),
        Some(IncomingMiss)
    );
    assert_eq!(
        body("125mm Gatling AutoCannon II misses Sample Pilot completely"),
        Some(OutgoingMiss)
    );
    assert_eq!(
        body("<color=0xffcc0000><b>12</b> from Sample Pilot - 125mm Gatling misses"),
        Some(IncomingDamage(12))
    );
    assert_eq!(
        body("12 from Sample Pilot - Gatling - Hits"),
        Some(IncomingDamage(12))
    );
    assert_eq!(
        body("12 to Sample Pilot - Gatling - Hits"),
        Some(OutgoingDamage(12))
    );
    assert_eq!(
        body("12 来自 Sample Pilot - 轨道炮 - 击中"),
        Some(IncomingDamage(12))
    );
    assert_eq!(body("12 mm unknown module activated"), Some(OtherCombat));
}

/// 韩文己方未命中：「을(를)」及按收音换成的「을」「를」都不算对方未命中；对方未命中仍是 IncomingMiss。
#[test]
fn korean_resolved_particle() {
    assert_eq!(
        body("Sample Module이(가) Sample Pilot을(를) 완전히 빗나감"),
        Some(OutgoingMiss)
    );
    assert_eq!(
        body("Sample Module이 Sample Pilot을 완전히 빗나감"),
        Some(OutgoingMiss)
    );
    assert_eq!(
        body("Sample Module이 Sample Pilo를 완전히 빗나감"),
        Some(OutgoingMiss)
    );
    assert_eq!(
        body("Sample Pilot의 Sample Module이(가) 완전히 빗나감"),
        Some(IncomingMiss)
    );
    assert_eq!(
        body("Sample Pilot의 Sample Module이 완전히 빗나감"),
        Some(IncomingMiss)
    );
    assert_eq!(
        body("Sample Pilot의 Sample Modul가 완전히 빗나감"),
        Some(IncomingMiss)
    );
}

/// 标记被删掉，连续空白合成一个空格；找不到 `>` 的 `<` 保留为普通字符；实体不解码。
#[test]
fn plain_text_strips_markup() {
    assert_eq!(
        plain_text("<b>19</b> <color=0x77ffffff><font size=10>来自</font>  <b>X</b>"),
        "19 来自 X"
    );
    assert_eq!(plain_text("  a\u{00A0}\u{00A0}b  "), "a b");
    assert_eq!(plain_text("a <b>x</b> < tail"), "a x < tail");
    assert_eq!(plain_text("x <unclosed"), "x <unclosed");
    assert_eq!(plain_text("A &amp; B"), "A &amp; B");
}

/// 日志时间按 UTC 换算成 1970 年以来的秒数；不合法的日期返回 None。
#[test]
fn log_time_is_utc() {
    // 2026-11-20 09:51:46 UTC = 1,795,168,306 秒（与 macOS 的用例相同，经 date -u 核对）。
    assert_eq!(
        log_time("[ 2026.11.20 09:51:46 ] (hint) x"),
        Some(1_795_168_306.0)
    );
    assert_eq!(log_time("[ 1970.01.01 00:00:00 ] (hint) x"), Some(0.0));
    assert_eq!(log_time("[ 2026.13.01 00:00:00 ] (hint) x"), None);
    assert_eq!(log_time("not a log line"), None);
}
