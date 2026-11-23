// SPDX-License-Identifier: GPL-3.0-or-later
//
// 生成的文字代码的抽查：复数、分支、格式与平台变体各取几条，结果应与 shared/l10n 里写的一致，
// 写法与 macOS 生成的 Swift 相同（macOS 那边由双跑测试核对过，这里核对 Rust 的生成规则）。

//! 生成代码的抽查。

use eveo_core::model::{AppLanguage, ZoomAnchor};
use eveo_core::support::StringEnum;

/// 俄文三种复数形式、英文单复数。
#[test]
fn plurals() {
    let ru = eveo_l10n::menu(AppLanguage::Ru);
    assert_eq!(ru.client_count(1), "1 клиент");
    assert_eq!(ru.client_count(3), "3 клиента");
    assert_eq!(ru.client_count(11), "11 клиентов");
    let en = eveo_l10n::menu(AppLanguage::En);
    assert_eq!(en.client_count(1), "1 client");
    assert_eq!(en.client_count(2), "2 clients");
}

/// 可选值与枚举的分支。
#[test]
fn selects() {
    let en = eveo_l10n::updates(AppLanguage::En);
    assert_eq!(en.progress_downloading("2 MB", None), "Downloading… 2 MB");
    assert_eq!(
        en.progress_downloading("2 MB", Some("9 MB")),
        "Downloading… 2 MB of 9 MB"
    );
    let settings = eveo_l10n::settings(AppLanguage::En);
    assert_eq!(settings.anchor_name(ZoomAnchor::Se), "Bottom right");
}

/// 数字格式：按语言写小数点，秒数的整数不带小数。
#[test]
fn number_formats() {
    assert_eq!(eveo_l10n::settings(AppLanguage::Ru).seconds(2.5), "2,5 с");
    assert_eq!(eveo_l10n::settings(AppLanguage::En).seconds(2.0), "2.0 s");
    assert_eq!(eveo_l10n::combat(AppLanguage::De).seconds(2.5), "2,5 s");
    assert_eq!(eveo_l10n::combat(AppLanguage::En).seconds(3.0), "3 s");
}

/// 两端用词不同的文案取 Windows 的写法；只在 Windows 用的文案每种语言都有。
#[test]
fn windows_variants() {
    for language in AppLanguage::ALL {
        let settings = eveo_l10n::settings(*language);
        assert!(settings.about_subtitle().contains("Windows"), "{language:?}");
        assert!(!settings.search_settings().is_empty(), "{language:?}");
    }
    assert_eq!(
        eveo_l10n::diagnostics(AppLanguage::Zh).show_logs_button(),
        "在资源管理器中显示日志"
    );
}
