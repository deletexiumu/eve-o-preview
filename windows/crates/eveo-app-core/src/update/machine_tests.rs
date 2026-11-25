// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新状态机的用例：按 macOS UpdateController 的流程逐段走一遍（启动、定时检查、后台下载、空闲安装、
// 退出时安装、失败与跳过），每步核对阶段、发出的命令与 state.json 记录的变化。

use super::*;
use eveo_core::update::models::{InstallBlocker, ReleaseAsset};

/// 墙上时钟的起点，数值随意，只要各用例一致。
const T0: f64 = 1_800_000_000.0;

/// 正在运行 0.9.0 的正式版，能安装。
fn running() -> RunningApp {
    RunningApp {
        version: "0.9.0".into(),
        build_label: "0.9.0".into(),
        is_development: false,
        location_writable: true,
        has_signing_key: true,
    }
}

/// 一个 Windows 发布版，带压缩包附件（声明 1000 字节）。
fn release(version: &str) -> ReleaseInfo {
    let prefix = "https://github.com/deletexiumu/eve-o-preview/releases/";
    ReleaseInfo {
        version: version.into(),
        tag_name: format!("win-v{version}"),
        title: format!("win-v{version}"),
        notes: String::new(),
        page_url: format!("{prefix}tag/win-v{version}"),
        published_at: None,
        is_prerelease: false,
        is_draft: false,
        assets: vec![ReleaseAsset {
            name: archive_name(version),
            download_url: format!("{prefix}download/win-v{version}/{}", archive_name(version)),
            size: Some(1000),
            sha256: None,
            mirrors: Vec::new(),
        }],
    }
}

/// 一页列表，只含给出的版本。
fn list(versions: &[&str]) -> CheckOutcome {
    let releases = versions.iter().map(|v| release(v)).collect();
    CheckOutcome::List(
        ReleaseList {
            releases,
            is_full: false,
        },
        Some("etag-1".into()),
    )
}

/// 解出的新 exe。
fn prepared(version: &str) -> PreparedUpdate {
    PreparedUpdate {
        version: version.into(),
        exe_path: format!("C:\\cache\\EVE-O Preview-{version}.exe"),
        sha256: "00".repeat(32),
    }
}

/// 两个开关都打开。
fn both_on() -> Switches {
    Switches {
        check: true,
        auto_install: true,
    }
}

/// 建状态机并启动（没有 prepared 文件）。
fn started(switches: Switches, state: &mut UpdateState) -> UpdateMachine {
    let mut machine = UpdateMachine::new(running(), UpdateFeed::production(), switches);
    machine.start(state, T0, false);
    machine
}

/// 启动后第一次醒来：10 秒后检查一次，之前不检查；没有缓存时不带 ETag。
/// 推迟 10 秒是为了不和启动时的窗口枚举、缩略图注册抢时间，与 macOS 相同。
#[test]
fn first_wake_checks() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    assert!(machine.tick(&mut state, T0 + 5.0, true).is_empty());
    assert_eq!(
        machine.tick(&mut state, T0 + 10.0, true),
        [Command::Check { etag: None }]
    );
    // 检查进行中不再发第二次；一小时后醒来时距上次检查不到 24 小时，也不检查。
    machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.0"]));
    assert_eq!(state.last_check_at, Some(T0 + 11.0));
    assert!(
        machine
            .tick(&mut state, T0 + 10.0 + WAKE_INTERVAL, true)
            .is_empty()
    );
}

