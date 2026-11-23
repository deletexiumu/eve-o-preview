// SPDX-License-Identifier: GPL-3.0-or-later
//
// 分行器的用例，对应 macOS 的 LogLineFramerTests.swift 与 CombatLogEdgeCaseTests.swift 里分行的部分：
// 多字节字符被切开、半行、CRLF、BOM、UTF-16、超长行、reset 与指定编码，以及「结果与字节怎样分段到达无关」。

use crate::combat_log::framer::{LogLineFramer, LogTextEncoding, LogTextEncoding::*};

/// 自动判断编码、默认上限的分行器。
fn framer() -> LogLineFramer {
    LogLineFramer::default()
}

/// 把文本编码成带或不带 BOM 的字节。
fn encode(text: &str, encoding: LogTextEncoding, bom: bool) -> Vec<u8> {
    match encoding {
        Utf8 => {
            let mut data = if bom { vec![0xEF, 0xBB, 0xBF] } else { Vec::new() };
            data.extend_from_slice(text.as_bytes());
            data
        }
        Utf16LittleEndian | Utf16BigEndian => {
            let big = encoding == Utf16BigEndian;
            let mut data = match (bom, big) {
                (false, _) => Vec::new(),
                (true, true) => vec![0xFE, 0xFF],
                (true, false) => vec![0xFF, 0xFE],
            };
            for unit in text.encode_utf16() {
                data.extend_from_slice(&if big {
                    unit.to_be_bytes()
                } else {
                    unit.to_le_bytes()
                });
            }
            data
        }
    }
}

/// 一次追加全部字节得到的行。
fn whole(data: &[u8], encoding: Option<LogTextEncoding>, max: usize) -> Vec<String> {
    LogLineFramer::new(encoding, max).append(data)
}

/// 在 `cut` 处切成两段先后追加得到的行。
fn split(data: &[u8], cut: usize, encoding: Option<LogTextEncoding>, max: usize) -> Vec<String> {
    let mut framer = LogLineFramer::new(encoding, max);
    let mut lines = framer.append(&data[..cut]);
    lines.extend(framer.append(&data[cut..]));
    lines
}

/// 逐字节追加得到的行。
fn byte_by_byte(data: &[u8], encoding: Option<LogTextEncoding>, max: usize) -> Vec<String> {
    let mut framer = LogLineFramer::new(encoding, max);
    data.iter()
        .flat_map(|b| framer.append(std::slice::from_ref(b)))
        .collect()
}

/// 一个汉字的 3 个字节被切在两次追加之间，拼起来后输出完整的行。
#[test]
fn multibyte_split_across_appends() {
    let mut f = framer();
    let data = "收听者\n".as_bytes();
    assert!(f.append(&data[..2]).is_empty());
    assert_eq!(f.append(&data[2..]), ["收听者"]);
    assert_eq!(f.encoding(), Some(Utf8));
}

/// 尾部的半行留到下次；CRLF 的回车被去掉，空行照常输出。
#[test]
fn partial_lines_and_crlf() {
    let mut f = framer();
    assert_eq!(f.append(b"first\nsec"), ["first"]);
    assert_eq!(f.append(b"ond\nthird"), ["second"]);
    assert_eq!(f.append(b"\n"), ["third"]);
    assert_eq!(framer().append(b"a\r\n\r\nb\n"), ["a", "", "b"]);
}

/// 带 BOM 的 UTF-8：BOM 不进入输出；不到 3 个字节时不判断编码，凑够后再判断。
#[test]
fn utf8_bom_detection() {
    assert_eq!(framer().append(&encode("游戏记录\n", Utf8, true)), ["游戏记录"]);
    let mut f = framer();
    assert!(f.append(&[0xEF, 0xBB]).is_empty());
    assert_eq!(f.encoding(), None);
    assert_eq!(f.append(&[0xBF, b'x', b'\n']), ["x"]);
}

/// UTF-16 小端与大端，含 CRLF 与在奇数字节处切开的码元。
#[test]
fn utf16_both_endians() {
    for (encoding, big) in [(Utf16BigEndian, true), (Utf16LittleEndian, false)] {
        let data = encode("频道\r\nLocal\n", encoding, true);
        let mut f = framer();
        let mut lines = f.append(&data[..5]);
        lines.extend(f.append(&data[5..]));
        assert_eq!(lines, ["频道", "Local"], "big endian: {big}");
        assert_eq!(f.encoding(), Some(encoding));
    }
}

/// 超长行被丢弃，之后的行恢复正常；跨多次追加的超长行也一样。
#[test]
fn overlong_line_discarded() {
    let mut f = LogLineFramer::new(None, 8);
    assert_eq!(f.append(b"ok\n0123456789\nfine\n"), ["ok", "fine"]);
    assert!(f.append(b"abcdefghij").is_empty());
    assert!(f.append(b"klmnop").is_empty());
    assert_eq!(f.append(b"q\nnext\n"), ["next"]);
}

