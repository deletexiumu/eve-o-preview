// SPDX-License-Identifier: GPL-3.0-or-later
//
// 启动时处理上一次自动更新换上的 exe（docs/windows/architecture.md 6.3 节第 5、6 条，规则在 eveo_core::update::install）：
// - 旧版换好 exe 后带 `--after-update <旧进程编号>` 启动新版：新版先等旧进程退出（最多 15 秒），
//   再做单实例检查，否则会把自己当成第二个实例退出。
// - 读 state.json 的 updates.pendingSwap，按 install::on_launch 的结论处理：
//   - 第一次启动：记下启动时刻并写盘，运行满 30 秒（定时器里检查）或在此之前正常退出时确认：
//     写一条成功的安装记录、清掉待确认的替换、删除 `.old`。
//   - 启动过一次却没有确认：回滚（自己改名为 `.failed`、`.old` 改回 exe），写一条失败的安装记录，
//     带 `--after-update <本进程编号> --background` 启动旧版，本进程退出。
//   - 版本对不上：丢掉记录照常启动；没有记录时顺手删掉遗留的 `.new`、`.old`、`.failed`。
// - 本进程不是以正式文件名运行（例如用户直接双击了 `.old`）时什么都不做，免得删掉或换掉别的副本。
// 这一步在建 App 之前、预警模块读 state.json 之前完成，用自己读的 StateStore 写盘；之后的确认经 App 的
// StateStore（chat.state）写，两者不会同时持有改动。日志只写版本号与错误码，不写路径。

//! 自动更新换上的 exe：启动时的确认与回滚。

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use eveo_app_core::log::Logger;
use eveo_app_core::paths::DataPaths;
use eveo_app_core::state_store::StateStore;
use eveo_core::update::install::{self, AFTER_UPDATE_ARG, LaunchDecision, PendingSwap};
use eveo_platform_win::update;

use super::App;
use super::intel::wall_clock;

/// 更新的日志。
const LOG: Logger = Logger::new("Update");
/// 等旧进程退出的上限（毫秒）。旧进程启动新版之后立即退出，正常不到 1 秒。
const WAIT_PREVIOUS_MS: u32 = 15_000;
/// exe 的正式文件名；以别的名字运行时不处理更新。
const EXE_FILE_NAME: &str = "EVE-O Preview.exe";

/// 本构建的版本标签：打包时由环境变量 EVEO_BUILD_LABEL 给出（如 `0.9.1`、`0.9.1-ci.42`），没有时是版本号。
/// 与 exe 版本资源里的 BuildLabel 相同（见 build.rs），更新时用它比较新旧。
///
/// 调试构建可以用环境变量 EVEO_DEBUG_VERSION_LABEL 覆盖它（必须是合法的版本号），让旧进程自称旧版本，
/// 在真机上跑完整的下载、替换与重新启动；正式构建忽略这个变量。重新启动新版时去掉它（见 platform 的 launch）。
pub(super) fn version_label() -> &'static str {
    #[cfg(debug_assertions)]
    {
        static OVERRIDE: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
        let label = OVERRIDE.get_or_init(|| {
            std::env::var(update::DEBUG_VERSION_LABEL_ENV)
                .ok()
                .filter(|label| eveo_core::update::version::SemanticVersion::parse(label).is_some())
        });
        if let Some(label) = label.as_deref() {
            return label;
        }
    }
    option_env!("EVEO_BUILD_LABEL").unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// 带 `--after-update <编号>` 启动时等那个进程退出。在单实例检查之前调用。
pub(super) fn wait_for_previous_instance() {
    if let Some(pid) = install::after_update_pid(std::env::args()) {
        // 等不到也照常往下走：单实例检查会处理旧进程还在的情形（打开它的设置窗口，本进程退出）。
        let _ = update::wait_for_exit(pid, WAIT_PREVIOUS_MS);
    }
}

/// 启动时的结果。
pub(super) enum Startup {
    /// 照常启动；带着确认的状态。
    Continue(UpdateLaunch),
    /// 已回滚并启动了旧版，本进程应立即退出。
    Exit,
}

/// 等待确认的状态：新版第一次启动后才有内容。
#[derive(Debug, Default)]
pub(super) struct UpdateLaunch {
    /// 正在运行的 exe 的路径。
    exe: Option<PathBuf>,
    /// 待确认的替换。
    pending: Option<PendingSwap>,
    /// 何时确认。
    confirm_at: Option<Instant>,
}

/// 本进程的 exe 路径；不是以正式文件名运行时返回 None。
pub(super) fn own_exe() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let name = exe.file_name()?.to_str()?;
    name.eq_ignore_ascii_case(EXE_FILE_NAME).then_some(exe)
}