/// 自动检查 → 后台下载 → 待安装 → 空闲满 1 分钟安装 → 重新启动。
/// 这是默认设置下用户看到的完整流程：除了托盘菜单的提示项，全程不打扰。
#[test]
fn background_install_flow() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.tick(&mut state, T0 + 10.0, true);
    // 第一次醒来发检查；答复里有 0.9.1，两个开关都开着，直接在后台下载，不通知。
    let commands = machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.1", "0.9.0"]));
    assert_eq!(commands, [Command::Prepare(release("0.9.1"))]);
    assert_eq!(state.cached_release, Some(release("0.9.1")));
    assert_eq!(state.etag.as_deref(), Some("etag-1"));
    // 下载的进度：没收齐时是下载中，收齐时进入核对中（算签名与校验和、解包）。
    machine.progress(Progress {
        received: 400,
        total: Some(1000),
    });
    assert!(matches!(machine.phase(), UpdatePhase::Downloading(_, p) if p.received == 400));
    machine.progress(Progress {
        received: 1000,
        total: Some(1000),
    });
    assert!(matches!(machine.phase(), UpdatePhase::Verifying(_)));
    // 核对与解包通过：进入「待安装」，托盘菜单出现「重新启动以更新」。
    assert!(
        machine
            .prepare_finished(&mut state, T0 + 20.0, Ok(prepared("0.9.1")))
            .is_empty()
    );
    assert_eq!(machine.phase(), &UpdatePhase::ReadyToInstall(release("0.9.1")));
    assert_eq!(machine.menu_hint(), MenuHint::Ready("0.9.1".into()));
    // 有客户端在运行时不装；客户端都关了，满 1 分钟才装。
    assert!(machine.tick(&mut state, T0 + 30.0, true).is_empty());
    assert!(machine.tick(&mut state, T0 + 40.0, false).is_empty());
    assert!(machine.tick(&mut state, T0 + 90.0, true).is_empty());
    assert!(machine.tick(&mut state, T0 + 100.0, false).is_empty());
    let commands = machine.tick(&mut state, T0 + 160.0, false);
    assert_eq!(
        commands,
        [Command::Install {
            prepared: prepared("0.9.1"),
            relaunch: true
        }]
    );
    assert!(machine.is_busy());
    // 替换成功：待确认的记录写进 state，缓存里的新 exe 删掉，接着启动新版。
    let swap = PendingSwap {
        version: "0.9.1".into(),
        from_version: "0.9.0".into(),
        at: T0 + 161.0,
        launched_at: None,
    };
    let commands = machine.install_finished(&mut state, T0 + 161.0, Ok(swap.clone()));
    assert_eq!(
        commands,
        [Command::DeleteFile(prepared("0.9.1").exe_path), Command::Relaunch]
    );
    assert_eq!(state.pending_swap, Some(swap));
    assert_eq!(state.prepared, None);
    assert_eq!(machine.phase(), &UpdatePhase::Relaunching);
    // 启动新版失败：窗口提示手动重新打开。
    assert_eq!(
        machine.relaunch_did_fail(),
        [Command::ShowWindow { activate: true }]
    );
    assert!(machine.relaunch_failed());
}

/// 自动安装关闭：进入「可用」，同一个版本只通知一次。
/// 每天的自动检查都会得到同一个版本，反复弹通知会让人想关掉自动检查。
#[test]
fn notify_once() {
    let mut state = UpdateState::default();
    let switches = Switches {
        check: true,
        auto_install: false,
    };
    let mut machine = started(switches, &mut state);
    machine.tick(&mut state, T0 + 10.0, true);
    // 自动安装关着：发现新版本只通知，托盘菜单出现「有可用更新」。
    let commands = machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.1"]));
    assert_eq!(commands, [Command::Notify("0.9.1".into())]);
    assert_eq!(machine.menu_hint(), MenuHint::Available("0.9.1".into()));
    // 一天后再查，版本没变（304）：不再通知。
    let later = T0 + 11.0 + policy::CHECK_INTERVAL + WAKE_INTERVAL;
    assert_eq!(
        machine.tick(&mut state, later, true),
        [Command::Check {
            etag: Some("etag-1".into())
        }]
    );
    assert!(
        machine
            .check_finished(&mut state, later, CheckOutcome::NotModified)
            .is_empty()
    );
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
}

