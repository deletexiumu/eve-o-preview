// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口当前的界面语言。Slint 页面上的文字在 l10n.slint 的全局里，由 l10n::apply 填；
// 另有一些文字由 Rust 拼好再交给页面（热键的问题提示、通用热键的名称、名称的问题等），
// 拼的时候要知道当前语言，这里记下它。设置窗口只在主线程上，用线程局部变量即可。

//! 设置窗口的界面语言。

use std::cell::Cell;

use eveo_core::model::AppLanguage;

use crate::SettingsWindow;

thread_local! {
    /// 当前语言。应用建窗口时就会设置；单元测试里没设时是英文，与 Slint 全局的初值一致。
    static LANGUAGE: Cell<AppLanguage> = const { Cell::new(AppLanguage::En) };
}

/// 换界面语言：填 Slint 全局里的文字，并记下语言供 Rust 拼文字时用。
/// 由 Rust 拼的文字（各页的 show_* 函数填的）要在换语言后重新填一次，调用方负责。
pub fn set_language(ui: &SettingsWindow, language: AppLanguage) {
    LANGUAGE.with(|cell| cell.set(language));
    crate::l10n::apply(ui, language);
}

/// 当前的界面语言。
pub fn language() -> AppLanguage {
    LANGUAGE.with(Cell::get)
}

/// 单元测试用：只改记下的语言，不碰窗口。
#[cfg(test)]
pub(crate) fn set_for_test(language: AppLanguage) {
    LANGUAGE.with(|cell| cell.set(language));
}
