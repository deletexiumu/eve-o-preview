// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用里的诊断日志，对应 macOS 的 LogBootstrap.swift（docs/macos/design-v1.1.md 5.2、5.3 节）：
// - 启动：在读配置之前装上文件日志（读配置的错误才能进文件），写一行会话头，装 panic 钩子。
//   重复启动后自己退出的实例不装（它在 single_instance 那一步就返回了）。
//   环境变量 EVEO_LOG_DIR 可以换日志目录（与 macOS 相同，开发与测试用）。
// - 级别：`general.logLevel` 在 info 与 debug 之间切换（「通用」页的「详细日志」），配置变化时立即生效。
// - 退出：每一步的耗时都记下来。托盘「退出」在真机上要约 5 秒才结束，靠这些行找出慢在哪一步。
// 会话头只有版本、构建类别、架构与随机的会话编号，不含个人信息。

//! 启动时装上文件日志，退出时记下每一步的耗时。

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};
use std::time::Instant;

use eveo_app_core::config_store::ConfigWarning;
use eveo_app_core::log::{self, Logger};
use eveo_core::chat_log::ChatLogStatus;
use eveo_core::combat_log::CombatLogStatus;
use eveo_core::model::AppConfig;

/// 会话与退出的日志。
pub(super) const LOG: Logger = Logger::new("Session");

/// 日志目录：EVEO_LOG_DIR 有值时用它，否则是数据位置里的 logs。
pub(super) fn log_directory(default: PathBuf) -> PathBuf {
    std::env::var_os("EVEO_LOG_DIR")
        .filter(|value| !value.is_empty())
        .map_or(default, PathBuf::from)
}

/// 装上文件日志与 panic 钩子，写会话头。启动时、读配置之前调一次。
pub(super) fn start(directory: &Path) {
    log::install(directory);
    log::install_panic_hook();
    LOG.info(session_header());
}

/// 会话头。例：`会话开始 6f1d3c2a：版本 0.1.0，构建 release，x86_64`。
fn session_header() -> String {
    // 会话编号只用来在几份日志之间认出同一次运行；标准库的随机哈希种子足够，不必另加依赖。
    let mut hasher = RandomState::new().build_hasher();
    hasher.write_u32(std::process::id());
    let session = format!("{:08x}", hasher.finish() & 0xffff_ffff);
    let build = if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    };
    format!(
        "会话开始 {session}：版本 {}，构建 {build}，{}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::ARCH
    )
}

/// 按配置设最低级别（启动时与每次配置变化后）。级别变了时记一行。
pub(super) fn apply_level(config: &AppConfig) {
    let level = config.general.log_level;
    if log::minimum_level() != level {
        log::set_minimum_level(level);
        LOG.info(format_args!(
            "日志级别：{}",
            eveo_core::support::StringEnum::raw(level)
        ));
    }
}

/// 读配置时的警告各记一行。损坏文件的隔离位置去掉用户目录；改正过的字段只有字段路径，不含值。
pub(super) fn config_warning(warning: &ConfigWarning) {
    match warning {
        ConfigWarning::CreatedDefault => LOG.info("配置文件不存在，用默认配置"),
        ConfigWarning::Migrated { from, to } => {
            LOG.notice(format_args!("配置从版本 {from} 迁移到 {to}，原文件已备份"));
        }
        ConfigWarning::CorruptFileQuarantined(path) => LOG.error(format_args!(
            "配置文件损坏，已隔离到 {}，用默认配置",
            log::redact(&path.display().to_string())
        )),
        ConfigWarning::ValuesClamped(fields) => {
            LOG.notice(format_args!("配置里有值被改正：{}", fields.join("，")));
        }
    }
}

/// 跟踪服务的状态，拆成日志要的几项：状态名、目录（去掉用户目录）与跟踪的文件数。
struct WatchState {
    /// 状态名。
    state: &'static str,
    /// 目录；停止时没有。
    directory: Option<String>,
    /// 跟踪的文件数；只在正在跟踪时有。
    files: Option<usize>,
}

