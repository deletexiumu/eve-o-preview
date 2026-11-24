// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新功能的值类型（macOS v1.1 设计 8.4 节，移植 UpdateModels.swift）：发布信息、能否安装、错误。
// 与 macOS 的差别：
// - 时刻是 1970 年以来的秒数（f64），与 Core 其余地方一致。
// - 不能自动安装的原因换成 Windows 的情形（便携 exe 所在的文件夹、开发构建、没有内置公钥），见 InstallBlocker。
// - 错误去掉 dmg、签名框架相关的项，加上 ed25519 签名与 zip 解包的项。
// 界面阶段（UpdatePhase）放在应用层，Core 只给规则。

//! 更新的值类型。

/// Release 的一个附件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseAsset {
    /// 附件名，如 `EVE-O-Preview-0.9.0-windows-x64.zip`。
    pub name: String,
    /// `browser_download_url`。
    pub download_url: String,
    /// 附件声明的大小，单位是字节；没有时是 None。
    pub size: Option<u64>,
}

/// 一个 Release 的发布信息（已解析、已过滤附件）。
#[derive(Debug, Clone, PartialEq)]
pub struct ReleaseInfo {
    /// tag 去掉 `win-v` 后的规范写法，如 `0.9.0`。
    pub version: String,
    /// 原始的 tag 名，如 `win-v0.9.0`。
    pub tag_name: String,
    /// Release 的标题；答复里没有或为空时取 tag。
    pub title: String,
    /// Release 正文，最多保留 65,536 个字符。
    pub notes: String,
    /// 发布页的地址（`html_url`）。
    pub page_url: String,
    /// 发布时刻；答复里没有或解析不了时是 None。
    pub published_at: Option<f64>,
    /// 答复里的 `prerelease`。
    pub is_prerelease: bool,
    /// 答复里的 `draft`。
    pub is_draft: bool,
    /// 通过 `UpdateFeed::accepts` 的附件，最多 100 个。
    pub assets: Vec<ReleaseAsset>,
}

impl ReleaseInfo {
    /// 按名字找附件。
    pub fn asset(&self, name: &str) -> Option<&ReleaseAsset> {
        self.assets.iter().find(|asset| asset.name == name)
    }
}

/// 不能自动安装、只提示并打开发布页的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallBlocker {
    /// 当前用户不能改动 exe 所在的文件夹（例如放在了 Program Files 下）。
    LocationNotWritable,
    /// 开发或 PR 构建（构建标签带 `dev` 或 `pr`），使用测试地址时除外。
    DevelopmentBuild,
    /// 这个构建没有内置更新包的公钥，核对不了签名。
    NoSigningKey,
}

/// 这个构建能否自动安装更新。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallCapability {
    /// 能下载、核对并安装。
    CanInstall,
    /// 只提示并打开发布页。
    NotifyOnly(InstallBlocker),
    /// 版本号解析不了，更新功能整个停用。
    Unavailable,
}

/// 正在运行的应用，更新规则需要的部分。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningApp {
    /// 版本号，如 `0.9.0`。
    pub version: String,
    /// 构建标签：正式版与版本号相同，CI 构建如 `0.9.0-pr.70.abc1234`。
    pub build_label: String,
    /// 是否是开发或 PR 构建（调试版、构建标签带 `dev` 或 `pr` 的 CI 构建）。
    pub is_development: bool,
    /// exe 所在的文件夹当前用户能否写入。
    pub location_writable: bool,
    /// 是否内置了更新包的公钥。
    pub has_signing_key: bool,
}

/// 检查、下载与安装的错误。关联的说明是英文，不含用户数据，可以写进日志。
#[derive(Debug, Clone, PartialEq)]
pub enum UpdateError {
    /// 网络错误或超时，关联值是系统的说明。
    Network(String),
    /// 服务器返回了意外的状态码。
    HttpStatus(u16),
    /// 被限流，关联值是可以再试的时刻。
    RateLimited(Option<f64>),
    /// 发布信息解析不了，关联值是原因。
    MalformedFeed(String),
    /// 缺少附件，关联值是缺少的附件名。
    AssetMissing(String),
    /// 磁盘空间不足。
    InsufficientDiskSpace,
    /// 下载超过上限。
    DownloadTooLarge,
    /// 校验和文件无效。
    ChecksumListInvalid,
    /// 校验和文件里没有这个文件，关联值是文件名。
    ChecksumEntryMissing(String),
    /// SHA-256 不符。
    ChecksumMismatch,
    /// 校验和文件的 ed25519 签名无效（或签名文件格式不对）。
    SignatureInvalid,
    /// zip 里没有应用的 exe，或解包失败，关联值是原因。
    ArchiveInvalid(String),
    /// 新 exe 的版本号与发布的版本不同。
    VersionMismatch {
        /// 发布的版本。
        expected: String,
        /// 新 exe 里写的版本。
        found: String,
    },
    /// 新 exe 不比正在运行的新。
    NotNewer,
    /// 新 exe 的架构与本机不符。
    ArchitectureMismatch,
    /// 这个构建不能自动安装。
    Blocked(InstallBlocker),
    /// 替换 exe 失败，关联值是系统错误码。
    ReplaceFailed(u32),
    /// 用户取消。界面不显示。
    Cancelled,
}
