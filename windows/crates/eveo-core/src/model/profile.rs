// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置方案及其各组设置，对应 macOS 的 Model/Profile.swift（架构文档 5.2 节）。
// 默认值沿用 macOS 版；取值范围由配置校验夹取。以角色名为键的字段（布局、隐藏名单、高亮颜色、角色热键）
// 区分大小写。字典用 BTreeMap，写出的文件键序固定。

use std::collections::BTreeMap;

use crate::geometry::{ScreenPoint, ScreenSize};
use crate::hotkeys::HotkeyScope;
use crate::model::{CombatAlertSettings, CycleGroup, GeneralHotkeys, IntelSettings, TranslationSettings};

/// 新建配置文件时第一个配置方案的名称。
pub const DEFAULT_PROFILE_NAME: &str = "Default";
/// 登录客户端缩略图的默认起始位置 (5, 40)。
pub const DEFAULT_LOGIN_POSITION: ScreenPoint = ScreenPoint::new(5.0, 40.0);

config_struct! {
    /// 一个配置方案：一套完整的设置、布局与循环组。
    pub struct Profile via ProfileRaw {
        /// 配置方案的 id（UUID 字符串），在配置文件内唯一；缺失时为空串，由校验补上。
        req id: String = String::new(), "id";
        /// 显示名称。去掉首尾空白后 1～64 字，不区分大小写唯一。
        req name: String = String::new(), "name";
        /// 缩略图尺寸、透明度、放大与吸附。
        req thumbnail: ThumbnailSettings = ThumbnailSettings::default(), "thumbnail";
        /// 标题、高亮边框与中性边框。
        req overlay: OverlaySettings = OverlaySettings::default(), "overlay";
        /// 置顶与隐藏规则。
        req behavior: BehaviorSettings = BehaviorSettings::default(), "behavior";
        /// 捕获帧率与标题栏裁剪。只有 macOS 用，Windows 读入后原样保留。
        req capture: CaptureSettings = CaptureSettings::default(), "capture";
        /// 每个角色的缩略图位置与尺寸，键是角色名。
        req layouts: BTreeMap<String, ThumbnailLayout> = BTreeMap::new(), "layouts";
        /// 登录界面客户端的缩略图起始位置，默认 (5, 40)。
        req login_position: ScreenPoint = DEFAULT_LOGIN_POSITION, "loginPosition";
        /// 不显示缩略图的角色名。
        req hidden_characters: Vec<String> = Vec::new(), "hiddenCharacters";
        /// 按角色设置的高亮颜色，角色名 → `#RRGGBB`。
        req highlight_colors: BTreeMap<String, String> = BTreeMap::new(), "highlightColors";
        /// 循环组，按设置窗口里的顺序。
        req cycle_groups: Vec<CycleGroup> = Vec::new(), "cycleGroups";
        /// 角色直达热键，角色名 → 热键字符串数组。
        req character_hotkeys: BTreeMap<String, Vec<String>> = BTreeMap::new(), "characterHotkeys";
        /// 全局热键。
        req hotkeys: GeneralHotkeys = GeneralHotkeys::default(), "hotkeys";
        /// 没有 `@global`、`@game` 后缀的热键的作用范围，默认 `global`。
        lenient hotkey_default_scope: HotkeyScope = HotkeyScope::Global, "hotkeyDefaultScope";
        /// 战斗提醒的设置，默认关闭。
        req combat_alert: CombatAlertSettings = CombatAlertSettings::default(), "combatAlert";
        /// 预警的设置，默认关闭。
        req intel: IntelSettings = IntelSettings::default(), "intel";
        /// 聊天翻译的设置，默认关闭。
        req translation: TranslationSettings = TranslationSettings::default(), "translation";
    }
}

impl Profile {
    /// 用 id 与名称建一个配置方案，其余取默认值（全局热键为空）。
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            ..Self::default()
        }
    }

    /// 新建一个配置方案：除了 [`Profile::new`] 的默认值，全局热键取 [`GeneralHotkeys::new_profile_defaults`]。
    ///
    /// 新建配置文件、在设置窗口里新建方案、校验时补出的方案都用它。
    pub fn make_new(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            hotkeys: GeneralHotkeys::new_profile_defaults(),
            ..Self::new(id, name)
        }
    }
}

config_struct! {
    /// 缩略图尺寸、透明度、悬停放大与吸附。
    pub struct ThumbnailSettings via ThumbnailSettingsRaw {
        /// 没有尺寸记录的缩略图使用的尺寸，默认 384×216。
        req default_size: ScreenSize = ScreenSize::new(384.0, 216.0), "defaultSize";
        /// 缩放下限，默认 192×108。
        req minimum_size: ScreenSize = ScreenSize::new(192.0, 108.0), "minimumSize";
        /// 缩放上限，默认 960×540。悬停放大后的尺寸不受它限制。
        req maximum_size: ScreenSize = ScreenSize::new(960.0, 540.0), "maximumSize";
        /// 未悬停时的不透明度，默认 0.5，范围 0.2～1.0；悬停时总是 1.0。
        req opacity: f64 = 0.5, "opacity";
        /// 是否启用悬停放大，默认 false。
        req zoom_enabled: bool = false, "zoomEnabled";
        /// 悬停放大倍数，默认 2，范围 2～10。
        req zoom_factor: i64 = 2, "zoomFactor";
        /// 悬停放大时保持不动的点，默认 `nw`（左上角）。值不是字符串时判为损坏，不认识的名字取默认值。
        strict zoom_anchor: ZoomAnchor = ZoomAnchor::Nw, "zoomAnchor";
        /// 拖动时是否吸附到其他缩略图和屏幕边，默认 true。
        req snap_enabled: bool = true, "snapEnabled";
        /// 缩放时是否保持宽高比，默认 false。
        req lock_aspect_ratio: bool = false, "lockAspectRatio";
    }
}

