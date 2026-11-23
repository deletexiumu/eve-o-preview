// SPDX-License-Identifier: GPL-3.0-or-later
//
// 基于 JSON 文件的配置存储，对应 macOS 的 JSONFileConfigStore（架构文档 5.2 节 load() 表）：
// 文件不存在返回默认配置；损坏时改名隔离；旧版本先备份再迁移；新版本报错且不碰文件。
// 隔离文件名里的时间由调用方按本地时区格式化后传入（`yyyyMMdd-HHmmss`），这样这里只用标准库，测试也稳定。

//! `config.json` 的读写。

use std::fmt;
use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use eveo_core::config::{CURRENT_SCHEMA_VERSION, ConfigError, decode, encode, new_id, normalized};
use eveo_core::model::AppConfig;

/// 读配置时出现、但不妨碍继续运行的情况，由设置窗口提示用户。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigWarning {
    /// 配置文件不存在，返回了默认配置（尚未写盘）。
    CreatedDefault,
    /// 配置从旧版本迁移到了当前版本，原文件已备份。
    Migrated {
        /// 旧版本。
        from: i64,
        /// 当前版本。
        to: i64,
    },
    /// 配置文件损坏，已改名隔离，关联值是隔离后的位置。
    CorruptFileQuarantined(PathBuf),
    /// 有越界或不一致的值被改正，关联值是字段路径，如 `profiles[0].thumbnail.opacity`。
    ValuesClamped(Vec<String>),
}

/// 读写文件时出错的那一步。界面按它显示本地化的说明。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileOperation {
    /// 读配置文件。
    Read,
    /// 写配置文件。
    Write,
    /// 把损坏的配置文件改名隔离。
    Quarantine,
    /// 迁移前备份旧版本的配置文件。
    Backup,
}

/// 读写配置的错误。出现时应用用默认配置运行，本次会话不写盘，避免用默认值覆盖用户的文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    /// 配置文件来自更新的版本。
    NewerSchema {
        /// 文件里的版本。
        found: i64,
        /// 本版本支持的最高版本。
        supported: i64,
    },
    /// 读写文件失败：出错的那一步、涉及的文件、系统给出的说明。
    Io {
        /// 出错的那一步。
        operation: FileOperation,
        /// 涉及的文件。
        path: PathBuf,
        /// 系统给出的说明。
        reason: String,
    },
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::NewerSchema { found, supported } => {
                write!(f, "配置文件的版本 {found} 比本版本支持的 {supported} 新")
            }
            StoreError::Io {
                operation,
                path,
                reason,
            } => {
                write!(f, "{operation:?} {} 失败：{reason}", path.display())
            }
        }
    }
}

impl std::error::Error for StoreError {}

/// [`JsonFileConfigStore::load`] 的结果：已迁移、已校验的配置与警告。
#[derive(Debug, Clone, PartialEq)]
pub struct LoadResult {
    /// 可直接使用的配置。
    pub config: AppConfig,
    /// 读取过程中的警告，按发生顺序。
    pub warnings: Vec<ConfigWarning>,
}

/// 把配置保存为一个 JSON 文件的存储。只做文件读写，不缓存；调用方在主线程串行调用。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonFileConfigStore {
    /// 配置文件的位置。
    path: PathBuf,
}

