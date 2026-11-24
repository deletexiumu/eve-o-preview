// SPDX-License-Identifier: GPL-3.0-or-later
//
// 问题报告的摘要，对应 macOS 的 DiagnosticsSummary.swift（v1.1 设计 7.2 节），按 Windows 调整：
// - `config_summary`：`config-summary.json` 的内容。只有数值、开关、热键与数量，
//   不含配置方案名、循环组名、角色名、频道名、接口地址与任何路径。用户自己起的名字可能含任何文字，
//   所以整个不进报告，不靠脱敏。键名与 macOS 相同（Windows 用不到的 showDockIcon 不写）。
// - `RuntimeSummary`：应用在主线程取的运行时快照。Windows 没有屏幕录制与辅助功能权限，
//   改写缩略图的状态计数；屏幕写成 `2560x1440 @150% primary`。
// - `EnvironmentReport`：`summary.md` 的全文与 Issue 正文「Environment」一节（英文）。
// - `DiagnosticsBundlePlanner`：日志取多少、压缩包叫什么。
// - `DiagnosticsManifest`：`manifest.json` 的内容。
// 报告里的 JSON 一律缩进、键按字母排序（serde_json 的 Map 是有序的）。

//! 问题报告的摘要、环境报告与文件清单。

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{Value, json};

use crate::diagnostics::redactor::RedactionCounts;
use crate::model::AppConfig;
use crate::support::time::iso8601_seconds;

/// 由配置建 `config-summary.json` 的内容。load_error、warnings 只传类别名（如 `newerSchema`、`valuesClamped`），
/// 不传路径与说明。没有配置方案时 activeProfile 为 null。
pub fn config_summary(config: &AppConfig, load_error: Option<&str>, warnings: &[String]) -> Value {
    // 游戏日志目录只写「默认」还是「自定」：路径里有用户名，也没有排查价值。
    let general = &config.general;
    let custom_log_directory = general
        .eve_log_directory
        .as_deref()
        .is_some_and(|dir| !dir.trim().is_empty());
    json!({
        "schemaVersion": config.schema_version,
        "profileCount": config.profiles.len(),
        "loadError": load_error,
        "warnings": warnings,
        "activeProfile": config.active_profile().map(|profile| profile_summary(profile, config)),
        "general": {
            "pollIntervalMs": general.poll_interval_ms,
            "language": to_value(&general.language),
            "checkForUpdates": general.check_for_updates,
            "autoInstallUpdates": general.auto_install_updates,
            "logLevel": to_value(&general.log_level),
            "eveLogDirectory": if custom_log_directory { "custom" } else { "default" },
        },
    })
}

/// 当前配置方案的摘要：各组设置原样（都是数值、开关与热键），以角色名为键的字段换成数量或序号。
fn profile_summary(profile: &crate::model::Profile, config: &AppConfig) -> Value {
    // 角色热键按角色名排序（不区分大小写，相同时区分大小写）后的序号排列，只有热键。
    let mut hotkey_names: Vec<&String> = profile.character_hotkeys.keys().collect();
    hotkey_names.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()).then_with(|| a.cmp(b)));
    let character_hotkeys: Vec<&Vec<String>> = hotkey_names
        .iter()
        .map(|name| &profile.character_hotkeys[*name])
        .collect();
    let cycle_groups: Vec<Value> = profile
        .cycle_groups
        .iter()
        .map(|group| {
            json!({
                "memberCount": group.members.len(),
                "forwardHotkeys": group.forward_hotkeys,
                "backwardHotkeys": group.backward_hotkeys,
            })
        })
        .collect();
    // 预警与翻译的设置里有频道名、星系名与接口地址，只取开关与数量，不整个编码。
    let intel = &profile.intel;
    let translation = &profile.translation;
    let endpoint = &config.general.translation_endpoint;
    json!({
        // 这几组设置只有数值、开关、颜色与枚举，原样编码，键名与配置文件相同。
        "thumbnail": to_value(&profile.thumbnail),
        "overlay": to_value(&profile.overlay),
        "behavior": to_value(&profile.behavior),
        "capture": to_value(&profile.capture),
        "combatAlert": to_value(&profile.combat_alert),
        "hotkeyDefaultScope": to_value(&profile.hotkey_default_scope),
        "layoutCount": profile.layouts.len(),
        "hiddenCharacterCount": profile.hidden_characters.len(),
        "highlightColorCount": profile.highlight_colors.len(),
        "characterHotkeyCount": profile.character_hotkeys.len(),
        "hotkeys": to_value(&profile.hotkeys),
        "cycleGroups": cycle_groups,
        "characterHotkeys": character_hotkeys,
        // 预警：只有开关与数量，不含频道名与参考星系名。
        "intel": {
            "enabled": intel.enabled,
            "channelCount": intel.channels.len(),
            "windowMinutes": intel.window_minutes,
            "maxJumps": intel.max_jumps,
            "alertJumps": intel.alert_jumps,
            "hasReferenceSystem": intel.reference_system.is_some(),
            "hasCustomFrame": intel.overlay.frame.is_some(),
            "resolvePilotNames": intel.resolve_pilot_names,
        },
        // 翻译：只有开关、数量与预设编号，不含频道名、接口地址与模型名。
        "translation": {
            "enabled": translation.enabled,
            "channelCount": translation.channels.len(),
            "targetLanguage": to_value(&translation.target_language),
            "provider": to_value(&endpoint.provider),
            "hasCustomBaseURL": !endpoint.base_url.trim().is_empty(),
            "hasCustomModel": !endpoint.model.trim().is_empty(),
        },
    })
}