impl WatchState {
    /// 一行日志的文字：`<来源>：<状态>，<目录>，<文件数> 个文件`。
    fn text(&self, source: &str) -> String {
        let mut text = format!("{source}：{}", self.state);
        if let Some(directory) = &self.directory {
            text.push_str(&format!("，{}", log::redact(directory)));
        }
        if let Some(files) = self.files {
            text.push_str(&format!("，{files} 个文件"));
        }
        text
    }
}

impl From<&ChatLogStatus> for WatchState {
    fn from(status: &ChatLogStatus) -> Self {
        match status {
            ChatLogStatus::Stopped => watch("停止", None, None),
            ChatLogStatus::Watching {
                directory,
                followed_files,
            } => watch("正在跟踪", Some(directory), Some(*followed_files)),
            ChatLogStatus::DirectoryNotFound(directory) => watch("找不到目录", Some(directory), None),
            ChatLogStatus::AccessDenied(directory) => watch("没有读取权限", Some(directory), None),
        }
    }
}

impl From<&CombatLogStatus> for WatchState {
    fn from(status: &CombatLogStatus) -> Self {
        match status {
            CombatLogStatus::Stopped => watch("停止", None, None),
            CombatLogStatus::Watching {
                directory,
                followed_files,
            } => watch("正在跟踪", Some(directory), Some(*followed_files)),
            CombatLogStatus::DirectoryNotFound(directory) => watch("找不到目录", Some(directory), None),
            CombatLogStatus::AccessDenied(directory) => watch("没有读取权限", Some(directory), None),
        }
    }
}

/// 建一个 WatchState。
fn watch(state: &'static str, directory: Option<&str>, files: Option<usize>) -> WatchState {
    WatchState {
        state,
        directory: directory.map(str::to_owned),
        files,
    }
}

/// 跟踪服务的状态变了时记一行：状态名或目录变了记 info，只是文件数变了记 debug（文件多时会常变）。
fn watch_changed(source: &str, old: &WatchState, new: &WatchState) {
    if old.state != new.state || old.directory != new.directory {
        LOG.info(new.text(source));
    } else if old.files != new.files {
        LOG.debug(|| new.text(source));
    }
}

/// 聊天日志的跟踪状态变了。
pub(super) fn chat_status_changed(old: &ChatLogStatus, new: &ChatLogStatus) {
    watch_changed("聊天日志", &old.into(), &new.into());
}

/// 游戏日志的跟踪状态变了。
pub(super) fn combat_status_changed(old: &CombatLogStatus, new: &CombatLogStatus) {
    watch_changed("游戏日志", &old.into(), &new.into());
}

/// 退出时一步一步记耗时：`退出：<步骤> 用时 N 毫秒`，最后一行是总耗时。
#[derive(Debug)]
pub(super) struct QuitTimer {
    /// 开始退出的时刻。
    started: Instant,
    /// 上一步结束的时刻。
    last: Instant,
}

impl QuitTimer {
    /// 从现在开始计时，并记一行原因。
    pub(super) fn start(reason: &str) -> Self {
        LOG.info(format_args!("开始退出：{reason}"));
        let now = Instant::now();
        Self {
            started: now,
            last: now,
        }
    }

    /// 记下从上一步结束到现在的耗时，算作名为 name 的一步。
    pub(super) fn mark(&mut self, name: &str) {
        let now = Instant::now();
        LOG.info(format_args!(
            "退出：{name} 用时 {} 毫秒",
            now.duration_since(self.last).as_millis()
        ));
        self.last = now;
    }

    /// 执行一步并记下耗时；返回这一步的结果。
    pub(super) fn step<T>(&mut self, name: &str, work: impl FnOnce() -> T) -> T {
        self.last = Instant::now();
        let result = work();
        self.mark(name);
        result
    }

    /// 记总耗时并刷一次日志。
    pub(super) fn finish(self) {
        LOG.info(format_args!(
            "退出完成，共用时 {} 毫秒",
            self.started.elapsed().as_millis()
        ));
        log::flush();
    }
}