impl JsonFileConfigStore {
    /// 用配置文件的位置建一个存储。目录可以不存在，保存时创建。
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// 配置文件的位置。
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 读取配置，结果已迁移到当前版本并经过校验。`stamp` 是本地时间 `yyyyMMdd-HHmmss`，只用于隔离文件名。
    ///
    /// | 情况 | 行为 |
    /// | --- | --- |
    /// | 文件不存在 | 返回默认配置，警告 `CreatedDefault`，不写盘 |
    /// | JSON 损坏或结构不符 | 原文件改名为 `config.corrupt-<stamp>.json`，返回默认配置 |
    /// | 版本较旧 | 先复制为 `config.v<旧版本>.bak.json`，再迁移，警告 `Migrated`；迁移结果不写盘 |
    /// | 版本较新 | 返回 `NewerSchema`，文件不改名、不备份 |
    /// | 读文件失败（含路径是目录） | 返回 `Io` |
    ///
    /// 校验改正了值时追加警告 `ValuesClamped`。
    pub fn load(&self, stamp: &str) -> Result<LoadResult, StoreError> {
        // 先读成字节：路径是目录、没有权限等情况在这一步报错，与文件不存在分开处理。
        let text = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(finish(default_config(), vec![ConfigWarning::CreatedDefault]));
            }
            Err(error) => return Err(self.io_error(FileOperation::Read, &self.path, &error)),
        };
        // 不是合法 UTF-8 的文件按损坏处理，与 JSON 解析失败同一条路。
        let decoded = match String::from_utf8(text).map_err(|e| ConfigError::Corrupt(e.to_string())) {
            Ok(text) => decode(&text),
            Err(error) => Err(error),
        };
        let mut warnings = Vec::new();
        match decoded {
            Ok(decoded) => {
                if let Some(old) = decoded.migrated_from {
                    self.back_up(old)?;
                    warnings.push(ConfigWarning::Migrated {
                        from: old,
                        to: CURRENT_SCHEMA_VERSION,
                    });
                }
                Ok(finish(decoded.config, warnings))
            }
            Err(ConfigError::NewerSchema { found, supported }) => {
                Err(StoreError::NewerSchema { found, supported })
            }
            Err(ConfigError::Corrupt(_)) => {
                // 内容损坏：隔离原文件，让用户还能找回，然后用默认配置继续。
                let target = self.quarantine_path(stamp);
                fs::rename(&self.path, &target)
                    .map_err(|e| self.io_error(FileOperation::Quarantine, &self.path, &e))?;
                warnings.push(ConfigWarning::CorruptFileQuarantined(target));
                Ok(finish(default_config(), warnings))
            }
        }
    }

    /// 原子地写入配置：先写同目录的临时文件并刷到磁盘，再改名替换，写到一半断电也不会留下半个文件。
    /// 目录不存在时创建。
    pub fn save(&self, config: &AppConfig) -> Result<(), StoreError> {
        let write = || -> io::Result<()> {
            if let Some(dir) = self.path.parent() {
                fs::create_dir_all(dir)?;
            }
            // 临时文件放在同一目录，保证 rename 不跨卷；文件名带进程号，两个实例不会互相覆盖。
            let temp = self.sibling(&format!("{}.tmp-{}.json", self.base_name(), std::process::id()));
            let result = (|| {
                let mut file = fs::File::create(&temp)?;
                file.write_all(encode(config).as_bytes())?;
                file.sync_all()?;
                // Windows 上 rename 用 MoveFileExW 带 MOVEFILE_REPLACE_EXISTING，目标存在时直接替换。
                fs::rename(&temp, &self.path)
            })();
            // 写失败时删掉临时文件，原配置文件保持不变。
            if result.is_err() {
                let _ = fs::remove_file(&temp);
            }
            result
        };
        write().map_err(|e| self.io_error(FileOperation::Write, &self.path, &e))
    }

    /// 损坏文件隔离后的位置：同目录，名为 `<基名>.corrupt-<stamp>.json`；已有同名文件时追加 `-2`、`-3` 等序号。
    pub fn quarantine_path(&self, stamp: &str) -> PathBuf {
        let stem = format!("{}.corrupt-{stamp}", self.base_name());
        let mut candidate = self.sibling(&format!("{stem}.json"));
        let mut suffix = 2;
        while candidate.exists() {
            candidate = self.sibling(&format!("{stem}-{suffix}.json"));
            suffix += 1;
        }
        candidate
    }

    /// 迁移前备份的位置：同目录，名为 `<基名>.v<旧版本>.bak.json`。已存在时覆盖。
    pub fn backup_path(&self, version: i64) -> PathBuf {
        self.sibling(&format!("{}.v{version}.bak.json", self.base_name()))
    }

    /// 迁移前把原文件复制一份。备份失败时报错，不在没有备份的情况下迁移。
    fn back_up(&self, version: i64) -> Result<(), StoreError> {
        let target = self.backup_path(version);
        fs::copy(&self.path, &target)
            .map(|_| ())
            .map_err(|e| self.io_error(FileOperation::Backup, &target, &e))
    }

    /// 配置文件去掉扩展名后的名字，默认是 `config`。
    fn base_name(&self) -> String {
        self.path
            .file_stem()
            .map_or_else(|| "config".to_owned(), |s| s.to_string_lossy().into_owned())
    }

    /// 与配置文件同目录的另一个文件。
    fn sibling(&self, name: &str) -> PathBuf {
        self.path.with_file_name(name)
    }

    /// 组装一个 `Io` 错误。
    fn io_error(&self, operation: FileOperation, path: &Path, error: &io::Error) -> StoreError {
        StoreError::Io {
            operation,
            path: path.to_owned(),
            reason: error.to_string(),
        }
    }
}

/// 新的默认配置，配置方案 id 是随机的 UUID。
pub fn default_config() -> AppConfig {
    AppConfig::make_default(new_id())
}