/// 处理待确认的替换。在日志装好之后、建 App 之前调用。
pub(super) fn start(paths: &DataPaths) -> Startup {
    let Some(exe) = own_exe() else {
        return Startup::Continue(UpdateLaunch::default());
    };
    let mut store = StateStore::load(paths.state_file());
    let pending = store.state().updates.pending_swap.clone();
    match install::on_launch(pending.as_ref(), version_label()) {
        LaunchDecision::Normal => {
            let removed = update::clean_up(&exe);
            if removed > 0 {
                LOG.info(format_args!("删掉了上次更新留下的 {removed} 个文件"));
            }
            Startup::Continue(UpdateLaunch::default())
        }
        LaunchDecision::Abandon => {
            LOG.notice("待确认的更新与正在运行的版本不符，丢掉这条记录");
            save(&mut store, |updates| updates.pending_swap = None);
            update::clean_up(&exe);
            Startup::Continue(UpdateLaunch::default())
        }
        LaunchDecision::AwaitConfirmation => {
            // pending 在这个分支里一定有值（on_launch 只在有记录时给出这个结论）。
            let Some(mut pending) = pending else {
                return Startup::Continue(UpdateLaunch::default());
            };
            pending.launched_at = Some(wall_clock());
            LOG.info(format_args!(
                "从 {} 更新到 {} 后第一次启动，运行 {} 秒后确认",
                pending.from_version,
                pending.version,
                install::CONFIRM_DELAY
            ));
            let record = pending.clone();
            save(&mut store, |updates| updates.pending_swap = Some(record));
            Startup::Continue(UpdateLaunch {
                exe: Some(exe),
                pending: Some(pending),
                confirm_at: Some(Instant::now() + Duration::from_secs_f64(install::CONFIRM_DELAY)),
            })
        }
        LaunchDecision::RollBack => roll_back(&exe, &mut store, pending),
    }
}

/// 回滚到旧版并启动它。回滚失败时丢掉记录照常启动（新版至少能用，不再来回换）。
fn roll_back(exe: &Path, store: &mut StateStore, pending: Option<PendingSwap>) -> Startup {
    let Some(pending) = pending else {
        return Startup::Continue(UpdateLaunch::default());
    };
    LOG.error(format_args!(
        "{} 上次启动后没有确认（崩溃或被结束），回滚到 {}",
        pending.version, pending.from_version
    ));
    let record = install::rolled_back(&pending, wall_clock());
    save(store, |updates| {
        updates.pending_swap = None;
        updates.last_install = Some(record);
    });
    if let Err(code) = update::roll_back(exe) {
        LOG.error(format_args!(
            "回滚失败：错误码 {code}，继续运行 {}",
            pending.version
        ));
        return Startup::Continue(UpdateLaunch::default());
    }
    // 与正常的重新启动一样带 --background：用户没有主动打开应用，换回旧版后不弹设置窗口。
    let args = [
        AFTER_UPDATE_ARG.to_owned(),
        std::process::id().to_string(),
        "--background".to_owned(),
    ];
    match update::launch(exe, &args) {
        Ok(_) => {
            LOG.notice("已换回旧版并启动它，本进程退出");
            Startup::Exit
        }
        // 旧版启动不了：文件已经换回，下次用户自己启动的就是旧版；本进程照常运行这一次。
        Err(code) => {
            LOG.error(format_args!("启动旧版失败：错误码 {code}"));
            Startup::Continue(UpdateLaunch::default())
        }
    }
}

/// 改 state.json 的更新记录并写盘；写不了时记日志。
fn save(store: &mut StateStore, change: impl FnOnce(&mut eveo_app_core::state_store::UpdateState)) {
    if let Err(error) = store.update_updates(change) {
        LOG.error(format_args!("写 state.json 失败：{:?}", error.kind()));
    }
}

impl App {
    /// 定时器里调用：新版运行满 30 秒时确认。
    pub(super) fn check_update_confirmation(&mut self, now: Instant) {
        if self.update_launch.confirm_at.is_some_and(|at| now >= at) {
            self.confirm_update("运行满 30 秒");
        }
    }

    /// 确认这次更新成功：写安装记录、清掉待确认的替换、删除 `.old`。正常退出时也调用（reason 写进日志）。
    pub(super) fn confirm_update(&mut self, reason: &str) {
        let launch = std::mem::take(&mut self.update_launch);
        let (Some(pending), Some(exe)) = (launch.pending, launch.exe) else {
            return;
        };
        let record = install::confirmed(&pending, wall_clock());
        let result = self.chat.state.update_updates(|updates| {
            updates.pending_swap = None;
            updates.last_install = Some(record);
        });
        if let Err(error) = result {
            LOG.error(format_args!("写 state.json 失败：{:?}", error.kind()));
        }
        let removed = update::clean_up(&exe);
        LOG.notice(format_args!(
            "更新到 {} 成功（{reason}），删掉旧文件 {removed} 个",
            pending.version
        ));
    }
}
