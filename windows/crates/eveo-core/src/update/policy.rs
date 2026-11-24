// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新的决策规则（macOS v1.1 设计 8.3、8.5、8.6、9.1 节，移植 UpdatePolicy.swift；Windows 的差别见各函数）：
// - `comparable_version`：正在运行的版本，先取构建标签，再取版本号。
// - `capability`：这个构建能否自动安装。
// - `latest`：在一页列表里挑出要考虑的最新版（Windows 只取列表，macOS 由 `releases/latest` 直接给出）。
// - `offer`：一个发布版要不要提示。
// - `is_check_due`：自动检查是否到时。
// - `validate`：解出来的新 exe 能否安装。
//
// 预发布的渠道（Windows 才有的规则）：Windows 版先发 `win-v0.x` 的测试版，tag 带 `-beta.N`。正在运行的是预发布版
// （测试版或 CI 构建）时，也提示更新的预发布版；正在运行正式版时只提示正式版，与 macOS 相同。
// 全部是纯函数。

//! 更新的决策规则。

use super::models::{InstallBlocker, InstallCapability, ReleaseInfo, RunningApp, UpdateError};
use super::version::SemanticVersion;

/// 自动检查的间隔：24 小时。
pub const CHECK_INTERVAL: f64 = 86_400.0;
/// 启动时的检查与上一次检查至少相隔 1 小时。
pub const MINIMUM_LAUNCH_GAP: f64 = 3_600.0;

/// 不提示的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateSkipReason {
    /// 发布的版本不比正在运行的新。
    NotNewer,
    /// 用户选了「跳过此版本」，且这次是自动检查。
    SkippedByUser,
    /// 预发布版本，而正在运行的是正式版。
    Prerelease,
    /// 草稿。
    Draft,
    /// 发布的版本或正在运行的版本解析不了。
    UnparsableVersion,
}

/// 一次检查的决定。
#[derive(Debug, Clone, PartialEq)]
pub enum UpdateOffer {
    /// 不提示，关联值是原因。
    None(UpdateSkipReason),
    /// 提示这个发布版。
    Offer(ReleaseInfo),
}

/// 解出来的新 exe 的信息，由平台层从 exe 的版本资源读出。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StagedExe {
    /// 版本资源里的产品版本（如 `0.9.1`）；读不到时是 None。
    pub version: Option<String>,
    /// 版本资源里的构建标签；没有时取版本号。
    pub build_label: Option<String>,
    /// PE 头的机器类型与本机（正在运行的 exe）相同。
    pub architecture_matches: bool,
}

/// 正在运行的版本：先解析构建标签，失败时解析版本号，都失败时返回 None。
pub fn comparable_version(running: &RunningApp) -> Option<SemanticVersion> {
    SemanticVersion::parse(&running.build_label).or_else(|| SemanticVersion::parse(&running.version))
}

/// 这个构建能否自动安装（按顺序取第一个成立的）：
/// 1. 版本号解析不了：更新功能停用。
/// 2. 没有内置公钥：只提示。
/// 3. 开发构建，且不是测试地址：只提示。
/// 4. exe 所在的文件夹不可写：只提示。
pub fn capability(running: &RunningApp, is_test_feed: bool) -> InstallCapability {
    if comparable_version(running).is_none() {
        return InstallCapability::Unavailable;
    }
    if !running.has_signing_key {
        return InstallCapability::NotifyOnly(InstallBlocker::NoSigningKey);
    }
    if running.is_development && !is_test_feed {
        return InstallCapability::NotifyOnly(InstallBlocker::DevelopmentBuild);
    }
    if !running.location_writable {
        return InstallCapability::NotifyOnly(InstallBlocker::LocationNotWritable);
    }
    InstallCapability::CanInstall
}

/// 发布版是不是预发布：标志或版本号带预发布标识。
fn is_prerelease(release: &ReleaseInfo, version: &SemanticVersion) -> bool {
    release.is_prerelease || version.is_prerelease()
}

/// 这个渠道收不收预发布版：正在运行的是预发布版时收。
fn accepts_prerelease(running: Option<&SemanticVersion>) -> bool {
    running.is_some_and(SemanticVersion::is_prerelease)
}

/// 在一页列表里挑出版本号最高、渠道允许的发布版（跳过草稿与版本号解析不了的）；没有时返回 None。
pub fn latest<'a>(releases: &'a [ReleaseInfo], running: &RunningApp) -> Option<&'a ReleaseInfo> {
    // 渠道只看正在运行的版本：测试版用户也收测试版，正式版用户只收正式版。
    let prerelease_ok = accepts_prerelease(comparable_version(running).as_ref());
    releases
        .iter()
        .filter(|release| !release.is_draft)
        .filter_map(|release| Some((SemanticVersion::parse(&release.version)?, release)))
        .filter(|(version, release)| prerelease_ok || !is_prerelease(release, version))
        .max_by(|a, b| a.0.cmp(&b.0))
        .map(|(_, release)| release)
}

