// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告窗口的绑定（ui/report.slint，v1.1 设计 7.4 节）。窗口只显示，不读文件、不脱敏：
// 应用把收集好的项（名称的种类、文件名、脱敏后的文字、替换次数、是否勾选）交给这里，
// 这里换成列表的行与预览；用户的操作经 ReportModel 的回调交回应用。
// - 名称：种类的名字取自界面文字（环境摘要、设置摘要、应用日志、崩溃报告 N、文件清单），日志另加文件名。
// - 大小：十进制单位（B、KB、MB），保留一位小数，与资源管理器的习惯一致。
// - 预览：超过 200,000 个字符时只显示开头，下方注明；文本框太长会卡。

//! 问题报告窗口。

use eveo_core::model::AppLanguage;
use slint::{ComponentHandle, ModelRc, VecModel};

use crate::{ProblemReportWindow, ReportFileRow, ReportModel};

/// 预览最多显示多少个字符。
pub const PREVIEW_LIMIT: usize = 200_000;

/// 列表一行的名称种类。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileKind {
    /// summary.md。
    Summary,
    /// config-summary.json。
    Config,
    /// 一个日志文件，带文件名。
    Log(String),
    /// 第 N 个崩溃报告。
    Crash(usize),
    /// manifest.json。
    Manifest,
}

/// 列表的一行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileView {
    /// 名称的种类。
    pub kind: FileKind,
    /// 脱敏后的字节数。
    pub bytes: usize,
    /// 能否取消勾选。
    pub optional: bool,
    /// 是否勾选。
    pub included: bool,
}

/// 按语言填窗口的文字。
pub fn set_language(window: &ProblemReportWindow, language: AppLanguage) {
    crate::l10n::apply_report(window, language);
}

/// 显示的名称：种类的名字，日志另加文件名。
pub fn file_name(kind: &FileKind, language: AppLanguage) -> String {
    let text = eveo_l10n::diagnostics(language);
    match kind {
        FileKind::Summary => text.item_summary().to_owned(),
        FileKind::Config => text.item_config().to_owned(),
        FileKind::Log(name) => format!("{} · {name}", text.item_log()),
        FileKind::Crash(number) => text.item_crash(*number as i64),
        FileKind::Manifest => text.item_manifest().to_owned(),
    }
}

/// 大小的写法：`512 B`、`12.3 KB`、`1.5 MB`（十进制）。
pub fn format_size(bytes: usize) -> String {
    // 1000 进位，与资源管理器的「大小」一列的习惯不同（它用 1024 却写 KB），这里与 macOS 版一致。
    match bytes {
        0..1000 => format!("{bytes} B"),
        1000..1_000_000 => format!("{:.1} KB", bytes as f64 / 1000.0),
        _ => format!("{:.1} MB", bytes as f64 / 1_000_000.0),
    }
}

/// 预览的文字：超过上限时只留开头，第二项为真。
pub fn preview(text: &str) -> (String, bool) {
    match text.char_indices().nth(PREVIEW_LIMIT) {
        Some((cut, _)) => (text[..cut].to_owned(), true),
        None => (text.to_owned(), false),
    }
}

/// 显示文件列表。selected 是选中的行。
pub fn show_files(window: &ProblemReportWindow, files: &[FileView], selected: usize, language: AppLanguage) {
    let rows: Vec<ReportFileRow> = files
        .iter()
        .map(|file| ReportFileRow {
            name: file_name(&file.kind, language).into(),
            size: format_size(file.bytes).into(),
            optional: file.optional,
            included: file.included,
        })
        .collect();
    let model = window.global::<ReportModel>();
    model.set_files(ModelRc::new(VecModel::from(rows)));
    model.set_selected(selected as i32);
}

/// 显示选中文件的预览与替换次数。
pub fn show_preview(window: &ProblemReportWindow, text: &str, replacements: usize) {
    let (shown, truncated) = preview(text);
    let model = window.global::<ReportModel>();
    model.set_preview(shown.into());
    model.set_preview_truncated(truncated);
    model.set_replacements(i32::try_from(replacements).unwrap_or(i32::MAX));
}

/// 切换窗口的状态：情境、是否在收集、是否在写、是否已完成、失败的原因。
pub fn show_state(window: &ProblemReportWindow, state: &ReportState) {
    let model = window.global::<ReportModel>();
    model.set_crash(state.crash);
    model.set_collecting(state.collecting);
    model.set_busy(state.busy);
    model.set_done(state.done);
    model.set_error(state.error.clone().into());
}

/// 窗口的状态。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReportState {
    /// 崩溃情境。
    pub crash: bool,
    /// 正在收集。
    pub collecting: bool,
    /// 正在写压缩包。
    pub busy: bool,
    /// 已生成。
    pub done: bool,
    /// 生成失败的原因；空串表示没有失败。
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 大小的三种单位。
    #[test]
    fn sizes() {
        assert_eq!(format_size(0), "0 B");
        assert_eq!(format_size(999), "999 B");
        assert_eq!(format_size(12_345), "12.3 KB");
        assert_eq!(format_size(2_097_152), "2.1 MB");
    }

    /// 预览：未超出时原样；超出时按字符截（不切断多字节字符）。
    #[test]
    fn previews() {
        assert_eq!(preview("short"), ("short".to_owned(), false));
        let long = "中".repeat(PREVIEW_LIMIT + 5);
        let (shown, truncated) = preview(&long);
        assert!(truncated);
        assert_eq!(shown.chars().count(), PREVIEW_LIMIT);
    }

    /// 名称：日志带文件名，崩溃报告带序号。
    #[test]
    fn names() {
        assert_eq!(file_name(&FileKind::Crash(2), AppLanguage::En), "Crash report 2");
        assert!(file_name(&FileKind::Log("a.log".into()), AppLanguage::En).ends_with(" · a.log"));
    }
}