/// 校验配置，有改正时追加 `ValuesClamped` 警告，组装结果。
fn finish(config: AppConfig, mut warnings: Vec<ConfigWarning>) -> LoadResult {
    let normalized = normalized(config);
    if !normalized.clamped.is_empty() {
        warnings.push(ConfigWarning::ValuesClamped(normalized.clamped));
    }
    LoadResult {
        config: normalized.config,
        warnings,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每个用例一个独立的临时目录，用完删掉。
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("eveo-app-core-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn store(&self) -> JsonFileConfigStore {
            JsonFileConfigStore::new(self.0.join("config.json"))
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// 第一次运行：没有配置文件时用默认配置，且不立即写盘（用户改了设置才写）。
    #[test]
    fn missing_file_gives_default_without_writing() {
        let dir = TempDir::new("missing");
        let result = dir.store().load("20261123-120000").unwrap();
        assert_eq!(result.warnings, vec![ConfigWarning::CreatedDefault]);
        assert_eq!(result.config.profiles.len(), 1);
        assert!(!dir.store().path().exists());
    }

    /// 写入后读回得到相同配置；目录不存在时自动创建，写完不留临时文件。
    #[test]
    fn save_then_load_round_trips_and_creates_directory() {
        let dir = TempDir::new("roundtrip");
        let store = JsonFileConfigStore::new(dir.0.join("nested").join("config.json"));
        let mut config = default_config();
        config.profiles[0].thumbnail.opacity = 0.8;
        store.save(&config).unwrap();
        let loaded = store.load("x").unwrap();
        assert!(loaded.warnings.is_empty());
        assert_eq!(loaded.config, config);
        // 临时文件不留在目录里。
        let names: Vec<_> = fs::read_dir(dir.0.join("nested"))
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("config.json")]);
    }

    /// 损坏的文件改名隔离；同一秒已有隔离文件时追加序号，不覆盖之前隔离的内容。
    #[test]
    fn corrupt_file_is_quarantined_with_unique_name() {
        let dir = TempDir::new("corrupt");
        let store = dir.store();
        fs::write(dir.0.join("config.corrupt-20261123-120000.json"), "older").unwrap();
        fs::write(store.path(), "{ not json").unwrap();
        let result = store.load("20261123-120000").unwrap();
        let expected = dir.0.join("config.corrupt-20261123-120000-2.json");
        assert_eq!(
            result.warnings,
            vec![ConfigWarning::CorruptFileQuarantined(expected.clone())]
        );
        assert_eq!(fs::read_to_string(expected).unwrap(), "{ not json");
        assert!(!store.path().exists());
    }

    /// 不是 UTF-8 的文件（例如被别的编辑器另存为 UTF-16）与 JSON 损坏同样处理。
    #[test]
    fn invalid_utf8_counts_as_corrupt() {
        let dir = TempDir::new("utf8");
        let store = dir.store();
        fs::write(store.path(), [0xFF, 0xFE, 0x00]).unwrap();
        let result = store.load("s").unwrap();
        assert!(matches!(
            result.warnings[..],
            [ConfigWarning::CorruptFileQuarantined(_)]
        ));
    }

    /// 降级运行旧版本时：新版本的配置原样保留，不改名、不备份，目录里只有原文件。
    #[test]
    fn newer_schema_leaves_file_alone() {
        let dir = TempDir::new("newer");
        let store = dir.store();
        fs::write(store.path(), r#"{"schemaVersion": 99}"#).unwrap();
        let error = store.load("s").unwrap_err();
        assert_eq!(
            error,
            StoreError::NewerSchema {
                found: 99,
                supported: CURRENT_SCHEMA_VERSION
            }
        );
        assert_eq!(
            fs::read_to_string(store.path()).unwrap(),
            r#"{"schemaVersion": 99}"#
        );
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
    }

    /// 旧版本的配置先原样备份，再迁移；迁移结果此时不写盘。
    #[test]
    fn older_schema_is_backed_up_before_migrating() {
        let dir = TempDir::new("older");
        let store = dir.store();
        let mut text = encode(&default_config());
        text = text.replace("\"schemaVersion\": 1", "\"schemaVersion\": 0");
        fs::write(store.path(), &text).unwrap();
        let result = store.load("s").unwrap();
        assert_eq!(
            result.warnings,
            vec![ConfigWarning::Migrated {
                from: 0,
                to: CURRENT_SCHEMA_VERSION
            }]
        );
        assert_eq!(fs::read_to_string(store.backup_path(0)).unwrap(), text);
    }

    /// 越界的值被夹回范围，并以字段路径报告给设置窗口。
    #[test]
    fn clamped_values_are_reported() {
        let dir = TempDir::new("clamped");
        let store = dir.store();
        let mut config = default_config();
        config.profiles[0].thumbnail.opacity = 5.0;
        fs::write(store.path(), encode(&config)).unwrap();
        let result = store.load("s").unwrap();
        assert!(
            matches!(&result.warnings[..], [ConfigWarning::ValuesClamped(paths)]
            if paths.iter().any(|p| p.ends_with("thumbnail.opacity")))
        );
        assert!((result.config.profiles[0].thumbnail.opacity - 1.0).abs() < f64::EPSILON);
    }

    /// 配置文件的位置被一个目录占了：读失败，报给调用方，本次会话不写盘。
    #[test]
    fn directory_in_place_of_file_is_a_read_error() {
        let dir = TempDir::new("isdir");
        let store = dir.store();
        fs::create_dir_all(store.path()).unwrap();
        let error = store.load("s").unwrap_err();
        assert!(matches!(
            error,
            StoreError::Io {
                operation: FileOperation::Read,
                ..
            }
        ));
    }
}
