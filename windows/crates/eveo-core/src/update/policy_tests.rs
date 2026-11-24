// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新决策规则的用例，移植 macOS 的 UpdatePolicyTests，另加 Windows 的渠道规则（正在运行预发布版时也提示预发布版）。

use super::*;
use crate::update::feed::PRODUCTION_ASSET_PREFIX;

/// 一个发布版。
fn release(version: &str, prerelease: bool, draft: bool) -> ReleaseInfo {
    ReleaseInfo {
        version: version.to_owned(),
        tag_name: format!("win-v{version}"),
        title: format!("EVE-O Preview {version}"),
        notes: String::new(),
        page_url: format!("{PRODUCTION_ASSET_PREFIX}tag/win-v{version}"),
        published_at: None,
        is_prerelease: prerelease,
        is_draft: draft,
        assets: Vec::new(),
    }
}

/// 一个正式发布版。
fn stable(version: &str) -> ReleaseInfo {
    release(version, false, false)
}

/// 正在运行的应用：版本、标签，其余取能安装的值。
fn running(version: &str, label: &str) -> RunningApp {
    RunningApp {
        version: version.to_owned(),
        build_label: label.to_owned(),
        is_development: false,
        location_writable: true,
        has_signing_key: true,
    }
}

/// 先取构建标签，标签解析不了时取版本号，都不行时是 None。
#[test]
fn comparable_version_prefers_label() {
    assert_eq!(
        comparable_version(&running("1.1.0", "1.1.0-pr.12.abc1234")),
        SemanticVersion::parse("1.1.0-pr.12.abc1234")
    );
    assert_eq!(
        comparable_version(&running("1.1.0", "release")),
        SemanticVersion::parse("1.1.0")
    );
    assert_eq!(comparable_version(&running("dev", "dev")), None);
}

/// 能否安装：按顺序取第一个成立的；开发构建在测试地址下可装。
#[test]
fn capability_table() {
    // 正式构建、有公钥、位置可写：能安装；版本号解析不了：停用。
    let base = running("0.9.0", "0.9.0");
    assert_eq!(capability(&base, false), InstallCapability::CanInstall);
    assert_eq!(
        capability(&running("x", "y"), false),
        InstallCapability::Unavailable
    );
    // 没有公钥排在最前：即使同时是开发构建、位置不可写，也报它。
    let no_key = RunningApp {
        has_signing_key: false,
        is_development: true,
        location_writable: false,
        ..base.clone()
    };
    assert_eq!(
        capability(&no_key, true),
        InstallCapability::NotifyOnly(InstallBlocker::NoSigningKey)
    );
    // 开发构建只在测试地址下可装。
    let dev = RunningApp {
        is_development: true,
        ..base.clone()
    };
    assert_eq!(
        capability(&dev, false),
        InstallCapability::NotifyOnly(InstallBlocker::DevelopmentBuild)
    );
    assert_eq!(capability(&dev, true), InstallCapability::CanInstall);
    // 位置不可写在测试地址下也不能装。
    let locked = RunningApp {
        location_writable: false,
        ..dev
    };
    assert_eq!(
        capability(&locked, true),
        InstallCapability::NotifyOnly(InstallBlocker::LocationNotWritable)
    );
}

/// 要不要提示：草稿、预发布（正式版渠道）、解析不了、不更新、跳过、提示。
#[test]
fn offer_table() {
    // 正在运行正式版 1.1.0，自动检查。
    let app = running("1.1.0", "1.1.0");
    let check = |r: &ReleaseInfo, skipped: Option<&str>| offer(r, &app, skipped, false);
    assert_eq!(
        check(&release("1.2.0", true, true), None),
        UpdateOffer::None(UpdateSkipReason::Draft)
    );
    assert_eq!(
        check(&release("1.2.0", true, false), None),
        UpdateOffer::None(UpdateSkipReason::Prerelease)
    );
    assert_eq!(
        check(&stable("1.2.0-beta.1"), None),
        UpdateOffer::None(UpdateSkipReason::Prerelease)
    );
    assert_eq!(
        check(&stable("latest"), None),
        UpdateOffer::None(UpdateSkipReason::UnparsableVersion)
    );
    assert_eq!(
        offer(&stable("1.2.0"), &running("x", "y"), None, false),
        UpdateOffer::None(UpdateSkipReason::UnparsableVersion)
    );
    assert_eq!(
        check(&stable("1.1.0"), None),
        UpdateOffer::None(UpdateSkipReason::NotNewer)
    );
    assert_eq!(
        check(&stable("1.0.9"), None),
        UpdateOffer::None(UpdateSkipReason::NotNewer)
    );
    assert_eq!(
        check(&stable("1.1.1"), Some("1.1.1")),
        UpdateOffer::None(UpdateSkipReason::SkippedByUser)
    );
    assert_eq!(check(&stable("1.1.1"), None), UpdateOffer::Offer(stable("1.1.1")));
    // 跳过的版本在用户发起时仍提示；更新的版本不受跳过影响。
    assert_eq!(
        offer(&stable("1.1.1"), &app, Some("1.1.1"), true),
        UpdateOffer::Offer(stable("1.1.1"))
    );
    assert_eq!(
        offer(&stable("1.1.2"), &app, Some("1.1.1"), false),
        UpdateOffer::Offer(stable("1.1.2"))
    );
}

