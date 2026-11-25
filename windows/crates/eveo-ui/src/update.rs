// SPDX-License-Identifier: GPL-3.0-or-later
//
// 软件更新窗口的绑定（ui/update.slint）。窗口只显示：阶段、标题、副标题、进度与发布说明都由应用层按更新状态机的
// 阶段算好，装进 UpdateView 交给这里；用户的操作经 UpdateModel 的回调交回应用。
// 发布说明：每个版本的正文先按界面语言取一块（Core 的 notes::section），去掉 macOS 的小节（notes::platform_only），
// 再切成标题、段落、列表项、代码（notes::blocks），换成窗口的块。最新版在前，不加小标题；中间版本各加一个「版本 x.y.z」的小标题。
// 文件大小用十进制单位（KB、MB），保留一位小数，与资源管理器的习惯一致。

//! 软件更新窗口。

use eveo_core::model::AppLanguage;
use eveo_core::update::notes::{self, ReleaseNotesBlock};
use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

use crate::{NotesBlock, UpdateModel, UpdateWindow};

/// 窗口的阶段，数值与 update.slint 的 UpdateModel.phase 相同。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhaseKind {
    /// 检查中。
    Checking = 0,
    /// 已是最新。
    UpToDate = 1,
    /// 可用。
    Available = 2,
    /// 下载中。
    Downloading = 3,
    /// 核对中。
    Verifying = 4,
    /// 待安装。
    Ready = 5,
    /// 安装中。
    Installing = 6,
    /// 重新启动中。
    Relaunching = 7,
    /// 失败。
    Failed = 8,
}

/// 窗口要显示的全部内容。
#[derive(Debug, Clone, PartialEq)]
pub struct UpdateView {
    /// 阶段。
    pub phase: PhaseKind,
    /// 大标题。
    pub headline: String,
    /// 副标题；空串表示没有。
    pub subtitle: String,
    /// 只提示的构建的说明；空串表示能安装。
    pub notify_only: String,
    /// 是否使用测试地址。
    pub test_feed: bool,
    /// 发布说明的块。
    pub notes: Vec<NotesBlock>,
    /// 是否还有更早的中间版本没有列出。
    pub more_on_release_page: bool,
    /// 下载进度 0～1；None 表示不定。
    pub progress: Option<f32>,
    /// 进度旁的文字。
    pub progress_text: String,
    /// 失败时是否带着发布版。
    pub has_release: bool,
    /// 重新启动没有成功。
    pub relaunch_failed: bool,
}

/// 按语言填窗口的固定文字。
pub fn set_language(window: &UpdateWindow, language: AppLanguage) {
    crate::l10n::apply_update(window, language);
}

/// 把内容写进窗口。
pub fn apply(window: &UpdateWindow, view: &UpdateView) {
    let model = window.global::<UpdateModel>();
    model.set_phase(view.phase as i32);
    model.set_headline(SharedString::from(view.headline.as_str()));
    model.set_subtitle(SharedString::from(view.subtitle.as_str()));
    model.set_notify_only(SharedString::from(view.notify_only.as_str()));
    model.set_test_feed(view.test_feed);
    // 说明的内容变了才换模型：下载进度每秒更新几次，每次都换会让滚动位置跳回顶部。
    let notes = model.get_notes();
    let current: Vec<NotesBlock> = notes.iter().collect();
    if current != view.notes {
        model.set_notes(ModelRc::new(VecModel::from(view.notes.clone())));
    }
    model.set_more_on_release_page(view.more_on_release_page);
    model.set_progress(view.progress.unwrap_or(-1.0));
    model.set_progress_text(SharedString::from(view.progress_text.as_str()));
    model.set_has_release(view.has_release);
    model.set_relaunch_failed(view.relaunch_failed);
}

/// 本平台在发布说明里的小标题。
const OWN_HEADING: &str = "Windows";