/// 编码成 JSON 值；配置模型总能编码，失败时写 null。
fn to_value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// 报告里 JSON 的写法：缩进两格、键按字母排序，末尾换行。
pub fn pretty_json(value: &Value) -> String {
    let mut text = serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".to_owned());
    text.push('\n');
    text
}

/// 应用的运行环境。只有版本、构建类别、提交与安装位置的类别，不含路径。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AppEnvironment {
    /// 版本，如 `0.9.0`。
    pub version: String,
    /// 构建类别：`release` 或 `debug`。
    pub build_label: String,
    /// 构建时的提交（前 7 位）；不知道时为 None。
    pub commit: Option<String>,
    /// 安装位置的类别：`programFiles`、`localAppData`、`other`。
    pub install_location: String,
    /// 安装位置是否可写（自动更新要用）。
    pub location_writable: bool,
}

/// 系统信息。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SystemInfo {
    /// 产品名，如 `Windows 11 Pro`（按构建号把注册表里的「Windows 10」改正）。
    pub os_name: String,
    /// 版本代号，如 `24H2`；读不到时为空。
    pub os_display_version: String,
    /// 构建号，如 `26100.2314`。
    pub os_build: String,
    /// 进程的架构：`x86_64` 或 `aarch64`。
    pub architecture: String,
    /// 是否在 ARM64 上经仿真运行。
    pub emulated: bool,
    /// 处理器的品牌字符串。
    pub cpu_brand: String,
    /// 物理内存，单位是字节。
    pub physical_memory_bytes: u64,
    /// 逻辑处理器个数。
    pub processor_count: usize,
    /// 系统的区域设置，如 `zh-CN`。
    pub locale: String,
    /// 用户的首选界面语言列表。
    pub preferred_languages: Vec<String>,
    /// 显卡的名称（DXGI 适配器描述，不含软件渲染器）。
    pub gpus: Vec<String>,
}

/// 应用在主线程取的运行时快照，写进 `summary.md`。只有状态名与个数，不含路径与名字。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RuntimeSummary {
    /// 界面语言代码。
    pub ui_language: String,
    /// 游戏日志跟踪服务的状态：`stopped`、`watching (N files)`、`directoryNotFound`、`accessDenied`。
    pub combat_log_status: String,
    /// 聊天日志跟踪服务的状态，写法同上。
    pub chat_log_status: String,
    /// 星图数据：`build-<版本号>`、`missing`、`invalid`、`notLoaded`。
    pub static_data: String,
    /// 翻译的状态：`off`、`idle`、`translating`、`waiting`、`blocked`。
    pub translation_status: String,
    /// 人名核对的状态：`off`、`idle`、`resolving`、`waiting`。
    pub pilot_lookup_status: String,
    /// 已选角色的客户端数。
    pub character_clients: usize,
    /// 停在登录界面的客户端数。
    pub login_clients: usize,
    /// 缩略图的状态名 → 个数（如 `shown`、`hidden`、`failed`）。
    pub thumbnail_states: BTreeMap<String, usize>,
    /// 已注册的热键数。
    pub hotkey_bindings: usize,
    /// 注册失败的原因名 → 个数。
    pub hotkey_failures: BTreeMap<String, usize>,
    /// 屏幕，如 `2560x1440 @150% primary`。
    pub screens: Vec<String>,
    /// 本次运行了多少秒。
    pub uptime_seconds: u64,
    /// 上一次运行的归类：`clean`、`abnormal`、`crashed`、`stillRunning`、`noRecord`。
    pub previous_run: String,
}

