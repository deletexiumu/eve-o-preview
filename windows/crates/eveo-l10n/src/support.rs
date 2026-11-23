// SPDX-License-Identifier: GPL-3.0-or-later
//
// 生成的文案用到的辅助函数：复数规则与占位符的格式。规则与 macOS 一致
// （Localization/Generated/L10nPlural.swift、L10n.swift 的 combatSecondsNumber），两端同一个数字写法相同。

use eveo_core::model::AppLanguage;

/// 复数类别。只考虑非负整数（个数、秒数）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Plural {
    /// 单数。
    One,
    /// 俄文的「少数」（个位 2～4）。
    Few,
    /// 俄文的「多数」。
    Many,
    /// 其余。
    Other,
}

/// 各语言的复数规则。中文、日文、韩文只有一种形式，生成的代码不调用它们。
pub mod plural {
    use super::Plural;

    /// 英文：1 为单数。
    pub fn en(n: i64) -> Plural {
        if n.unsigned_abs() == 1 {
            Plural::One
        } else {
            Plural::Other
        }
    }

    /// 德文：同英文。
    pub fn de(n: i64) -> Plural {
        en(n)
    }

    /// 西班牙文：同英文。
    pub fn es(n: i64) -> Plural {
        en(n)
    }

    /// 法文：0 与 1 为单数。
    pub fn fr(n: i64) -> Plural {
        if n.unsigned_abs() < 2 {
            Plural::One
        } else {
            Plural::Other
        }
    }

    /// 俄文：个位 1（11 除外）为 one；个位 2～4（12～14 除外）为 few；其余为 many。
    pub fn ru(n: i64) -> Plural {
        let n = n.unsigned_abs();
        let (last_two, last) = (n % 100, n % 10);
        if (11..=14).contains(&last_two) {
            Plural::Many
        } else if last == 1 {
            Plural::One
        } else if (2..=4).contains(&last) {
            Plural::Few
        } else {
            Plural::Many
        }
    }
}

/// 秒数的数字部分：整数不带小数点，其余保留一位（占位符格式 `secs`）。
pub(crate) fn seconds_number(value: f64) -> String {
    // 与 macOS 相同：非有限值或过大的数按原样显示，不转整数。
    if !value.is_finite() || value.abs() >= 1e9 {
        return value.to_string();
    }
    if value.round() == value {
        // 上面已排除过大的值，转换不会溢出。
        format!("{}", value as i64)
    } else {
        format!("{value:.1}")
    }
}

/// 按语言的习惯写一位小数（占位符格式 `.1f_locale`）：俄、法、德、西文的小数点写逗号。
/// 只用于界面上的小数值（秒数），不加千位分隔。
pub(crate) fn locale_decimal1(value: f64, language: AppLanguage) -> String {
    let text = format!("{value:.1}");
    match language {
        AppLanguage::Ru | AppLanguage::Fr | AppLanguage::De | AppLanguage::Es => text.replace('.', ","),
        _ => text,
    }
}

/// 日文、中文的列举：每项加「」，用「、」连接（占位符格式 `list_cjk`）。
pub(crate) fn cjk_list(items: &[String]) -> String {
    items
        .iter()
        .map(|item| format!("「{item}」"))
        .collect::<Vec<_>>()
        .join("、")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 复数规则与 macOS 的 L10nPlural 一致。
    #[test]
    fn plural_rules() {
        assert_eq!(plural::en(1), Plural::One);
        assert_eq!(plural::en(0), Plural::Other);
        assert_eq!(plural::fr(0), Plural::One);
        assert_eq!(plural::fr(2), Plural::Other);
        let ru: Vec<_> = [1, 2, 5, 11, 12, 21, 22, 25, 101, 111]
            .iter()
            .map(|&n| plural::ru(n))
            .collect();
        use Plural::*;
        assert_eq!(ru, [One, Few, Many, Many, Many, One, Few, Many, One, Many]);
    }

    /// 数字格式与 macOS 的 combatSecondsNumber、FormatStyle 的写法一致。
    #[test]
    fn number_formats() {
        assert_eq!(seconds_number(3.0), "3");
        assert_eq!(seconds_number(2.5), "2.5");
        assert_eq!(seconds_number(2.25), "2.2");
        assert_eq!(locale_decimal1(1.5, AppLanguage::De), "1,5");
        assert_eq!(locale_decimal1(1.5, AppLanguage::Ja), "1.5");
        assert_eq!(cjk_list(&["Local".into(), "Corp".into()]), "「Local」、「Corp」");
    }
}