/// 用户发起的检查：已是最新、有新版本、检查失败都显示窗口；被限流时不发请求。
#[test]
fn user_checks() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    // 用户点「检查更新」：先显示窗口（检查中），再发请求。
    let commands = machine.check_now(&mut state, T0 + 1.0);
    assert_eq!(
        commands,
        [
            Command::ShowWindow { activate: true },
            Command::Check { etag: None }
        ]
    );
    assert_eq!(machine.phase(), &UpdatePhase::Checking);
    let commands = machine.check_finished(&mut state, T0 + 2.0, list(&["0.9.0"]));
    assert_eq!(commands, [Command::ShowWindow { activate: true }]);
    assert_eq!(machine.phase(), &UpdatePhase::UpToDate(T0 + 2.0));
    // 关窗口后回到空闲。
    machine.later(&state);
    assert_eq!(machine.phase(), &UpdatePhase::Idle);
    // 有新版本时即使自动安装打开也只显示窗口，等用户点安装。
    machine.check_now(&mut state, T0 + 3.0);
    machine.check_finished(&mut state, T0 + 4.0, list(&["0.9.2"]));
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.2")));
    // 检查失败：显示失败；记录里的检查时刻不变。
    machine.check_now(&mut state, T0 + 5.0);
    // 失败的原因原样显示在窗口里；网络错误的说明来自系统，不含地址。
    let error = UpdateError::Network("timeout".into());
    machine.check_finished(&mut state, T0 + 6.0, CheckOutcome::Failed(error.clone()));
    assert_eq!(machine.phase(), &UpdatePhase::Failed(error, None));
    assert_eq!(state.last_check_at, Some(T0 + 4.0));
    // 「稍后」：按记录回到「可用」。
    machine.later(&state);
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.2")));
    // 被限流：记下时刻；限流期间用户再点检查，不发请求，直接显示限流。
    // 限流的答复带着可以再试的时刻，窗口按它显示「请在某时之后再试」。
    machine.check_now(&mut state, T0 + 7.0);
    machine.check_finished(&mut state, T0 + 8.0, CheckOutcome::RateLimited(Some(T0 + 600.0)));
    assert_eq!(state.rate_limited_until, Some(T0 + 600.0));
    machine.later(&state);
    let commands = machine.check_now(&mut state, T0 + 9.0);
    assert_eq!(commands, [Command::ShowWindow { activate: true }]);
    assert_eq!(
        machine.phase(),
        &UpdatePhase::Failed(UpdateError::RateLimited(Some(T0 + 600.0)), None)
    );
}

/// 自动检查失败：阶段不变、不显示窗口、不写检查时刻。
/// 不写检查时刻，下一次醒来（1 小时后）就会重试，而不是等 24 小时。
#[test]
fn automatic_failure_is_silent() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.tick(&mut state, T0 + 10.0, true);
    let commands = machine.check_finished(
        &mut state,
        T0 + 11.0,
        CheckOutcome::Failed(UpdateError::HttpStatus(502)),
    );
    assert!(commands.is_empty());
    assert_eq!(machine.phase(), &UpdatePhase::Idle);
    assert_eq!(state.last_check_at, None);
}

/// 用户点安装：先下载再安装；替换失败时记 lastInstall，失败过的版本不再自动安装。
#[test]
fn install_failure_blocks_auto_install() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.check_now(&mut state, T0 + 1.0);
    machine.check_finished(&mut state, T0 + 2.0, list(&["0.9.1"]));
    // 用户检查到 0.9.1 后点「安装更新」：还没有下载，先下载；下载好之后直接安装，不进「待安装」。
    assert_eq!(machine.install(&mut state), [Command::Prepare(release("0.9.1"))]);
    let commands = machine.prepare_finished(&mut state, T0 + 3.0, Ok(prepared("0.9.1")));
    assert_eq!(
        commands,
        [Command::Install {
            prepared: prepared("0.9.1"),
            relaunch: true
        }]
    );
    // 被占用（错误码 32）：记失败，新 exe 留着；窗口切到前台显示原因（用户点的）。
    let commands = machine.install_finished(&mut state, T0 + 4.0, Err(UpdateError::ReplaceFailed(32)));
    assert_eq!(commands, [Command::ShowWindow { activate: true }]);
    let record = state.last_install.clone().unwrap();
    assert_eq!(
        (
            record.version.as_str(),
            record.succeeded,
            record.error_code.as_deref()
        ),
        ("0.9.1", false, Some("replaceFailed"))
    );
    assert_eq!(state.prepared, Some(prepared("0.9.1")));
    // 关窗口：失败过的版本不进「待安装」，只普通提示。
    machine.later(&state);
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
    // 一天后的自动检查也不在后台下载，只通知。
    let later = T0 + 2.0 + policy::CHECK_INTERVAL;
    machine.tick(&mut state, later, true);
    let commands = machine.check_finished(&mut state, later, CheckOutcome::NotModified);
    assert_eq!(commands, [Command::Notify("0.9.1".into())]);
}

