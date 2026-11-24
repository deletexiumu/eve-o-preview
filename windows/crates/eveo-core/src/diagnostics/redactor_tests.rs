// SPDX-License-Identifier: GPL-3.0-or-later
//
// 脱敏的用例，对应 macOS 的 RedactorTests.swift（v1.1 设计 7.3 节、14.1 节），路径换成 Windows 的写法。

use super::*;

/// 测试用的本机名字：短用户名 cookie、全名、计算机名两种写法、三个角色名。
fn terms() -> RedactionTerms {
    RedactionTerms {
        user_names: vec!["cookie".into(), "Cookie Monster".into()],
        host_names: vec!["COOKIE-PC.home.lan".into(), "COOKIE-PC".into()],
        character_names: vec!["Bob".into(), "Bob Jr".into(), "Alice Zed".into()],
        home_directory: Some(r"C:\Users\cookie".into()),
    }
}

/// 用词表脱敏一段文字，只要结果。
fn redacted(terms: &RedactionTerms, text: &str) -> String {
    Redactor::new(terms).redact(text).0
}

/// 用户目录原样、JSON 转义与 `/` 分隔三种写法都换成 `%USERPROFILE%`，不区分大小写。
#[test]
fn home_directory_forms() {
    let redactor = Redactor::new(&terms());
    let (text, counts) = redactor.redact(r"config: C:\Users\cookie\AppData\Roaming\x.json");
    assert_eq!(text, r"config: %USERPROFILE%\AppData\Roaming\x.json");
    assert_eq!(counts.user, 1);
    assert_eq!(
        redactor.redact(r#"{"path":"C:\\Users\\cookie\\AppData"}"#).0,
        r#"{"path":"%USERPROFILE%\\AppData"}"#
    );
    assert_eq!(redactor.redact("at c:/users/COOKIE/x").0, r"at %USERPROFILE%/x");
}

/// 不在 `C:\Users` 下的用户目录也能认出来；末尾的分隔符不影响。
#[test]
fn non_standard_home_directory() {
    let terms = RedactionTerms {
        user_names: vec!["cookie".into()],
        home_directory: Some(r"D:\Profiles\ck\".into()),
        ..RedactionTerms::default()
    };
    assert_eq!(
        redacted(&terms, r"at D:\Profiles\ck\logs"),
        r"at %USERPROFILE%\logs"
    );
}

/// 用户名作为独立的词被替换；作为别的词的一部分时不被替换。
#[test]
fn user_name_boundaries() {
    let redactor = Redactor::new(&terms());
    assert_eq!(
        redactor.redact("owner cookie logged in").0,
        "owner [user] logged in"
    );
    assert_eq!(redactor.redact("HTTPCookieStorage").0, "HTTPCookieStorage");
    assert_eq!(redactor.redact("cookies and cookie2").0, "cookies and cookie2");
    assert_eq!(redactor.redact("user=cookie;").0, "user=[user];");
    assert_eq!(redactor.redact("by Cookie Monster.").0, "by [user].");
}

/// 不足 3 个字符的用户名只在紧跟用户目录的父目录时替换（三种写法）。
#[test]
fn short_user_name_only_in_paths() {
    let terms = RedactionTerms {
        user_names: vec!["ab".into()],
        ..RedactionTerms::default()
    };
    assert_eq!(redacted(&terms, "ab is here"), "ab is here");
    assert_eq!(redacted(&terms, r"C:\Users\ab\x"), r"C:\Users\[user]\x");
    assert_eq!(redacted(&terms, r"C:\\Users\\AB\\x"), r"C:\\Users\\[user]\\x");
    assert_eq!(redacted(&terms, "C:/Users/ab/x"), "C:/Users/[user]/x");
    assert_eq!(redacted(&terms, r"C:\Users\abc\x"), r"C:\Users\abc\x");
    let single = RedactionTerms {
        user_names: vec!["q".into()],
        ..RedactionTerms::default()
    };
    assert_eq!(
        redacted(&single, r"quick q C:\Users\q\x"),
        r"quick q C:\Users\[user]\x"
    );
    assert_eq!(redacted(&single, r"C:\Users\qq\x"), r"C:\Users\qq\x");
}

/// 计算机名的各种写法都换成 `[host]`，长的写法先匹配。
#[test]
fn host_names() {
    let (text, counts) = Redactor::new(&terms()).redact("host cookie-pc.home.lan, short COOKIE-PC");
    assert_eq!(text, "host [host], short [host]");
    assert_eq!(counts.host, 2);
}

/// 角色名不区分大小写；最长优先：`Bob Jr` 先于 `Bob`。
#[test]
fn character_names() {
    let redactor = Redactor::new(&terms());
    assert_eq!(
        redactor.redact("ALICE ZED and alice zed").0,
        "[character-1] and [character-1]"
    );
    let jr = redactor.placeholder_for_character("Bob Jr").unwrap();
    let bob = redactor.placeholder_for_character("bob").unwrap();
    assert_eq!(redactor.redact("Bob Jr met Bob").0, format!("{jr} met {bob}"));
}

/// 中文角色名不要求边界；单个非 ASCII 字符的名字不替换、不占序号。
#[test]
fn non_ascii_names_need_no_boundary() {
    let terms = RedactionTerms {
        character_names: vec!["星辰大海".into(), "龙".into()],
        ..RedactionTerms::default()
    };
    let redactor = Redactor::new(&terms);
    let (text, counts) = redactor.redact("角色星辰大海上线，龙");
    assert_eq!(text, "角色[character-1]上线，龙");
    assert_eq!(redactor.placeholder_for_character("龙"), None);
    assert_eq!(counts.character, 1);
}

/// 名叫 `user` 的角色不破坏已输出的占位符。
#[test]
fn character_named_user_keeps_placeholders() {
    let terms = RedactionTerms {
        user_names: vec!["cookie".into()],
        character_names: vec!["user".into()],
        home_directory: Some(r"C:\Users\cookie".into()),
        ..RedactionTerms::default()
    };
    let (text, counts) = Redactor::new(&terms).redact(r"C:\Users\cookie\x cookie user");
    assert_eq!(text, r"%USERPROFILE%\x [user] [character-1]");
    assert_eq!((counts.user, counts.character), (2, 1));
}

/// 序号按名字排序（不区分大小写）后从 1 起编，与传入顺序无关。
#[test]
fn character_numbering_is_sorted_and_stable() {
    let make = |names: &[&str]| {
        Redactor::new(&RedactionTerms {
            character_names: names.iter().map(|n| (*n).to_owned()).collect(),
            ..RedactionTerms::default()
        })
    };
    for redactor in [
        make(&["zeta", "Alpha", "mike"]),
        make(&["mike", "zeta", "Alpha", "ALPHA"]),
    ] {
        assert_eq!(redactor.placeholder_for_character("alpha"), Some("[character-1]"));
        assert_eq!(redactor.placeholder_for_character("mike"), Some("[character-2]"));
        assert_eq!(redactor.placeholder_for_character("zeta"), Some("[character-3]"));
        assert_eq!(redactor.placeholder_for_character("nobody"), None);
    }
}

/// 「José García」的 NFC（预组合）与 NFD（分解）两种写法。
const NFC_NAME: &str = "Jos\u{E9} Garc\u{ED}a";
/// 同一个名字的 NFD 写法。
const NFD_NAME: &str = "Jose\u{301} Garci\u{301}a";

/// 词与正文用不同的规范化写法时也能替换；两种写法得到同一个占位符、只占一个序号。
#[test]
fn normalization_forms() {
    assert_ne!(NFC_NAME.chars().count(), NFD_NAME.chars().count());
    for (term, text) in [(NFC_NAME, NFD_NAME), (NFD_NAME, NFC_NAME), (NFC_NAME, NFC_NAME)] {
        let redactor = Redactor::new(&RedactionTerms {
            character_names: vec![term.into()],
            ..RedactionTerms::default()
        });
        assert_eq!(
            redactor.redact(&format!("pilot {text} undocked")).0,
            "pilot [character-1] undocked"
        );
        assert_eq!(
            redactor.placeholder_for_character(NFD_NAME),
            Some("[character-1]")
        );
    }
    let both = Redactor::new(&RedactionTerms {
        character_names: vec![NFD_NAME.into(), "Alpha".into(), NFC_NAME.into()],
        ..RedactionTerms::default()
    });
    assert_eq!(both.placeholder_for_character(NFC_NAME), Some("[character-2]"));
    assert_eq!(
        both.redact(&format!("{NFC_NAME}/{NFD_NAME}")).0,
        "[character-2]/[character-2]"
    );
    let home = Redactor::new(&RedactionTerms {
        user_names: vec![NFC_NAME.into()],
        home_directory: Some(format!(r"C:\Users\{NFC_NAME}")),
        ..RedactionTerms::default()
    });
    let (text, counts) = home.redact(&format!(r"{NFD_NAME} at C:\Users\{NFD_NAME}\x"));
    assert_eq!(text, r"[user] at %USERPROFILE%\x");
    assert_eq!(counts.user, 2);
}

/// 设备标识的值被替换，键保留；冒号两侧的空白可有可无；值里的转义引号不提前结束。
#[test]
fn device_identifiers() {
    let text = r#"{"crashReporterKey" : "AB\"CD","deviceIdentifierForVendor":"F00D","other":"keep"}"#;
    let (result, counts) = Redactor::new(&RedactionTerms::default()).redact(text);
    assert_eq!(
        result,
        r#"{"crashReporterKey" : "[redacted]","deviceIdentifierForVendor":"[redacted]","other":"keep"}"#
    );
    assert_eq!(counts.identifier, 2);
    // 没有值或没有结束引号时原样保留。
    let broken = r#""crashReporterKey": 5, "crashReporterKey":"open"#;
    assert_eq!(Redactor::new(&RedactionTerms::default()).redact(broken).0, broken);
}

/// 脱敏后的 JSON 仍能解析，内容是预期的占位符。
#[test]
fn redacted_json_still_parses() {
    let json = r#"{"crashReporterKey":"5E3B","path":"C:\\Users\\cookie\\AppData\\Local\\EVE-O Preview","host":"COOKIE-PC","note":"Bob Jr"}"#;
    let text = Redactor::new(&terms()).redact(json).0;
    let object: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&text).unwrap();
    assert_eq!(object["crashReporterKey"], "[redacted]");
    assert_eq!(object["path"], r"%USERPROFILE%\AppData\Local\EVE-O Preview");
    assert_eq!(object["host"], "[host]");
    assert!(object["note"].as_str().unwrap().starts_with("[character-"));
}

/// 计数按类别累计，`+` 按类别相加；空的词表与空白的词原样返回。
#[test]
fn counts_and_empty_terms() {
    let (_, counts) =
        Redactor::new(&terms()).redact(r#"C:\Users\cookie cookie COOKIE-PC Bob "crashReporterKey":"x""#);
    let expected = RedactionCounts {
        user: 2,
        host: 1,
        character: 1,
        identifier: 1,
    };
    assert_eq!(counts, expected);
    assert_eq!(counts.total(), 5);
    assert_eq!((counts + expected).user, 4);
    let text = r"nothing to hide at C:\Users\someone";
    let blanks = RedactionTerms {
        user_names: vec![String::new(), "  ".into()],
        host_names: vec![String::new()],
        character_names: vec![" ".into()],
        home_directory: Some(String::new()),
    };
    let (result, counts) = Redactor::new(&blanks).redact(text);
    assert_eq!(result, text);
    assert_eq!(counts.total(), 0);
    assert_eq!(redacted(&RedactionTerms::default(), text), text);
}