string_enum! {
    /// 悬停放大时保持不动的点：4 个角、4 条边的中点和中心。按方位命名：n 是上，s 是下，w 是左，e 是右。
    pub enum ZoomAnchor {
        /// 左上角。
        Nw => "nw",
        /// 上边中点。
        N => "n",
        /// 右上角。
        Ne => "ne",
        /// 左边中点。
        W => "w",
        /// 中心。
        Center => "center",
        /// 右边中点。
        E => "e",
        /// 左下角。
        Sw => "sw",
        /// 下边中点。
        S => "s",
        /// 右下角。
        Se => "se",
    }
}

impl ZoomAnchor {
    /// 不动点在矩形内的相对位置，(0, 0) 是左上角，(1, 1) 是右下角。
    pub fn unit_position(self) -> (f64, f64) {
        match self {
            ZoomAnchor::Nw => (0.0, 0.0),
            ZoomAnchor::N => (0.5, 0.0),
            ZoomAnchor::Ne => (1.0, 0.0),
            ZoomAnchor::W => (0.0, 0.5),
            ZoomAnchor::Center => (0.5, 0.5),
            ZoomAnchor::E => (1.0, 0.5),
            ZoomAnchor::Sw => (0.0, 1.0),
            ZoomAnchor::S => (0.5, 1.0),
            ZoomAnchor::Se => (1.0, 1.0),
        }
    }
}

/// 中性边框的默认颜色。
pub const DEFAULT_BORDER_COLOR: &str = "#C0C0C0";

config_struct! {
    /// 缩略图上的叠层：标题、高亮边框与中性边框。颜色都是 `#RRGGBB`。
    pub struct OverlaySettings via OverlaySettingsRaw {
        /// 是否显示角色名标题，默认 true。
        req show_title: bool = true, "showTitle";
        /// 标题字号，默认 12，范围 8～36。
        req title_font_size: f64 = 12.0, "titleFontSize";
        /// 标题颜色，默认 `#FFFFFF`。
        req title_color: String = "#FFFFFF".to_owned(), "titleColor";
        /// 是否给活动客户端画高亮边框，默认 true。
        req highlight_enabled: bool = true, "highlightEnabled";
        /// 没有按角色设置时的高亮颜色，默认 `#ADFF2F`。
        req highlight_color: String = "#ADFF2F".to_owned(), "highlightColor";
        /// 高亮边框粗细，默认 3，范围 1～6。
        req highlight_thickness: i64 = 3, "highlightThickness";
        /// 是否给每个缩略图画一圈中性边框，默认 true。
        req border_enabled: bool = true, "borderEnabled";
        /// 中性边框的颜色，默认 `#C0C0C0`；非法时由校验改回默认值。
        req border_color: String = DEFAULT_BORDER_COLOR.to_owned(), "borderColor";
        /// 中性边框的粗细，默认 2，范围 1～6。
        req border_thickness: i64 = 2, "borderThickness";
    }
}

config_struct! {
    /// 缩略图的行为：置顶、隐藏规则与布局锁定。
    pub struct BehaviorSettings via BehaviorSettingsRaw {
        /// 缩略图是否置顶，默认 true。
        req always_on_top: bool = true, "alwaysOnTop";
        /// 是否隐藏活动客户端自己的缩略图，默认 false。
        req hide_active_client_thumbnail: bool = false, "hideActiveClientThumbnail";
        /// 前台不是 EVE 也不是本应用时是否隐藏全部缩略图，默认 false。
        req hide_when_eve_not_frontmost: bool = false, "hideWhenEVENotFrontmost";
        /// 上一项的隐藏延迟，单位是秒，默认 1.0，范围 0～10。
        req hide_delay_seconds: f64 = 1.0, "hideDelaySeconds";
        /// 锁定布局后忽略移动和缩放手势，默认 false。
        req lock_layout: bool = false, "lockLayout";
    }
}

config_struct! {
    /// 捕获设置（macOS 的 ScreenCaptureKit 用；Windows 用 DWM 缩略图，不需要它们）。
    pub struct CaptureSettings via CaptureSettingsRaw {
        /// 捕获帧率上限，默认 15，范围 1～60。
        req frame_rate: i64 = 15, "frameRate";
        /// 从画面顶部裁掉的高度，默认 28，范围 0～60；0 表示不裁。
        req title_bar_crop_height: f64 = 28.0, "titleBarCropHeight";
    }
}

config_struct! {
    /// 一个角色的缩略图位置与尺寸，全局屏幕坐标。
    pub struct ThumbnailLayout via ThumbnailLayoutRaw {
        /// 左上角的 x 坐标；缺失时取 0。
        req x: f64 = 0.0, "x";
        /// 左上角的 y 坐标；缺失时取 0。
        req y: f64 = 0.0, "y";
        /// 宽度；`None` 表示使用默认尺寸。
        opt width: f64 = None, "width";
        /// 高度；`None` 表示使用默认尺寸。
        opt height: f64 = None, "height";
    }
}