/// 校验和不符时丢掉缓存里的 exe。
/// 坏掉的文件留着只会每次安装都失败；丢掉之后，下一次安装会重新下载。
#[test]
fn broken_prepared_is_deleted() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.tick(&mut state, T0 + 10.0, true);
    machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.1"]));
    machine.prepare_finished(&mut state, T0 + 12.0, Ok(prepared("0.9.1")));
    // 托盘菜单的「重新启动以更新」：直接安装已下载的 exe，不再下载。
    assert_eq!(machine.restart_to_install(&mut state).len(), 1);
    // 安装前再算一次 SHA-256 发现不符：删掉缓存里的 exe；自动发起的安装失败时窗口不抢焦点。
    let commands = machine.install_finished(&mut state, T0 + 13.0, Err(UpdateError::ChecksumMismatch));
    assert_eq!(
        commands,
        [
            Command::DeleteFile(prepared("0.9.1").exe_path),
            Command::ShowWindow { activate: false }
        ]
    );
    assert_eq!(state.prepared, None);
}

/// 退出时安装：只在待安装时装，不重新启动；装好后不发 Relaunch。
#[test]
fn install_on_quit() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.tick(&mut state, T0 + 10.0, true);
    machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.1"]));
    machine.prepare_finished(&mut state, T0 + 12.0, Ok(prepared("0.9.1")));
    // 已下载好时退出：安装，但不启动新版。
    let commands = machine.quit(&mut state);
    assert_eq!(
        commands,
        [Command::Install {
            prepared: prepared("0.9.1"),
            relaunch: false
        }]
    );
    let swap = PendingSwap {
        version: "0.9.1".into(),
        from_version: "0.9.0".into(),
        at: T0 + 13.0,
        launched_at: None,
    };
    let commands = machine.install_finished(&mut state, T0 + 13.0, Ok(swap));
    assert_eq!(commands, [Command::DeleteFile(prepared("0.9.1").exe_path)]);
    // 退出之后不再自动安装。
    assert!(machine.tick(&mut state, T0 + 200.0, false).is_empty());
    // 没有下载好时退出什么都不做。
    let mut fresh = UpdateState::default();
    let mut idle = started(both_on(), &mut fresh);
    assert!(idle.quit(&mut fresh).is_empty());
}

/// 跳过此版本：自动检查不再提示，用户检查仍提示；已下载的同一版本一并删掉。
/// 更新的版本（0.9.2）出来时照常提示：跳过只针对一个版本号。
#[test]
fn skip_version() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.tick(&mut state, T0 + 10.0, true);
    machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.1"]));
    machine.prepare_finished(&mut state, T0 + 12.0, Ok(prepared("0.9.1")));
    // 「跳过此版本」：记下版本号，删掉已下载的 exe，回到空闲。
    let commands = machine.skip(&mut state);
    assert_eq!(commands, [Command::DeleteFile(prepared("0.9.1").exe_path)]);
    assert_eq!(state.skipped_version.as_deref(), Some("0.9.1"));
    assert_eq!(machine.phase(), &UpdatePhase::Idle);
    let later = T0 + 11.0 + policy::CHECK_INTERVAL;
    machine.tick(&mut state, later, true);
    assert!(
        machine
            .check_finished(&mut state, later, CheckOutcome::NotModified)
            .is_empty()
    );
    assert_eq!(machine.phase(), &UpdatePhase::Idle);
    // 用户自己检查时仍提示被跳过的版本。
    machine.check_now(&mut state, later + 1.0);
    machine.check_finished(&mut state, later + 2.0, CheckOutcome::NotModified);
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
}

