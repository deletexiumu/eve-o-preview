// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与聊天翻译的设置，对应 macOS 的 Model/ChatSettings.swift（docs/macos/design-intel-translate.md 3.1 节）。
// - IntelSettings、TranslationSettings 属于配置方案，JSON 路径是 profiles[].intel 与 profiles[].translation。
// - TranslationEndpointSettings 是全局设置，JSON 路径是 general.translationEndpoint。API Key 不在配置里。
// - ChannelRef 同时存频道名与 Channel ID，匹配规则见 5.3 节。

use crate::geometry::ScreenRect;
use crate::model::AppLanguage;
use crate::support::{StringEnum, text};

config_struct! {
    /// 配置里的一个频道：用户看到的名字，加上可选的 Channel ID。
    pub struct ChannelRef via ChannelRefRaw {
        /// 用户看到的频道名（文件头的 Channel Name）；缺失时为空串，由校验去掉。
        req name: String = String::new(), "name";
        /// 文件头的 Channel ID；`None` 表示只按名字匹配。
        opt id: String = None, "id";
    }
}

/// 内置频道的 ID。
const BUILT_IN_IDS: [&str; 4] = ["local", "corp", "alliance", "fleet"];

impl ChannelRef {
    /// 用名字与可选的 ID 建一个频道。
    pub fn new(name: &str, id: Option<&str>) -> Self {
        Self {
            name: name.to_owned(),
            id: id.map(str::to_owned),
        }
    }

    /// 4 个内置频道（本地、军团、联盟、舰队），按设置界面里的顺序。
    pub fn built_ins() -> Vec<ChannelRef> {
        vec![
            Self::new("Local", Some("local")),
            Self::new("Corp", Some("corp")),
            Self::new("Alliance", Some("alliance")),
            Self::new("Fleet", Some("fleet")),
        ]
    }

    /// 是否内置频道（id 是 local、corp、alliance、fleet 之一，不区分大小写）。
    pub fn is_built_in(&self) -> bool {
        self.id
            .as_deref()
            .is_some_and(|id| BUILT_IN_IDS.contains(&id.to_lowercase().as_str()))
    }

    /// 这个频道是否与日志文件头里的频道对应：
    /// 1. 内置频道只看 ID：`fleet` 要求日志的 ID 以 `fleet_` 开头，其余要求 ID 相同（不区分大小写）。
    ///    不看名字，因为名字随客户端语言变。
    /// 2. 其他频道：`id` 有值且与日志的 ID 相同时匹配；否则名字去掉首尾空白后不区分大小写相同时匹配。
    /// 3. 日志的 ID 以 `private_` 开头时一律不匹配。
    pub fn matches(&self, channel_id: Option<&str>, channel_name: Option<&str>) -> bool {
        let log_id = channel_id.map(text::trim_whitespace_and_newlines);
        if log_id.is_some_and(|id| id.to_lowercase().starts_with("private_")) {
            return false;
        }
        if let (true, Some(id)) = (self.is_built_in(), self.id.as_deref()) {
            let Some(log_id) = log_id else { return false };
            let own = id.to_lowercase();
            let other = log_id.to_lowercase();
            return if own == "fleet" {
                other.starts_with("fleet_")
            } else {
                other == own
            };
        }
        if let (Some(id), Some(log_id)) = (self.id.as_deref(), log_id)
            && !id.is_empty()
            && id == log_id
        {
            return true;
        }
        let own = text::trim_whitespace_and_newlines(&self.name);
        match channel_name.map(text::trim_whitespace_and_newlines) {
            Some(log_name) if !own.is_empty() => text::eq_ignore_case(own, log_name),
            _ => false,
        }
    }
}

string_enum! {
    /// 浮窗什么时候显示（v1.2.1）。
    pub enum OverlayVisibility {
        /// 始终显示（默认）：只受「离开 EVE 时隐藏」这个与缩略图共用的开关与延迟约束。
        Always => "always",
        /// 仅游戏内：前台不是 EVE 客户端（也不是本应用）时立即隐藏，切回任一客户端时立即显示。
        GameOnly => "gameOnly",
    }
}

/// 浮窗背景不透明度的范围。
pub const OVERLAY_OPACITY_RANGE: (f64, f64) = (0.2, 1.0);
/// 浮窗字号的范围。
pub const OVERLAY_FONT_SIZE_RANGE: (f64, f64) = (10.0, 24.0);

