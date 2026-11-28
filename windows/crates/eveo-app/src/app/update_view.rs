// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新窗口与「通用」页的视图拼装：把更新状态机的阶段、state.json 记录与多语言文案转成 `UpdateView`
// 与设置页状态行。纯转换逻辑从 `updates.rs` 拆出，避免运行时主文件超过 1000 行上限，同时缓存已渲染的
// Markdown 发布说明块，避免主循环 250ms 定时器反复重建 `StyledText`。
//
// 缓存失效条件：
// - 最新版本号变化（检查到更高版本）；
// - 界面语言变化（实时切换语言时按新语言重新截取并渲染对应语言块）；
// - 中间版本说明列表变化（后台拉取或更新清单刷新）。
// 以上三项均未变时直接复用缓存的 `Vec<NotesBlock>`，下载进度刷新不再触发 Markdown 重解析。

//! 更新窗口与「通用」页的视图构建。

use eveo_app_core::state_store::UpdateState;
use eveo_app_core::update::machine::{UpdateMachine, UpdatePhase};
use eveo_core::model::AppLanguage;
use eveo_core::update::models::{InstallBlocker, InstallCapability, UpdateError};
use eveo_ui::update::{PhaseKind, UpdateView};

use super::super::intel::wall_clock;
use super::super::update_launch::version_label;

/// 缓存已渲染好的发布说明块，避免定时器每 250 毫秒重解析 Markdown。
///
/// 窗口打开期间，下载进度或状态文字每次刷新都会重建 `UpdateView`，但发布说明本身只在
/// 目标版本、界面语言或中间版本摘要变化时才改变。缓存命中时直接克隆 `Vec<NotesBlock>`，
/// 避免把八语发布说明反复送进 `StyledText::from_markdown`。
pub(super) struct NotesCache {
    /// 最新版本号（含前缀无关的规范版本字符串，来自 `ReleaseInfo::version`）。
    version: String,
    /// 最新版本的发布说明原文（同版本原地改说明时能及时失效）。
    notes: String,
    /// 当前界面语言（切换语言时重新截取对应 `<!-- lang:xx -->` 块）。
    language: AppLanguage,
    /// 对应的中间版本说明快照（后台历史拉取完成后触发刷新）。
    intermediate: Option<eveo_core::update::history::IntermediateReleaseNotes>,
    /// 渲染好的 Slint 富文本说明块列表。
    blocks: Vec<eveo_ui::NotesBlock>,
    /// 中间版本数量超过上限时置为真，提示用户可点「查看完整更新日志」。
    more: bool,
}

/// 时刻写成本地的「yyyy-MM-dd HH:mm」。
///
/// 时差按此刻的本地时区算（含夏令时）；记录里的时刻离现在最多几天，跨过夏令时切换的误差可以忽略。
/// 用于「通用」设置页的「上次检查时间」与限流恢复时刻展示。
pub(super) fn local_date_time(time: f64) -> String {
    let shifted = time + eveo_platform_win::events::local_offset_seconds();
    // ISO 8601 的「2026-11-24T16:30:00Z」取日期与时分，去掉秒数与时区尾缀。
    let text = eveo_core::support::time::iso8601_seconds(shifted);
    format!("{} {}", &text[..10], &text[11..16])
}

/// 时刻写成本地的「HH:mm」（限流的「请在 HH:mm 之后再试」）。
/// 直接截用 `local_date_time` 的时分切片，保证与日期时间使用同一本地偏移口径。
fn local_time(time: f64) -> String {
    local_date_time(time)[11..].to_owned()
}

/// 不能安装的原因写成一句话。
///
/// 原因接在「此版本只能提示更新。」之后显示，告诉用户为什么没有「安装更新」按钮、该怎么办：
/// - `LocationNotWritable`：安装目录无写权限，需移至可写目录或手动覆盖；
/// - `DevelopmentBuild`：开发构建未带正式签名配置，不支持自更新；
/// - `NoSigningKey`：构建时未嵌入校验公钥，拒绝执行未验签替换。
fn blocker_text(blocker: InstallBlocker, language: AppLanguage) -> String {
    let text = eveo_l10n::updates(language);
    match blocker {
        InstallBlocker::LocationNotWritable => text.blocker_location_not_writable(),
        InstallBlocker::DevelopmentBuild => text.blocker_development_build(),
        InstallBlocker::NoSigningKey => text.blocker_no_signing_key(),
    }
    .to_owned()
}

