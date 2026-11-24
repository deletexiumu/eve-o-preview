// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置文件的顶层结构，对应 macOS 的 Model/AppConfig.swift（架构文档 5.2 节、Windows 架构文档 5.5 节）。
// 一个 config.json 装下全部配置方案。两端用同一份格式：键名、默认值与 schemaVersion 序列相同。

use crate::config::CURRENT_SCHEMA_VERSION;
use crate::frame_cap::FrameCapSettings;
use crate::logging::LogLevel;
use crate::model::{DEFAULT_PROFILE_NAME, LanguagePreference, Profile, TranslationEndpointSettings};

config_struct! {
    /// 配置文件的顶层结构。
    ///
    /// 取值范围与一致性（至少 1 个配置方案、`active_profile_id` 有效）由配置校验保证，解码本身不做校验。
    pub struct AppConfig via AppConfigRaw {
        /// 配置结构的版本；缺失时按当前版本处理。
        req schema_version: i64 = CURRENT_SCHEMA_VERSION, "schemaVersion";
        /// 当前使用的配置方案的 id。
        req active_profile_id: String = String::new(), "activeProfileID";
        /// 全部配置方案，按用户看到的顺序排列；缺失时为空，由校验补上。
        req profiles: Vec<Profile> = Vec::new(), "profiles";
        /// 与配置方案无关的全局设置。
        req general: GeneralSettings = GeneralSettings::default(), "general";
    }
}

impl AppConfig {
    /// 默认配置：一个名为 `Default` 的新配置方案（见 [`Profile::make_new`]），其余取默认值。
    pub fn make_default(profile_id: impl Into<String>) -> Self {
        let profile = Profile::make_new(profile_id, DEFAULT_PROFILE_NAME);
        Self {
            active_profile_id: profile.id.clone(),
            profiles: vec![profile],
            ..Self::default()
        }
    }

    /// 当前配置方案在 `profiles` 里的下标。`active_profile_id` 无效时取 0；没有配置方案时返回 `None`。
    pub fn active_profile_index(&self) -> Option<usize> {
        self.profiles
            .iter()
            .position(|p| p.id == self.active_profile_id)
            .or(if self.profiles.is_empty() { None } else { Some(0) })
    }

    /// 当前配置方案；没有任何配置方案时返回 `None`。经过校验的配置总有当前方案。
    pub fn active_profile(&self) -> Option<&Profile> {
        self.active_profile_index().map(|i| &self.profiles[i])
    }

    /// 当前配置方案的可变引用；没有任何配置方案时返回 `None`。
    pub fn active_profile_mut(&mut self) -> Option<&mut Profile> {
        self.active_profile_index().map(|i| &mut self.profiles[i])
    }

    /// 按 id 查找配置方案。
    pub fn profile_with_id(&self, id: &str) -> Option<&Profile> {
        self.profiles.iter().find(|p| p.id == id)
    }
}

config_struct! {
    /// 与配置方案无关的全局设置。
    pub struct GeneralSettings via GeneralSettingsRaw {
        /// 轮询窗口列表的间隔，单位是毫秒，默认 1000，范围 300～2000。
        req poll_interval_ms: i64 = 1000, "pollIntervalMs";
        /// 是否已完成首次启动引导，默认 false。
        req onboarding_completed: bool = false, "onboardingCompleted";
        /// 界面语言的选项，对全部配置方案生效，默认 `en`。
        lenient language: LanguagePreference = LanguagePreference::En, "language";
        /// 游戏日志目录；`None` 表示自动查找。去掉首尾空白后是空串时由校验改成 `None`。
        opt eve_log_directory: String = None, "eveLogDirectory";
        /// 是否在启动时与每 24 小时自动检查更新，默认 true。
        req check_for_updates: bool = true, "checkForUpdates";
        /// 是否在后台下载更新、退出时安装，默认 true。
        req auto_install_updates: bool = true, "autoInstallUpdates";
        /// 写进文件日志的最低级别，默认 `info`，只接受 info 与 debug。
        lenient log_level: LogLevel = LogLevel::Info, "logLevel";
        /// 是否在 Dock 里显示图标（macOS），默认 true。
        req show_dock_icon: bool = true, "showDockIcon";
        /// 聊天翻译的模型服务：预设、地址与模型名。
        req translation_endpoint: TranslationEndpointSettings = TranslationEndpointSettings::default(), "translationEndpoint";
        /// 用 NVIDIA 驱动给 EVE 客户端限帧（Windows 独有）；`None` 表示从没设置过，等同于关闭。
        /// 为 `None` 时不写这个键，两端共用的配置用例（shared/fixtures/config）不受影响。
        opt frame_cap: FrameCapSettings = None, "frameCap";
    }
}