/// CI 构建的标签小于同版本号的正式版，所以会收到提示；标签等于版本号时不提示同版本。
#[test]
fn build_label_drives_offer() {
    let pr = running("1.1.0", "1.1.0-pr.12.abc1234");
    assert_eq!(
        offer(&stable("1.1.0"), &pr, None, false),
        UpdateOffer::Offer(stable("1.1.0"))
    );
    assert_eq!(
        offer(&stable("1.1.0"), &running("1.1.0", "1.1.0"), None, true),
        UpdateOffer::None(UpdateSkipReason::NotNewer)
    );
}

/// 预发布的渠道：运行测试版时提示更新的测试版与正式版；运行正式版时只看正式版。
#[test]
fn prerelease_channel() {
    // 一页里有两个测试版、一个草稿测试版、一个旧正式版和一个版本号解析不了的项。
    let list = [
        release("0.9.0-beta.1", true, false),
        release("0.9.0-beta.3", true, false),
        release("0.9.1-beta.1", true, true),
        stable("0.8.0"),
        stable("garbage"),
    ];
    // 运行 beta.2：最新的是 beta.3（草稿不算），渠道里有 beta.1、beta.3 与 0.8.0。
    let beta = running("0.9.0", "0.9.0-beta.2");
    assert_eq!(
        latest(&list, &beta).map(|r| r.version.as_str()),
        Some("0.9.0-beta.3")
    );
    assert_eq!(
        offer(&list[1], &beta, None, false),
        UpdateOffer::Offer(list[1].clone())
    );
    assert_eq!(channel_releases(&list, &beta).len(), 3);
    // 运行正式版 0.8.0：只看正式版，最新的就是它自己（随后 offer 会判为不更新）。
    let release_app = running("0.8.0", "0.8.0");
    assert_eq!(
        latest(&list, &release_app).map(|r| r.version.as_str()),
        Some("0.8.0")
    );
    assert_eq!(channel_releases(&list, &release_app).len(), 1);
    assert_eq!(latest(&[], &release_app), None);
    // 测试版之后的正式版对测试版用户也提示。
    let with_final = [list[1].clone(), stable("0.9.0")];
    assert_eq!(
        latest(&with_final, &beta).map(|r| r.version.as_str()),
        Some("0.9.0")
    );
}

/// 自动检查：限流期间不检查；从未检查或时钟被调回时到时；启动时 1 小时、平时 24 小时。
#[test]
fn check_due() {
    // 现在的时刻与 macOS 用例相同。
    let now = 1_800_000_000.0;
    // 限流期间：即使从未检查过也不到时；限流已过：到时。
    assert!(!is_check_due(now, None, Some(now + 1.0), true));
    assert!(is_check_due(now, None, Some(now - 1.0), false));
    // 上次检查在未来（时钟被调回）：到时。
    assert!(is_check_due(now, Some(now + 100.0), None, false));
    // 启动时的间隔是 1 小时，平时是 24 小时，正好等于间隔时到时。
    assert!(!is_check_due(now, Some(now - 3_599.0), None, true));
    assert!(is_check_due(now, Some(now - 3_600.0), None, true));
    assert!(!is_check_due(now, Some(now - 86_399.0), None, false));
    assert!(is_check_due(now, Some(now - 86_400.0), None, false));
}

/// 新 exe 的核对：版本号要等于发布版本、比正在运行的新、架构相同。
#[test]
fn validate_staged_exe() {
    // 正在运行 0.9.0；staged 建一个解出来的 exe 的信息。
    let app = running("0.9.0", "0.9.0");
    let staged = |version: Option<&str>, label: Option<&str>, arch: bool| StagedExe {
        version: version.map(str::to_owned),
        build_label: label.map(str::to_owned),
        architecture_matches: arch,
    };
    assert_eq!(
        validate(&staged(Some("0.9.1"), None, true), "0.9.1", &app),
        Ok(())
    );
    assert_eq!(
        validate(&staged(Some("0.9.1"), Some(""), true), "0.9.1", &app),
        Ok(())
    );
    assert_eq!(
        validate(&staged(Some("0.9.2"), None, true), "0.9.1", &app),
        Err(UpdateError::VersionMismatch {
            expected: "0.9.1".into(),
            found: "0.9.2".into()
        })
    );
    assert_eq!(
        validate(&staged(None, None, true), "0.9.1", &app),
        Err(UpdateError::VersionMismatch {
            expected: "0.9.1".into(),
            found: String::new()
        })
    );
    assert_eq!(
        validate(&staged(Some("0.9.0"), None, true), "0.9.0", &app),
        Err(UpdateError::NotNewer)
    );
    assert_eq!(
        validate(&staged(Some("0.9.1"), Some("0.8.0"), true), "0.9.1", &app),
        Err(UpdateError::NotNewer)
    );
    assert_eq!(
        validate(&staged(Some("0.9.1"), None, false), "0.9.1", &app),
        Err(UpdateError::ArchitectureMismatch)
    );
}