/// 运行环境、系统信息与运行时快照的合集。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct EnvironmentReport {
    /// 应用的运行环境。
    pub app: AppEnvironment,
    /// 系统信息。
    pub system: SystemInfo,
    /// 运行时快照。
    pub runtime: RuntimeSummary,
}

impl EnvironmentReport {
    /// 压缩包里 `summary.md` 的全文（英文）。generated_at 是生成时刻（1970 年以来的秒数）。
    pub fn markdown(&self, generated_at: f64) -> String {
        let (app, system, runtime) = (&self.app, &self.system, &self.runtime);
        let lines = vec![
            "# EVE-O Preview diagnostics".to_owned(),
            String::new(),
            format!("Generated: {}", iso8601_seconds(generated_at)),
            String::new(),
            "## App".to_owned(),
            String::new(),
            format!("- Version: {}", app.version),
            format!("- Build label: {}", app.build_label),
            format!("- Commit: {}", app.commit.as_deref().unwrap_or("unknown")),
            format!("- Install location: {}", app.install_location),
            format!("- Location writable: {}", yes_no(app.location_writable)),
            String::new(),
            "## System".to_owned(),
            String::new(),
            format!("- Windows: {}", self.os_text()),
            format!("- Architecture: {}", self.architecture_text()),
            format!("- CPU: {}", system.cpu_brand),
            format!("- GPU: {}", list_or_none(&system.gpus)),
            format!("- Memory: {}", gibibytes(system.physical_memory_bytes)),
            format!("- Processors: {}", system.processor_count),
            format!("- Locale: {}", system.locale),
            format!("- Preferred languages: {}", system.preferred_languages.join(", ")),
            format!("- Interface language: {}", runtime.ui_language),
            String::new(),
            "## Runtime".to_owned(),
            String::new(),
            format!("- Screens: {}", list_or_none(&runtime.screens)),
            format!(
                "- Clients: {} character, {} login",
                runtime.character_clients, runtime.login_clients
            ),
            format!("- Thumbnails: {}", counts(&runtime.thumbnail_states)),
            format!("- Hotkeys registered: {}", runtime.hotkey_bindings),
            format!("- Hotkey failures: {}", counts(&runtime.hotkey_failures)),
            format!("- Combat log: {}", runtime.combat_log_status),
            format!("- Chat log: {}", runtime.chat_log_status),
            format!("- Map data: {}", runtime.static_data),
            format!("- Translation: {}", runtime.translation_status),
            format!("- Pilot lookup: {}", runtime.pilot_lookup_status),
            format!("- Uptime: {} s", runtime.uptime_seconds),
            format!("- Previous run: {}", runtime.previous_run),
            String::new(),
        ];
        lines.join("\n")
    }

    /// Issue 正文里「Environment」一节的各行（英文），不含任何路径与名字。
    /// 重要的在前：超出地址长度时从末尾逐行删。`/` 换成 `-`，免得 GitHub 把它当成路径。
    pub fn issue_lines(&self) -> Vec<String> {
        [
            format!(
                "- EVE-O Preview: {} (build {})",
                self.app.version, self.app.build_label
            ),
            format!("- Windows: {}", self.os_text()),
            format!("- Architecture: {}", self.architecture_text()),
            format!("- GPU: {}", list_or_none(&self.system.gpus)),
            format!("- Interface language: {}", self.runtime.ui_language),
            format!("- Screens: {}", list_or_none(&self.runtime.screens)),
        ]
        .into_iter()
        .map(|line| line.replace('/', "-"))
        .collect()
    }

    /// 系统版本的一段文字：`Windows 11 Pro 24H2 (build 26100.2314)`；没有版本代号时省掉。
    pub fn os_text(&self) -> String {
        let system = &self.system;
        let mut text = system.os_name.clone();
        if !system.os_display_version.is_empty() {
            text.push(' ');
            text.push_str(&system.os_display_version);
        }
        format!("{text} (build {})", system.os_build)
    }

    /// 架构，经仿真时注明。
    fn architecture_text(&self) -> String {
        if self.system.emulated {
            format!("{} (emulated on ARM64)", self.system.architecture)
        } else {
            self.system.architecture.clone()
        }
    }
}

/// 布尔值的英文。
fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

