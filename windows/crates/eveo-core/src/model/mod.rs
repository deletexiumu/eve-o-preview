// SPDX-License-Identifier: GPL-3.0-or-later
//
// 数据模型，对应 macOS 的 Model/：窗口与客户端（运行时）、配置文件的各层结构（持久化）。

//! 数据模型。

mod chat;
mod client;
mod combat;
mod config;
mod cycle_group;
mod language;
mod profile;

pub use chat::{
    ChannelRef, INTEL_ALERT_JUMPS_RANGE, INTEL_MAX_JUMPS_RANGE, INTEL_WINDOW_MINUTES_RANGE, IntelSettings,
    MAX_CHANNELS, OVERLAY_FONT_SIZE_RANGE, OVERLAY_OPACITY_RANGE, OverlayPanelSettings, OverlayVisibility,
    TranslationEndpointSettings, TranslationPreset, TranslationProviderId, TranslationSettings,
    TranslationTarget,
};
pub use client::{ClientChange, ClientIdentity, EveClient, Pid, RegistryDiff, WindowId, WindowInfo};
pub use combat::{
    COMBAT_ALERT_DEFAULT_COLOR, COMBAT_ALERT_DURATION_RANGE, COMBAT_ALERT_MINIMUM_DAMAGE_RANGE,
    CombatAlertSettings, CombatAlertStyle,
};
pub use config::{AppConfig, GeneralSettings};
pub use cycle_group::{CycleGroup, DEFAULT_TOGGLE_HIDE_ALL, GeneralHotkeys};
pub use language::{AppLanguage, LanguagePreference};
pub use profile::{
    BehaviorSettings, CaptureSettings, DEFAULT_BORDER_COLOR, DEFAULT_LOGIN_POSITION, DEFAULT_PROFILE_NAME,
    OverlaySettings, Profile, ThumbnailLayout, ThumbnailSettings, ZoomAnchor,
};