config_struct! {
    /// 一个浮窗的位置与外观。
    pub struct OverlayPanelSettings via OverlayPanelSettingsRaw {
        /// 全局屏幕坐标的位置与尺寸；`None` 表示用默认位置。
        opt frame: ScreenRect = None, "frame";
        /// 背景的不透明度，默认 0.75，范围 0.2～1.0。文字始终不透明。
        req opacity: f64 = 0.75, "opacity";
        /// 第一行的字号，默认 12，范围 10～24。
        req font_size: f64 = 12.0, "fontSize";
        /// 什么时候显示，默认始终显示；不认识的取值按默认值处理。
        lenient visibility: OverlayVisibility = OverlayVisibility::Always, "visibility";
    }
}

/// 预警保留时长的范围，单位是分钟。
pub const INTEL_WINDOW_MINUTES_RANGE: (i64, i64) = (5, 120);
/// 跳数计算上限的范围。
pub const INTEL_MAX_JUMPS_RANGE: (i64, i64) = (1, 30);
/// 高亮距离的范围；0 表示不高亮。
pub const INTEL_ALERT_JUMPS_RANGE: (i64, i64) = (0, 30);
/// 频道列表的上限，预警与翻译共用。
pub const MAX_CHANNELS: usize = 16;

config_struct! {
    /// 预警的设置。功能默认关闭，打开后才读聊天日志。
    pub struct IntelSettings via IntelSettingsRaw {
        /// 是否显示预警浮窗并读聊天日志，默认 false。
        req enabled: bool = false, "enabled";
        /// 预警频道，默认为空，至多 16 项。
        req channels: Vec<ChannelRef> = Vec::new(), "channels";
        /// 早于这个时长的消息从浮窗里去掉，单位是分钟，默认 30，范围 5～120。
        req window_minutes: i64 = 30, "windowMinutes";
        /// 跳数的计算上限，默认 15，范围 1～30。
        req max_jumps: i64 = 15, "maxJumps";
        /// 敌对在这个跳数以内时高亮，默认 5，范围 0～30；0 表示不高亮。
        req alert_jumps: i64 = 5, "alertJumps";
        /// 每条下面是否显示原文，默认 true。
        req show_original: bool = true, "showOriginal";
        /// 参考星系的英文名；不知道角色位置时跳数从它算。默认 `None`。
        opt reference_system: String = None, "referenceSystem";
        /// 是否向 CCP 的 ESI 核对人名，默认 true。
        req resolve_pilot_names: bool = true, "resolvePilotNames";
        /// 预警浮窗的位置与外观。
        req overlay: OverlayPanelSettings = OverlayPanelSettings::default(), "overlay";
    }
}

string_enum! {
    /// 翻译的目标语言：跟随界面语言，或 8 种语言之一。
    pub enum TranslationTarget {
        /// 跟随界面语言，默认值。
        Ui => "ui",
        /// 英文。
        En => "en",
        /// 中文（简体）。
        Zh => "zh",
        /// 俄文。
        Ru => "ru",
        /// 日文。
        Ja => "ja",
        /// 韩文。
        Ko => "ko",
        /// 法文。
        Fr => "fr",
        /// 德文。
        De => "de",
        /// 西班牙文。
        Es => "es",
    }
}

impl TranslationTarget {
    /// 实际的目标语言：`ui` 取界面语言，其余取同名的语言。
    pub fn resolved(self, ui: AppLanguage) -> AppLanguage {
        AppLanguage::from_raw(self.raw()).unwrap_or(ui)
    }
}

config_struct! {
    /// 聊天翻译的设置。功能默认关闭。
    pub struct TranslationSettings via TranslationSettingsRaw {
        /// 是否显示翻译浮窗，默认 false。
        req enabled: bool = false, "enabled";
        /// 翻译频道，默认为空，至多 16 项。
        req channels: Vec<ChannelRef> = Vec::new(), "channels";
        /// 目标语言，默认 `ui`（跟随界面语言）。
        lenient target_language: TranslationTarget = TranslationTarget::Ui, "targetLanguage";
        /// 译文下面是否显示原文，默认 true。
        req show_original: bool = true, "showOriginal";
        /// 为真时只显示翻译过的消息，默认 false。
        req foreign_only: bool = false, "foreignOnly";
        /// 翻译浮窗的位置与外观。
        req overlay: OverlayPanelSettings = OverlayPanelSettings::default(), "overlay";
    }
}

string_enum! {
    /// 模型服务的预设编号。
    pub enum TranslationProviderId {
        /// DeepSeek，默认预设。
        DeepSeek => "deepseek",
        /// Anthropic 的 Claude。
        Anthropic => "anthropic",
        /// OpenAI。
        OpenAi => "openai",
        /// 通义千问（DashScope 的 OpenAI 兼容接口）。
        Qwen => "qwen",
        /// Kimi（Moonshot）。
        Moonshot => "moonshot",
        /// 本机的 Ollama。
        Ollama => "ollama",
        /// 其他 OpenAI 兼容接口，地址与模型由用户填写。
        Custom => "custom",
    }
}