/// 列表用 `; ` 连起来；空列表写 `none`。
fn list_or_none(items: &[String]) -> String {
    if items.is_empty() {
        "none".to_owned()
    } else {
        items.join("; ")
    }
}

/// 内存，单位 GiB，保留一位小数。
fn gibibytes(bytes: u64) -> String {
    format!("{:.1} GiB", bytes as f64 / 1_073_741_824.0)
}

/// 计数表，按名字排序，如 `failed 1, shown 2`；空表写 `none`。
fn counts(table: &BTreeMap<String, usize>) -> String {
    if table.is_empty() {
        return "none".to_owned();
    }
    let parts: Vec<String> = table.iter().map(|(name, n)| format!("{name} {n}")).collect();
    parts.join(", ")
}

/// 日志取多少、压缩包叫什么。
pub struct DiagnosticsBundlePlanner;

impl DiagnosticsBundlePlanner {
    /// 日志合计的上限：2 MiB。
    pub const MAX_LOG_BYTES: u64 = 2_097_152;
    /// 压缩包名字的前缀。
    pub const ARCHIVE_PREFIX: &'static str = "EVE-O-Preview-diagnostics-";

    /// 从最新的日志文件起取，合计不超过 MAX_LOG_BYTES；超出的那个文件只留末尾，之后的文件不取。
    /// files 是日志文件的名字与大小，最新的在前（`LogFileLayout::existing` 的顺序）。
    /// 返回要取的文件与从末尾取的字节数，顺序不变；空文件不取。
    pub fn log_slices(files: &[(String, u64)]) -> Vec<(String, u64)> {
        // remaining 是还能取的字节数；取到 0 就停，更旧的文件不取。
        let mut remaining = Self::MAX_LOG_BYTES;
        let mut slices = Vec::new();
        for (name, bytes) in files.iter().filter(|(_, bytes)| *bytes > 0) {
            if remaining == 0 {
                break;
            }
            let take = (*bytes).min(remaining);
            slices.push((name.clone(), take));
            remaining -= take;
        }
        slices
    }

    /// 压缩包的名字（不带扩展名），按 UTC：`EVE-O-Preview-diagnostics-20261121-040506`。
    /// 用 UTC 而不是本地时间：维护者看到的时刻与日志里的时间一致，也不暴露用户所在的时区。
    pub fn archive_name(at: f64) -> String {
        // iso8601_seconds 给出 `2026-11-21T04:05:06Z`，去掉分隔符即可。
        let iso = iso8601_seconds(at);
        let digits: String = iso.chars().filter(char::is_ascii_digit).collect();
        format!("{}{}-{}", Self::ARCHIVE_PREFIX, &digits[..8], &digits[8..14])
    }
}

/// `manifest.json` 里的一个文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestEntry {
    /// 压缩包里的相对路径，如 `logs/eve-o-preview.log`。
    pub path: String,
    /// 脱敏后的大小，单位是字节。
    pub bytes: usize,
    /// 替换次数。
    pub replacements: RedactionCounts,
}

/// `manifest.json` 的内容：文件清单、各文件的大小与替换次数、生成时刻、应用版本。
#[derive(Debug, Clone, PartialEq)]
pub struct DiagnosticsManifest {
    /// 应用版本。
    pub app_version: String,
    /// 构建类别。
    pub build_label: String,
    /// 生成时刻（1970 年以来的秒数）。
    pub generated_at: f64,
    /// 情境：`manual` 或 `crash`。
    pub context: String,
    /// 文件清单，不含 `manifest.json` 自己。
    pub files: Vec<ManifestEntry>,
}

impl DiagnosticsManifest {
    /// 编码成 `manifest.json` 的内容（键名与 macOS 相同）。
    pub fn to_json(&self) -> String {
        let files: Vec<Value> = self
            .files
            .iter()
            .map(|entry| {
                let counts = entry.replacements;
                json!({
                    "path": entry.path,
                    "bytes": entry.bytes,
                    "replacements": {
                        "user": counts.user,
                        "host": counts.host,
                        "character": counts.character,
                        "identifier": counts.identifier,
                    },
                })
            })
            .collect();
        pretty_json(&json!({
            "appVersion": self.app_version,
            "buildLabel": self.build_label,
            "generatedAt": iso8601_seconds(self.generated_at),
            "context": self.context,
            "files": files,
        }))
    }
}

#[cfg(test)]
#[path = "summary_tests.rs"]
mod tests;