/// 取消下载：回到「可用」。
/// 取消是用户的选择，不记失败：之后的自动安装照常进行。
#[test]
fn cancel_download() {
    let mut state = UpdateState::default();
    let mut machine = started(both_on(), &mut state);
    machine.check_now(&mut state, T0 + 1.0);
    machine.check_finished(&mut state, T0 + 2.0, list(&["0.9.1"]));
    machine.install(&mut state);
    // 下载中点「取消」：发出取消，下载任务以 Cancelled 结束。
    assert_eq!(machine.cancel(), [Command::CancelPrepare]);
    machine.prepare_finished(&mut state, T0 + 3.0, Err(UpdateError::Cancelled));
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
    // 取消不算失败。
    assert_eq!(state.last_install, None);
}

/// 只提示的构建：「安装更新」打开发布页；不在后台下载。
/// 例如用户把 exe 放在 Program Files 下：普通权限换不了文件，只能请用户自己下载。
#[test]
fn notify_only() {
    let mut state = UpdateState::default();
    let mut app = running();
    app.location_writable = false;
    let mut machine = UpdateMachine::new(app, UpdateFeed::production(), both_on());
    assert_eq!(
        machine.capability(),
        InstallCapability::NotifyOnly(InstallBlocker::LocationNotWritable)
    );
    machine.start(&mut state, T0, false);
    machine.tick(&mut state, T0 + 10.0, true);
    let commands = machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.1"]));
    assert_eq!(commands, [Command::Notify("0.9.1".into())]);
    assert_eq!(
        machine.install(&mut state),
        [Command::OpenUrl(release("0.9.1").page_url)]
    );
}

/// 版本号解析不了的构建：更新功能整个停用。
/// 本机自己编译、没有写版本号的构建就是这样：不检查、不提示，托盘菜单也没有「检查更新」。
#[test]
fn unavailable() {
    let mut state = UpdateState::default();
    let mut app = running();
    app.version = "debug".into();
    app.build_label = "debug".into();
    let mut machine = UpdateMachine::new(app, UpdateFeed::production(), both_on());
    assert!(machine.start(&mut state, T0, false).is_empty());
    assert!(machine.tick(&mut state, T0 + 100.0, true).is_empty());
    assert!(machine.check_now(&mut state, T0 + 100.0).is_empty());
}

/// 启动时的恢复：文件不在的下载记录清掉；别的地址留下的缓存丢掉；已下载好的恢复成「待安装」。
#[test]
fn restore_on_start() {
    // UpdateState 有私有字段，不能用结构体更新语法，先取默认值再逐个设。
    let mut state = UpdateState::default();
    state.cached_release = Some(release("0.9.1"));
    state.prepared = Some(prepared("0.9.1"));
    state.etag = Some("e".into());
    let mut machine = UpdateMachine::new(running(), UpdateFeed::production(), both_on());
    assert!(machine.start(&mut state.clone(), T0, true).is_empty());
    let mut restored = state.clone();
    machine.start(&mut restored, T0, true);
    assert_eq!(machine.phase(), &UpdatePhase::ReadyToInstall(release("0.9.1")));
    // 文件不在：记录清掉，阶段退为「可用」。
    let mut missing = state.clone();
    let mut machine = UpdateMachine::new(running(), UpdateFeed::production(), both_on());
    machine.start(&mut missing, T0, false);
    assert_eq!(missing.prepared, None);
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
    // 已经装上了（正在运行的就是 0.9.1）：文件删掉。
    let mut app = running();
    app.version = "0.9.1".into();
    app.build_label = "0.9.1".into();
    let mut machine = UpdateMachine::new(app, UpdateFeed::production(), both_on());
    let mut installed = state.clone();
    assert_eq!(
        machine.start(&mut installed, T0, true),
        [Command::DeleteFile(prepared("0.9.1").exe_path)]
    );
    assert_eq!(machine.phase(), &UpdatePhase::Idle);
    // 测试地址下，正式地址的缓存与 ETag 丢掉。
    let feed = UpdateFeed::resolve(Some("http://127.0.0.1:8123/releases.json"));
    let mut machine = UpdateMachine::new(running(), feed, both_on());
    machine.start(&mut state, T0, false);
    assert_eq!((state.cached_release.clone(), state.etag.clone()), (None, None));
}