config_struct! {
    /// 模型服务的地址与模型名，全局设置。空串表示用预设值。
    pub struct TranslationEndpointSettings via TranslationEndpointSettingsRaw {
        /// 服务预设，默认 `deepseek`。
        lenient provider: TranslationProviderId = TranslationProviderId::DeepSeek, "provider";
        /// 接口地址；空串表示用预设地址。
        req base_url: String = String::new(), "baseURL";
        /// 模型名；空串表示用预设模型。
        req model: String = String::new(), "model";
    }
}

/// 一个模型服务预设（macOS 的 TranslationProviders.presets，地址与模型名 2026-11-21 核对过）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranslationPreset {
    /// 下拉里显示的服务名，不翻译；「自定义」一项的名字由界面文字提供。
    pub display_name: &'static str,
    /// 默认的接口地址；设置里的地址为空时用它。
    pub base_url: &'static str,
    /// 默认的模型名；设置里的模型名为空时用它。
    pub model: &'static str,
    /// 是否要 API Key。
    pub requires_key: bool,
}

impl TranslationProviderId {
    /// 这个编号的预设。顺序与「翻译」页的下拉一致，即声明顺序。
    pub fn preset(self) -> TranslationPreset {
        let (display_name, base_url, model, requires_key) = match self {
            // 默认预设：价格低、中文好，与 macOS 相同。
            Self::DeepSeek => ("DeepSeek", "https://api.deepseek.com", "deepseek-flash", true),
            Self::Anthropic => (
                "Claude (Anthropic)",
                "https://api.anthropic.com",
                "claude-haiku-5-5",
                true,
            ),
            Self::OpenAi => ("OpenAI", "https://api.openai.com/v1", "gpt-6-luna", true),
            Self::Qwen => (
                "Qwen (DashScope)",
                "https://dashscope.aliyuncs.com/compatible-mode/v1",
                "qwen-plus",
                true,
            ),
            Self::Moonshot => ("Kimi (Moonshot)", "https://api.moonshot.cn/v1", "kimi-k3", true),
            // 本机服务：明文 http 只允许本机与局域网（macOS 设计文档 7.11 节），不用 Key。
            Self::Ollama => ("Ollama", "http://127.0.0.1:11434/v1", "qwen2.5:7b", false),
            // 地址与模型由用户填写；Key 可有可无。
            Self::Custom => ("Custom (OpenAI-compatible)", "", "", false),
        };
        TranslationPreset {
            display_name,
            base_url,
            model,
            requires_key,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 内置频道只看 ID，舰队按前缀；私聊一律不匹配。
    #[test]
    fn built_in_matching() {
        let [local, _, _, fleet] = <[ChannelRef; 4]>::try_from(ChannelRef::built_ins()).unwrap();
        assert!(local.matches(Some("local"), Some("本地")));
        assert!(!local.matches(None, Some("Local")));
        assert!(fleet.matches(Some(" fleet_123 "), None));
        assert!(!fleet.matches(Some("fleet"), None));
        assert!(!local.matches(Some("private_local"), None));
    }

    /// 自定义频道：ID 相同即匹配，否则比名字。
    #[test]
    fn custom_matching() {
        let by_id = ChannelRef::new("Intel", Some("player_1"));
        assert!(by_id.matches(Some("player_1"), Some("whatever")));
        assert!(by_id.matches(Some("player_2"), Some(" intel ")));
        let by_name = ChannelRef::new("  ", None);
        assert!(!by_name.matches(None, Some("")));
    }

    /// 缺键与 null 取默认值，不认识的枚举值取默认值，null 的可选键为 None。
    #[test]
    fn lenient_decoding() {
        let panel: OverlayPanelSettings =
            serde_json::from_str(r#"{"opacity": null, "visibility": 5, "frame": null}"#).unwrap();
        assert_eq!(panel, OverlayPanelSettings::default());
        let endpoint: TranslationEndpointSettings =
            serde_json::from_str(r#"{"provider": "future", "baseURL": "x"}"#).unwrap();
        assert_eq!(endpoint.provider, TranslationProviderId::DeepSeek);
        assert_eq!(endpoint.base_url, "x");
        assert!(serde_json::from_str::<IntelSettings>(r#"{"maxJumps": "5"}"#).is_err());
    }

    /// 可选键为 None 时不写出。
    #[test]
    fn omits_none() {
        let json = serde_json::to_value(ChannelRef::new("Intel", None)).unwrap();
        assert_eq!(json, serde_json::json!({"name": "Intel"}));
    }
}