/// 错误写成一句话；取消时是空串。
///
/// 错误的细节（HTTP 状态码以外的内部原因）只写进日志：用户能做的只有重试或去发布页手动下载，
/// 多写几种措辞只会让人困惑。
fn error_text(error: &UpdateError, language: AppLanguage) -> String {
    let text = eveo_l10n::updates(language);
    match error {
        UpdateError::Network(_) => text.error_network().to_owned(),
        UpdateError::HttpStatus(code) => text.error_http_status(i64::from(*code)),
        UpdateError::RateLimited(Some(until)) => text.status_rate_limited(&local_time(*until)),
        UpdateError::RateLimited(None) => text.status_rate_limited_later().to_owned(),
        UpdateError::MalformedFeed(_) => text.error_malformed_feed().to_owned(),
        UpdateError::AssetMissing(_) => text.error_asset_missing().to_owned(),
        UpdateError::InsufficientDiskSpace => text.error_disk_space().to_owned(),
        UpdateError::ChecksumListInvalid
        | UpdateError::ChecksumEntryMissing(_)
        | UpdateError::ChecksumMismatch => text.error_checksum().to_owned(),
        // 签名、解包、版本与架构的核对失败对用户都是「无法验证新版本」；具体原因在日志里。
        UpdateError::DownloadTooLarge
        | UpdateError::SignatureInvalid
        | UpdateError::ArchiveInvalid(_)
        | UpdateError::VersionMismatch { .. }
        | UpdateError::NotNewer
        | UpdateError::ArchitectureMismatch => text.error_verification().to_owned(),
        UpdateError::Blocked(blocker) => blocker_text(*blocker, language),
        UpdateError::ReplaceFailed(_) => text.error_swap_failed().to_owned(),
        UpdateError::Cancelled => String::new(),
    }
}