/// 上次运行检查到新版本、没下完就退出，1 小时内重新启动：第一次醒来时不检查（不到最小间隔），
/// 但缓存的版本仍该提示、两个开关都开着，接着在后台下载；只开自动检查时保持「可用」，不发命令。
#[test]
fn resume_download_at_launch() {
    let mut state = UpdateState::default();
    state.cached_release = Some(release("0.9.1"));
    state.last_check_at = Some(T0 - 600.0);
    // 10 分钟前检查过：启动时那一次检查要求至少隔 1 小时（policy::is_check_due），所以第一次醒来不会检查。
    // 没有 prepared 记录（上次下载被退出打断），阶段按缓存恢复成「可用」。
    let mut machine = started(both_on(), &mut state.clone());
    let mut resumed = state.clone();
    machine.start(&mut resumed, T0, false);
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
    assert_eq!(
        machine.tick(&mut resumed, T0 + 10.0, true),
        [Command::Prepare(release("0.9.1"))]
    );
    // 之后每小时醒来时不再重复（已经在下载中）。
    // 下载中时 is_busy 为真，自动检查让开；at_launch 也只在第一次醒来时为真。
    assert!(
        machine
            .tick(&mut resumed, T0 + 10.0 + WAKE_INTERVAL, true)
            .is_empty()
    );
    // 自动安装关着：不下载，也不重复通知（启动时恢复的「可用」只在托盘菜单里提示）。
    let only_check = Switches {
        check: true,
        auto_install: false,
    };
    let mut quiet = state.clone();
    let mut machine = started(only_check, &mut quiet);
    assert!(machine.tick(&mut quiet, T0 + 10.0, true).is_empty());
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
}

/// 开关：关掉自动检查时不再检查；打开时立即判断一次；关掉自动安装时「待安装」退为「可用」。
#[test]
fn switches() {
    let mut state = UpdateState::default();
    let off = Switches {
        check: false,
        auto_install: true,
    };
    let mut machine = started(off, &mut state);
    assert!(machine.tick(&mut state, T0 + 10.0, true).is_empty());
    // 打开自动检查：从没检查过，立即检查。
    let commands = machine.switches_changed(&mut state, T0 + 20.0, both_on());
    assert_eq!(commands, [Command::Check { etag: None }]);
    machine.check_finished(&mut state, T0 + 21.0, list(&["0.9.1"]));
    machine.prepare_finished(&mut state, T0 + 22.0, Ok(prepared("0.9.1")));
    assert!(matches!(machine.phase(), UpdatePhase::ReadyToInstall(_)));
    let manual = Switches {
        check: true,
        auto_install: false,
    };
    // 关掉自动安装：已下载的 exe 留着，但不再空闲时安装，界面退为「可用」。
    machine.switches_changed(&mut state, T0 + 23.0, manual);
    assert_eq!(machine.phase(), &UpdatePhase::Available(release("0.9.1")));
}

/// 检查时顺便取中间版本的说明：0.9.0 < v < 0.9.3 的两个版本，新的在前。
#[test]
fn intermediate_notes() {
    let mut state = UpdateState::default();
    let mut machine = started(
        Switches {
            check: true,
            auto_install: false,
        },
        &mut state,
    );
    machine.tick(&mut state, T0 + 10.0, true);
    // 列表的顺序打乱（补发的旧版本可能排在前面）；记录按版本号从新到旧排。
    machine.check_finished(&mut state, T0 + 11.0, list(&["0.9.3", "0.9.1", "0.9.2", "0.9.0"]));
    let notes = state.intermediate_notes.clone().unwrap();
    let versions: Vec<_> = notes.entries.iter().map(|e| e.version.as_str()).collect();
    assert_eq!(versions, ["0.9.2", "0.9.1"]);
    assert_eq!(notes.latest_version, "0.9.3");
    assert!(!notes.has_more);
}
