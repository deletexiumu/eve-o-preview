// SPDX-License-Identifier: GPL-3.0-or-later
//
// 数据位置（架构文档 4.10 节）：
// - 配置：%APPDATA%\EVE-O Preview\config.json、state.json、session.json，含义与 macOS 相同。
// - 日志与缓存：%LOCALAPPDATA%\EVE-O Preview\logs\、cache\。
// 环境变量由调用方读出后传进来（`DataPaths::from_env` 是便捷写法），这样在 Linux 上也能测试。

//! 配置、状态、日志与缓存的位置。

use std::path::{Path, PathBuf};

/// 应用数据目录的名字，与 macOS 的 Application Support 子目录同名。
pub const APP_DIR_NAME: &str = "EVE-O Preview";

/// 各类数据的位置。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataPaths {
    /// 漫游数据目录：`%APPDATA%\EVE-O Preview`。
    pub roaming: PathBuf,
    /// 本机数据目录：`%LOCALAPPDATA%\EVE-O Preview`。
    pub local: PathBuf,
}

impl DataPaths {
    /// 由 `%APPDATA%` 与 `%LOCALAPPDATA%` 的值建。`LOCALAPPDATA` 缺失时退回漫游目录。
    pub fn new(app_data: impl AsRef<Path>, local_app_data: Option<&Path>) -> Self {
        let roaming = app_data.as_ref().join(APP_DIR_NAME);
        let local = local_app_data.map_or_else(|| roaming.clone(), |dir| dir.join(APP_DIR_NAME));
        Self { roaming, local }
    }

    /// 读当前进程的环境变量。`APPDATA` 缺失时返回 `None`（正常的 Windows 账户总有它）。
    pub fn from_env() -> Option<Self> {
        let app_data = std::env::var_os("APPDATA")?;
        let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
        Some(Self::new(PathBuf::from(app_data), local.as_deref()))
    }

    /// 配置文件。
    pub fn config_file(&self) -> PathBuf {
        self.roaming.join("config.json")
    }

    /// 应用状态文件（补过的一次性默认值等）。
    pub fn state_file(&self) -> PathBuf {
        self.roaming.join("state.json")
    }

    /// 会话标记文件，用于发现上次异常退出。
    pub fn session_file(&self) -> PathBuf {
        self.roaming.join("session.json")
    }

    /// 日志目录。
    pub fn logs_dir(&self) -> PathBuf {
        self.local.join("logs")
    }

    /// 问题报告的压缩包所在的目录（只留最新的 3 个）。
    pub fn reports_dir(&self) -> PathBuf {
        self.local.join("Reports")
    }

    /// 缓存目录（译文缓存、人名缓存）。
    pub fn cache_dir(&self) -> PathBuf {
        self.local.join("cache")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 各文件的位置与架构文档 4.10 节一致：配置在漫游目录，日志与缓存在本机目录。
    #[test]
    fn layout_matches_architecture_doc() {
        let paths = DataPaths::new("/r", Some(Path::new("/l")));
        assert_eq!(paths.config_file(), Path::new("/r/EVE-O Preview/config.json"));
        assert_eq!(paths.state_file(), Path::new("/r/EVE-O Preview/state.json"));
        assert_eq!(paths.session_file(), Path::new("/r/EVE-O Preview/session.json"));
        assert_eq!(paths.logs_dir(), Path::new("/l/EVE-O Preview/logs"));
        assert_eq!(paths.cache_dir(), Path::new("/l/EVE-O Preview/cache"));
    }

    /// 极少数精简系统没有 LOCALAPPDATA，日志退回到漫游目录下，而不是写到当前目录。
    #[test]
    fn missing_local_app_data_falls_back_to_roaming() {
        let paths = DataPaths::new("/r", None);
        assert_eq!(paths.logs_dir(), Path::new("/r/EVE-O Preview/logs"));
    }
}