/// 窗口要显示的内容；空闲时没有（窗口关掉）。
///
/// 阶段与窗口的对应与 macOS 的 UpdateView 相同：
/// - 检查中、已是最新：只有标题与「关闭」；
/// - 可用、待安装：标题是「EVE-O Preview x.y.z 可用」，下面是发布说明；只提示的构建多一行原因；
/// - 下载中、核对中、安装中：标题不变，进度条与进度文字在说明下面；
/// - 重新启动中：标题换成「正在重新启动…」，启动失败时副标题请用户手动重新打开；
/// - 失败：副标题是失败原因（红字由界面按阶段决定），带着发布版时可以重试安装或打开发布页。
pub(super) fn build_view(
    machine: &UpdateMachine,
    state: &UpdateState,
    language: AppLanguage,
    notes_cache: &mut Option<NotesCache>,
) -> Option<UpdateView> {
    let text = eveo_l10n::updates(language);
    let current = text.current_version_line(version_label());
    let notify_only = match machine.capability() {
        InstallCapability::NotifyOnly(blocker) => {
            format!("{} {}", text.notify_only_intro(), blocker_text(blocker, language))
        }
        _ => String::new(),
    };
    // 发布说明：版本、语言与中间版本未变时复用缓存，避免 250ms 定时器反复重解析 Markdown。
    let mut notes_for = |release: &eveo_core::update::models::ReleaseInfo| {
        let intermediate = state
            .intermediate_notes
            .as_ref()
            .filter(|notes| notes.latest_version == release.version)
            .cloned();
        if let Some(cached) = notes_cache.as_ref()
            && cached.version == release.version
            && cached.notes == release.notes
            && cached.language == language
            && cached.intermediate == intermediate
        {
            return (cached.blocks.clone(), cached.more);
        }
        let mut versions: Vec<(&str, &str)> = vec![(release.version.as_str(), release.notes.as_str())];
        if let Some(notes) = &intermediate {
            versions.extend(
                notes
                    .entries
                    .iter()
                    .map(|e| (e.version.as_str(), e.notes.as_str())),
            );
        }
        let more = intermediate.as_ref().is_some_and(|notes| notes.has_more);
        let blocks = eveo_ui::update::notes_blocks(language, &versions, |v| text.version_notes_title(v));
        *notes_cache = Some(NotesCache {
            version: release.version.clone(),
            notes: release.notes.clone(),
            language,
            intermediate,
            blocks: blocks.clone(),
            more,
        });
        (blocks, more)
    };
    let mut view = UpdateView {
        phase: PhaseKind::Checking,
        background_downloading: machine.is_background_downloading(),
        headline: String::new(),
        subtitle: current.clone(),
        notify_only: String::new(),
        test_feed: machine.feed().is_test_feed,
        notes: Vec::new(),
        more_on_release_page: false,
        progress: None,
        progress_text: String::new(),
        has_release: false,
        relaunch_failed: machine.relaunch_failed(),
    };
    match machine.phase() {
        UpdatePhase::Idle => return None,
        UpdatePhase::Checking => view.headline = text.status_checking().to_owned(),
        UpdatePhase::UpToDate(_) => {
            view.phase = PhaseKind::UpToDate;
            view.headline = text.status_up_to_date().to_owned();
        }
        UpdatePhase::Available(release) | UpdatePhase::ReadyToInstall(release) => {
            let ready = matches!(machine.phase(), UpdatePhase::ReadyToInstall(_));
            view.phase = if ready {
                PhaseKind::Ready
            } else {
                PhaseKind::Available
            };
            view.headline = text.headline(&release.version);
            if ready {
                view.subtitle = text.status_ready(&release.version);
            }
            view.notify_only = notify_only;
            (view.notes, view.more_on_release_page) = notes_for(release);
        }
        UpdatePhase::Downloading(release, progress) => {
            view.phase = PhaseKind::Downloading;
            view.headline = text.headline(&release.version);
            view.progress = progress
                .total
                .filter(|&total| total > 0)
                .map(|total| (progress.received as f64 / total as f64).min(1.0) as f32);
            let received = eveo_ui::update::byte_size(progress.received);
            let total = progress.total.map(eveo_ui::update::byte_size);
            view.progress_text = text.progress_downloading(&received, total.as_deref());
            (view.notes, view.more_on_release_page) = notes_for(release);
        }
        UpdatePhase::Verifying(release) | UpdatePhase::Installing(release) => {
            let installing = matches!(machine.phase(), UpdatePhase::Installing(_));
            view.phase = if installing {
                PhaseKind::Installing
            } else {
                PhaseKind::Verifying
            };
            view.headline = text.headline(&release.version);
            view.progress_text = if installing {
                text.progress_installing()
            } else {
                text.progress_verifying()
            }
            .to_owned();
            (view.notes, view.more_on_release_page) = notes_for(release);
        }
        UpdatePhase::Relaunching => {
            view.phase = PhaseKind::Relaunching;
            view.headline = text.progress_relaunching().to_owned();
            if machine.relaunch_failed() {
                view.subtitle = text.reopen_manually().to_owned();
            }
        }
        UpdatePhase::Failed(error, release) => {
            view.phase = PhaseKind::Failed;
            view.has_release = release.is_some();
            view.headline = release
                .as_ref()
                .map_or_else(|| text.window_title().to_owned(), |r| text.headline(&r.version));
            // 安装失败时补一句「当前版本没有变化」，让用户放心。
            view.subtitle = match release {
                Some(_) => format!(
                    "{} {}",
                    error_text(error, language),
                    text.current_version_unchanged()
                ),
                None => error_text(error, language),
            };
        }
    }
    Some(view)
}

/// 「通用」页的状态行与「立即检查」能否点。
///
/// 状态行只写一句话：窗口里的细节（发布说明、进度）不放进设置页。
/// 正在检查、下载或安装时「立即检查」不能点，免得用户以为点了没反应又连点几次。
pub(super) fn settings_status(
    machine: &UpdateMachine,
    state: &UpdateState,
    language: AppLanguage,
) -> (String, bool) {
    let text = eveo_l10n::updates(language);
    if machine.capability() == InstallCapability::Unavailable {
        return (text.status_unavailable().to_owned(), false);
    }
    let status = match machine.phase() {
        UpdatePhase::Checking => text.status_checking().to_owned(),
        UpdatePhase::UpToDate(_) => text.status_up_to_date().to_owned(),
        UpdatePhase::Available(release) => text.status_available(&release.version),
        UpdatePhase::ReadyToInstall(release) => text.status_ready(&release.version),
        UpdatePhase::Downloading(release, _)
        | UpdatePhase::Verifying(release)
        | UpdatePhase::Installing(release) => text.headline(&release.version),
        UpdatePhase::Failed(error, _) => error_text(error, language),
        UpdatePhase::Relaunching => text.progress_relaunching().to_owned(),
        // 空闲时：被限流就说明，否则不写。
        UpdatePhase::Idle => match state.rate_limited_until.filter(|&until| until > wall_clock()) {
            Some(until) => text.status_rate_limited(&local_time(until)),
            None => String::new(),
        },
    };
    (status, !machine.is_busy())
}