/// 列表里渠道允许的发布版（不含草稿），给中间版本的说明用。
pub fn channel_releases<'a>(releases: &'a [ReleaseInfo], running: &RunningApp) -> Vec<&'a ReleaseInfo> {
    let prerelease_ok = accepts_prerelease(comparable_version(running).as_ref());
    releases
        .iter()
        .filter(|release| !release.is_draft)
        .filter(|release| {
            SemanticVersion::parse(&release.version)
                .is_some_and(|version| prerelease_ok || !is_prerelease(release, &version))
        })
        .collect()
}

/// 一个发布版要不要提示（按顺序取第一个成立的）。「跳过此版本」只影响自动检查：user_initiated 为真时仍提示。
pub fn offer(
    release: &ReleaseInfo,
    running: &RunningApp,
    skipped_version: Option<&str>,
    user_initiated: bool,
) -> UpdateOffer {
    if release.is_draft {
        return UpdateOffer::None(UpdateSkipReason::Draft);
    }
    let release_version = SemanticVersion::parse(&release.version);
    let running_version = comparable_version(running);
    let flagged = release.is_prerelease
        || release_version
            .as_ref()
            .is_some_and(SemanticVersion::is_prerelease);
    if flagged && !accepts_prerelease(running_version.as_ref()) {
        return UpdateOffer::None(UpdateSkipReason::Prerelease);
    }
    let (Some(release_version), Some(running_version)) = (release_version, running_version) else {
        return UpdateOffer::None(UpdateSkipReason::UnparsableVersion);
    };
    // 同号或更旧都不提示（构建信息不参与比较）。
    if running_version >= release_version {
        return UpdateOffer::None(UpdateSkipReason::NotNewer);
    }
    if !user_initiated && skipped_version.and_then(SemanticVersion::parse) == Some(release_version) {
        return UpdateOffer::None(UpdateSkipReason::SkippedByUser);
    }
    UpdateOffer::Offer(release.clone())
}

/// 自动检查是否到时（按顺序）：
/// 1. `rate_limited_until` 晚于现在时不到时。
/// 2. `last_check_at` 为 None 或晚于现在（时钟被调回）时到时。
/// 3. at_launch 为真时看是否已过 1 小时，否则看是否已过 24 小时。
pub fn is_check_due(
    now: f64,
    last_check_at: Option<f64>,
    rate_limited_until: Option<f64>,
    at_launch: bool,
) -> bool {
    if rate_limited_until.is_some_and(|until| until > now) {
        return false;
    }
    let Some(last) = last_check_at.filter(|&last| last <= now) else {
        return true;
    };
    let gap = if at_launch {
        MINIMUM_LAUNCH_GAP
    } else {
        CHECK_INTERVAL
    };
    now - last >= gap
}

/// 核对解出来的新 exe（依次核对，第一项不成立时返回错误）：
/// 1. 版本资源里的版本号等于发布的版本（`VersionMismatch`）。
/// 2. 构建标签（没有时取版本号）大于正在运行的版本（`NotNewer`）。
/// 3. 机器类型与本机相同（`ArchitectureMismatch`）。
pub fn validate(staged: &StagedExe, release_version: &str, running: &RunningApp) -> Result<(), UpdateError> {
    // 读不到版本资源时按空串报告，日志里能看出是哪种情况。
    let found = staged.version.clone().unwrap_or_default();
    let matches = match (
        SemanticVersion::parse(&found),
        SemanticVersion::parse(release_version),
    ) {
        (Some(found), Some(expected)) => found == expected,
        _ => false,
    };
    if !matches {
        return Err(UpdateError::VersionMismatch {
            expected: release_version.to_owned(),
            found,
        });
    }
    // 新 exe 自己的构建标签比版本号更细（例如同号的 CI 构建），有就用它。
    let label = staged
        .build_label
        .as_deref()
        .filter(|label| !label.is_empty())
        .unwrap_or(&found);
    let newer = match (SemanticVersion::parse(label), comparable_version(running)) {
        (Some(staged), Some(running)) => running < staged,
        _ => false,
    };
    if !newer {
        return Err(UpdateError::NotNewer);
    }
    if !staged.architecture_matches {
        return Err(UpdateError::ArchitectureMismatch);
    }
    Ok(())
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