/// reset 清空缓冲，编码恢复成建分行器时的值；指定编码时不做 BOM 判断；非法字节用 U+FFFD 代替。
#[test]
fn reset_explicit_encoding_and_invalid_bytes() {
    let mut f = framer();
    assert!(f.append(b"half").is_empty());
    f.reset();
    assert_eq!(f.encoding(), None);
    assert_eq!(f.append(b"whole\n"), ["whole"]);

    let mut explicit = LogLineFramer::with_encoding(Utf8);
    assert_eq!(explicit.append(&[0xEF, 0xBB, 0xBF, b'x', b'\n']), ["\u{FEFF}x"]);
    assert_eq!(explicit.append(b"y\n"), ["y"]);
    assert_eq!(
        LogLineFramer::with_encoding(Utf8).append(&[0x61, 0xFF, 0x62, 0x0A]),
        ["a\u{FFFD}b"]
    );
}

/// 样例文本：中文、日文、代理对（emoji）、CRLF、空行，以及 UTF-16 码元里含 0A 字节的字符
/// （U+0A0A 的两个字节都是 0A，U+010A 的低字节是 0A），用来核对 UTF-16 按码元对齐找换行。
const SAMPLE: &str =
    "  游戏记录\r\n  收听者: Aurora Vale\n\n[ 2026.01.01 00:00:00 ] (combat) 🛰️ ਊ Ċ 外した\r\ntail\n";
/// 期望的行：与切分无关。
const EXPECTED: [&str; 5] = [
    "  游戏记录",
    "  收听者: Aurora Vale",
    "",
    "[ 2026.01.01 00:00:00 ] (combat) 🛰️ ਊ Ċ 外した",
    "tail",
];

/// 3 种编码、带与不带 BOM：任一切点切成两段、逐字节追加，结果都与一次追加相同。
#[test]
fn every_cut_point_gives_same_lines() {
    for encoding in [Utf8, Utf16LittleEndian, Utf16BigEndian] {
        for bom in [true, false] {
            let data = encode(SAMPLE, encoding, bom);
            // 不带 BOM 的 UTF-16 无法自动判断，由调用方指定编码（从文件中间读起的做法）。
            let given = (encoding != Utf8 && !bom).then_some(encoding);
            let max = crate::combat_log::framer::DEFAULT_MAX_LINE_BYTES;
            assert_eq!(whole(&data, given, max), EXPECTED, "{encoding:?} bom={bom}");
            for cut in 0..=data.len() {
                assert_eq!(
                    split(&data, cut, given, max),
                    EXPECTED,
                    "{encoding:?} bom={bom} cut={cut}"
                );
            }
            assert_eq!(
                byte_by_byte(&data, given, max),
                EXPECTED,
                "{encoding:?} bom={bom}"
            );
        }
    }
}

/// 回车与换行被切在两次追加之间：回车照样去掉；内容正好等于上限的 CRLF 行在切开时也保留。
#[test]
fn carriage_return_split_from_line_feed() {
    let mut f = framer();
    assert!(f.append(b"abc\r").is_empty());
    assert_eq!(f.append(b"\ndef\r\n"), ["abc", "def"]);
    let data = b"12345678\r\nnext\n";
    assert_eq!(whole(data, None, 8), ["12345678", "next"]);
    assert_eq!(split(data, 9, None, 8), ["12345678", "next"]);
}

/// 内容等于上限、以 CRLF 结尾的行，以及超长的 CRLF 行：任一切点、逐字节追加的结果都与一次追加相同。
#[test]
fn limit_and_overlong_crlf_lines_independent_of_cuts() {
    let data = b"ok\r\n12345678\r\n0123456789abcdef\r\n123456789\r\nlast\r\n";
    let expected = ["ok", "12345678", "last"];
    assert_eq!(whole(data, None, 8), expected);
    for cut in 0..=data.len() {
        assert_eq!(split(data, cut, None, 8), expected, "cut={cut}");
    }
    assert_eq!(byte_by_byte(data, None, 8), expected);
}

/// UTF-16 的 CRLF 同样不把回车计入行长（含切在回车码元中间的切点）。上限 8 字节即 4 个字符。
#[test]
fn limit_crlf_lines_independent_of_cuts_utf16() {
    for encoding in [Utf16LittleEndian, Utf16BigEndian] {
        let data = encode("ab\r\n1234\r\n0123456789\r\nend\r\n", encoding, false);
        let expected = ["ab", "1234", "end"];
        assert_eq!(whole(&data, Some(encoding), 8), expected);
        for cut in 0..=data.len() {
            assert_eq!(
                split(&data, cut, Some(encoding), 8),
                expected,
                "{encoding:?} cut={cut}"
            );
        }
    }
}

/// 超长行之后的行不受切分方式影响（切点不落在回车与换行之间时）。
#[test]
fn overlong_line_independent_of_cuts() {
    let data = b"ok\n0123456789abcdef\nfine\r\nlast\n";
    let expected = ["ok", "fine", "last"];
    assert_eq!(whole(data, None, 8), expected);
    for cut in 0..=data.len() {
        if cut > 0 && data[cut - 1] == b'\r' {
            continue;
        }
        assert_eq!(split(data, cut, None, 8), expected, "cut={cut}");
    }
}