/// 发布说明换成窗口的块。versions 是（版本号，正文），最新版在前；第一个不加小标题。
/// version_title 生成中间版本的小标题（「版本 0.9.1」）。
pub fn notes_blocks(
    language: AppLanguage,
    versions: &[(&str, &str)],
    version_title: impl Fn(&str) -> String,
) -> Vec<NotesBlock> {
    let mut result = Vec::new();
    for (index, (version, body)) in versions.iter().enumerate() {
        // 只留 Windows 的小节：两个平台共用一份说明，macOS 的改动不显示（docs/update-manifest.md 第 4 节）。
        let section = notes::section(language, body);
        let blocks = notes::blocks(&notes::platform_only(&section, OWN_HEADING));
        // 没有内容的版本（正文为空）不列出，免得只剩一个孤零零的小标题。
        if blocks.is_empty() {
            continue;
        }
        if index > 0 {
            result.push(NotesBlock {
                kind: 4,
                text: version_title(version).into(),
                level: 0,
            });
        }
        result.extend(blocks.into_iter().map(block));
    }
    result
}

/// 一块说明换成窗口的块。编号列表的序号拼进文字，按列表项画（不加圆点的写法要另一个种类，没有必要）。
fn block(source: ReleaseNotesBlock) -> NotesBlock {
    let (kind, text, level) = match source {
        ReleaseNotesBlock::Heading { level, text } => (0, text, level),
        ReleaseNotesBlock::Paragraph(text) => (1, text, 0),
        ReleaseNotesBlock::Bullet { depth, text } => (2, text, depth),
        ReleaseNotesBlock::Numbered { number, text } => (2, format!("{number}. {text}"), 0),
        ReleaseNotesBlock::Code(text) => (3, text, 0),
    };
    NotesBlock {
        kind,
        text: text.into(),
        // 层级不会超过几十；万一超出 i32 就按最大值画（缩进由界面限制在窗口内）。
        level: i32::try_from(level).unwrap_or(i32::MAX),
    }
}

/// 字节数写成「12.3 MB」：十进制单位，保留一位小数；小于 1 KB 时写字节数。
pub fn byte_size(bytes: u64) -> String {
    // 与问题报告窗口的写法一致（资源管理器的「大小」一栏也是这样）。
    const UNITS: [&str; 3] = ["KB", "MB", "GB"];
    if bytes < 1_000 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64 / 1_000.0;
    let mut unit = 0;
    while value >= 1_000.0 && unit < UNITS.len() - 1 {
        value /= 1_000.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 最新版不加小标题；中间版本各加一个；空正文的版本跳过；按界面语言选块。
    #[test]
    fn builds_blocks() {
        let latest = "<!-- lang:en -->\n## Fixes\n- one\n  - two\n1. first\n<!-- /lang:en -->\n<!-- lang:zh -->\n## 修复\n- 一\n<!-- /lang:zh -->";
        let blocks = notes_blocks(
            AppLanguage::Zh,
            &[("0.9.2", latest), ("0.9.1", ""), ("0.9.0", "Plain paragraph.")],
            |v| format!("版本 {v}"),
        );
        let kinds: Vec<(i32, &str)> = blocks.iter().map(|b| (b.kind, b.text.as_str())).collect();
        assert_eq!(
            kinds,
            [(0, "修复"), (2, "一"), (4, "版本 0.9.0"), (1, "Plain paragraph.")]
        );
        // 英文界面：嵌套的列表项带层级，编号拼进文字。
        let english = notes_blocks(AppLanguage::En, &[("0.9.2", latest)], |v| v.to_owned());
        assert_eq!(english[2].level, 1);
        assert_eq!(english[3].text.as_str(), "1. first");
    }

    /// 大小的写法。
    #[test]
    fn sizes() {
        assert_eq!(byte_size(999), "999 B");
        assert_eq!(byte_size(1_500), "1.5 KB");
        assert_eq!(byte_size(21_400_000), "21.4 MB");
        assert_eq!(byte_size(3_000_000_000), "3.0 GB");
    }
}
