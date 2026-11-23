// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置的读入、迁移、校验与编辑，对应 macOS 的 Config/（架构文档 5.2 节）。
// 文件读写（损坏隔离、迁移前备份、原子写入）在 M4 随配置持久化加入；这里只有纯逻辑。
// 两端的行为由 shared/fixtures/config 对齐。

//! 配置的迁移、校验与编辑。

mod migrator;
pub mod profile_editor;
mod validator;

pub use migrator::{ConfigError, Decoded, decode, encode};
pub use validator::{
    COORDINATE_LIMIT, FALLBACK_PROFILE_NAME, MAX_PROFILE_NAME_LENGTH, Normalized, SIZE_LIMIT, normalized,
    normalized_with, unique_name,
};

/// 当前的配置结构版本。
pub const CURRENT_SCHEMA_VERSION: i64 = 1;

/// 生成一个新的 id：大写的 UUID v4，与 macOS 的 `UUID().uuidString` 格式相同。
pub fn new_id() -> String {
    uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase()
}
