// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「翻译」页的运行时状态，对应 macOS 的 SettingsViewModel+Translation.swift 里状态、Key、测试与缓存那几项。
// 配置（开关、频道、目标语言、模型服务、浮窗）在 chat 模块里整页显示与读回；这里只显示应用层算好的状态：
// - 状态行的文字与是否需要留意（暂停或等待时显示「立即重试」）、聊天日志的错误、接口设置不能用的原因。
// - Key 是否已保存在凭据管理器、保存或删除失败的说明；Key 的草稿只在输入框里，保存成功后由应用清空。
// - 「测试」是否在等答复与结果；译文缓存的条数。
// 文字都由应用层按界面语言算好（失败原因的写法在 eveo-app-core::translation::text），这里不再拼字符串，
// 只有缓存条数按 eveo-l10n 的复数规则写。值没变时不重写，免得打断正在输入的文字或闪烁。

//! 「翻译」页的状态、Key、测试与缓存。

use slint::ComponentHandle;

use crate::{SettingsWindow, TranslationModel};

/// 「翻译」页要显示的运行时状态。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TranslationView {
    /// 状态行的文字。
    pub status_text: String,
    /// 暂停或等待：状态行用醒目的颜色并附「立即重试」。
    pub needs_attention: bool,
    /// 聊天日志的错误说明；没有时为空。
    pub chat_log_problem: String,
    /// 接口设置不能用的原因；能用时为空。
    pub endpoint_issue: String,
    /// 当前预设的 Key 已在凭据管理器里。
    pub key_stored: bool,
    /// 当前预设是自定义接口（Key 可不填）。
    pub key_optional: bool,
    /// 保存或删除 Key 失败的说明；没有时为空。
    pub key_error: String,
    /// 「测试」在等答复。
    pub testing: bool,
    /// 测试结果的文字；还没测过时为空。
    pub test_result: String,
    /// 测试成功。
    pub test_succeeded: bool,
    /// 译文缓存的条数。
    pub cache_count: usize,
}

/// 把运行时状态显示到页上。只改变了的属性。
pub fn show_translation_view(ui: &SettingsWindow, view: &TranslationView) {
    let model = ui.global::<TranslationModel>();
    let text = eveo_l10n::translation(crate::language());
    set_text(&model.get_status_text(), &view.status_text, |v| {
        model.set_status_text(v)
    });
    model.set_needs_attention(view.needs_attention);
    set_text(&model.get_chat_log_problem(), &view.chat_log_problem, |v| {
        model.set_chat_log_problem(v)
    });
    set_text(&model.get_endpoint_issue(), &view.endpoint_issue, |v| {
        model.set_endpoint_issue(v)
    });
    model.set_key_stored(view.key_stored);
    model.set_key_optional(view.key_optional);
    set_text(&model.get_key_error(), &view.key_error, |v| {
        model.set_key_error(v)
    });
    model.set_testing(view.testing);
    set_text(&model.get_test_result(), &view.test_result, |v| {
        model.set_test_result(v)
    });
    model.set_test_succeeded(view.test_succeeded);
    // 条数超过 i64 不可能出现（缓存至多 10,000 条），转换失败时按上限写。
    let count = i64::try_from(view.cache_count).unwrap_or(i64::MAX);
    set_text(&model.get_cache_text(), &text.cache_count(count), |v| {
        model.set_cache_text(v)
    });
    model.set_cache_empty(view.cache_count == 0);
}

/// 清空 Key 的输入框（保存成功、或换了服务预设之后）。
pub fn clear_key_draft(ui: &SettingsWindow) {
    ui.global::<TranslationModel>().set_key_draft("".into());
}

/// 文字变了才写：Slint 的属性每写一次都会重新排版与重画。
fn set_text(current: &str, wanted: &str, set: impl FnOnce(slint::SharedString)) {
    if current != wanted {
        set(wanted.into());
    }
}
