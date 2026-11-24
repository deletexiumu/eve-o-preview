// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置的取值范围与一致性，对应 macOS 的 Config/ConfigValidator.swift（架构文档 5.2 节）。
// 只改正越界或不一致的值，合法值原样保留，所以对默认配置是无操作，重复调用结果不变。
// 每个被改正的字段记下路径（如 `profiles[0].thumbnail.opacity`），路径的写法与顺序两端相同。

use std::collections::{BTreeMap, HashSet};

use crate::config::{CURRENT_SCHEMA_VERSION, new_id};
use crate::geometry::ScreenSize;
use crate::logging::LogLevel;
use crate::model::{
    AppConfig, COMBAT_ALERT_DURATION_RANGE, COMBAT_ALERT_MINIMUM_DAMAGE_RANGE, ChannelRef,
    CombatAlertSettings, DEFAULT_LOGIN_POSITION, DEFAULT_PROFILE_NAME, INTEL_ALERT_JUMPS_RANGE,
    INTEL_MAX_JUMPS_RANGE, INTEL_WINDOW_MINUTES_RANGE, IntelSettings, MAX_CHANNELS, OVERLAY_FONT_SIZE_RANGE,
    OVERLAY_OPACITY_RANGE, OverlayPanelSettings, OverlaySettings, Profile, ThumbnailLayout,
    ThumbnailSettings, TranslationEndpointSettings, TranslationSettings,
};
use crate::support::{hex_color, text};

/// 缩略图尺寸每一维的绝对范围。下限与「屏幕上至少可见 32 点」一致。
pub const SIZE_LIMIT: (f64, f64) = (32.0, 4096.0);
/// 配置方案名称的最大长度（按字素簇计，去掉首尾空白后）。
pub const MAX_PROFILE_NAME_LENGTH: usize = 64;
/// 名称为空时使用的配置方案名称。
pub const FALLBACK_PROFILE_NAME: &str = "Profile";
/// 布局坐标与登录位置每个分量的范围。远超任何显示器排列，只用来挡住极端值。
pub const COORDINATE_LIMIT: (f64, f64) = (-100_000.0, 100_000.0);

/// [`normalized`] 的结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Normalized {
    /// 改正后的配置。
    pub config: AppConfig,
    /// 被改正字段的路径，按改正顺序，不重复。
    pub clamped: Vec<String>,
}

/// 把越界值夹回范围，保证至少 1 个配置方案、`active_profile_id` 有效、id 与名称唯一。新 id 是随机的 UUID。
///
/// 改正规则与 macOS 相同：
/// - 数值越界夹到最近的边界；NaN、无穷大改回默认值。
/// - 尺寸每一维夹到 [`SIZE_LIMIT`]，最大尺寸不小于最小尺寸，默认尺寸夹到两者之间。
/// - 非法颜色改回默认颜色；按角色设置的非法颜色被删除。
/// - 布局里非有限的坐标改为 0，非正或非有限的宽高改为 `None`；坐标与登录位置夹到 [`COORDINATE_LIMIT`]。
/// - 循环组成员去掉重复项，保留第一次出现的位置。
/// - 战斗提醒的持续时间、最小伤害夹到范围内，非法颜色改回默认值；空白的日志目录改成 `None`。
/// - `general.logLevel` 不是 info 或 debug 时改成 info；`general.frameCap.fps` 夹到驱动接受的范围。
/// - 预警与翻译：数值夹到范围内，频道去重与截断，空白的参考星系改成 `None`，不可用的浮窗 frame 改成 `None`，
///   接口地址与模型名去掉首尾空白，地址末尾的 `/` 去掉。
/// - 配置方案的 id 为空或重复时换新 id；名称去掉首尾空白，为空时用 `Profile`，超长时截断，
///   不区分大小写重名时追加 ` 2`、` 3` 等序号。循环组 id 同理。
/// - 没有配置方案时补一个 `Default`；`active_profile_id` 无效时取第一个配置方案。
pub fn normalized(config: AppConfig) -> Normalized {
    normalized_with(config, &mut new_id)
}

/// 同 [`normalized`]，新 id 由 `make_id` 生成（测试用固定的序列）。
pub fn normalized_with(config: AppConfig, make_id: &mut dyn FnMut() -> String) -> Normalized {
    let mut fixer = FieldFixer::default();
    let mut result = config;

    if result.schema_version != CURRENT_SCHEMA_VERSION {
        result.schema_version = CURRENT_SCHEMA_VERSION;
        fixer.record("schemaVersion");
    }
    let general = &mut result.general;
    fixer.clamp_int(
        &mut general.poll_interval_ms,
        (300, 2000),
        "general.pollIntervalMs",
    );
    // 只把空白串改成 None；非空的路径原样保留（含首尾空白），由日志跟踪按候选规则解释。
    if general
        .eve_log_directory
        .as_deref()
        .is_some_and(|d| text::trim_whitespace_and_newlines(d).is_empty())
    {
        general.eve_log_directory = None;
        fixer.record("general.eveLogDirectory");
    }
    // 文件日志只提供 info 与 debug 两档；手工改成别的级别时改回 info。
    if general.log_level != LogLevel::Info && general.log_level != LogLevel::Debug {
        general.log_level = LogLevel::Info;
        fixer.record("general.logLevel");
    }
    // 限帧的帧数夹到驱动接受的范围（Windows 独有的键，macOS 的配置里没有）。
    if let Some(frame_cap) = &mut general.frame_cap {
        fixer.clamp_int(
            &mut frame_cap.fps,
            crate::frame_cap::FPS_RANGE,
            "general.frameCap.fps",
        );
    }
    normalize_endpoint(
        &mut general.translation_endpoint,
        "general.translationEndpoint",
        &mut fixer,
    );

    if result.profiles.is_empty() {
        result.profiles = vec![Profile::make_new(make_id(), DEFAULT_PROFILE_NAME)];
        fixer.record("profiles");
    }
    let mut seen_ids: HashSet<String> = HashSet::new();
    let mut seen_names: Vec<String> = Vec::new();
    for (index, profile) in result.profiles.iter_mut().enumerate() {
        let path = format!("profiles[{index}]");
        normalize_identity(
            profile,
            &path,
            &mut seen_ids,
            &mut seen_names,
            make_id,
            &mut fixer,
        );
        normalize_settings(profile, &path, make_id, &mut fixer);
    }

    if !result.profiles.iter().any(|p| p.id == result.active_profile_id) {
        result.active_profile_id = result.profiles[0].id.clone();
        fixer.record("activeProfileID");
    }
    Normalized {
        config: result,
        clamped: fixer.paths,
    }
}

// ---- 配置方案的身份 ----

/// 改正配置方案的 id 与名称，保证在整个配置内唯一。
fn normalize_identity(
    profile: &mut Profile,
    path: &str,
    seen_ids: &mut HashSet<String>,
    seen_names: &mut Vec<String>,
    make_id: &mut dyn FnMut() -> String,
    fixer: &mut FieldFixer,
) {
    if profile.id.is_empty() || seen_ids.contains(&profile.id) {
        profile.id = make_id();
        fixer.record(format!("{path}.id"));
    }
    seen_ids.insert(profile.id.clone());

    let name = unique_name(&profile.name, seen_names);
    if name != profile.name {
        profile.name = name.clone();
        fixer.record(format!("{path}.name"));
    }
    seen_names.push(name);
}

/// 生成一个合法且不与 `taken` 重名（不区分大小写）的名称。
pub fn unique_name(base: &str, taken: &[String]) -> String {
    let mut trimmed = text::trim_whitespace_and_newlines(base);
    if trimmed.is_empty() {
        trimmed = FALLBACK_PROFILE_NAME;
    }
    // 截断后再去一次首尾空白：截断点落在空白上时，结果末尾会留下空白，下次校验又会被去掉，
    // 那样同一份配置校验两次结果不同。
    let trimmed = text::trim_whitespace_and_newlines(text::prefix(trimmed, MAX_PROFILE_NAME_LENGTH));
    let is_taken = |candidate: &str| taken.iter().any(|t| text::eq_ignore_case(t, candidate));
    if !is_taken(trimmed) {
        return trimmed.to_owned();
    }
    (2..)
        .map(|number| {
            let suffix = format!(" {number}");
            // 加序号后仍不超过长度上限：先截短基名，再拼序号。
            let stem = text::trim_whitespace(text::prefix(trimmed, MAX_PROFILE_NAME_LENGTH - suffix.len()));
            format!("{stem}{suffix}")
        })
        .find(|candidate| !is_taken(candidate))
        .expect("序号无限，总能找到没被占用的名称")
}

// ---- 配置方案的设置 ----

/// 改正一个配置方案内的全部取值。
fn normalize_settings(
    profile: &mut Profile,
    path: &str,
    make_id: &mut dyn FnMut() -> String,
    fixer: &mut FieldFixer,
) {
    normalize_thumbnail(&mut profile.thumbnail, &format!("{path}.thumbnail"), fixer);
    normalize_overlay(&mut profile.overlay, &format!("{path}.overlay"), fixer);
    normalize_combat_alert(&mut profile.combat_alert, &format!("{path}.combatAlert"), fixer);
    normalize_intel(&mut profile.intel, &format!("{path}.intel"), fixer);
    normalize_translation(&mut profile.translation, &format!("{path}.translation"), fixer);

    let behavior = &mut profile.behavior;
    fixer.clamp_float(
        &mut behavior.hide_delay_seconds,
        (0.0, 10.0),
        1.0,
        &format!("{path}.behavior.hideDelaySeconds"),
    );
    let capture = &mut profile.capture;
    fixer.clamp_int(
        &mut capture.frame_rate,
        (1, 60),
        &format!("{path}.capture.frameRate"),
    );
    fixer.clamp_float(
        &mut capture.title_bar_crop_height,
        (0.0, 60.0),
        28.0,
        &format!("{path}.capture.titleBarCropHeight"),
    );

    let login_path = format!("{path}.loginPosition");
    let login = &mut profile.login_position;
    if !login.x.is_finite() || !login.y.is_finite() {
        *login = DEFAULT_LOGIN_POSITION;
        fixer.record(login_path.clone());
    }
    // 两个分量此时都是有限值，默认值不会用到，只为满足夹取函数的参数。
    fixer.clamp_float(
        &mut login.x,
        COORDINATE_LIMIT,
        DEFAULT_LOGIN_POSITION.x,
        &login_path,
    );
    fixer.clamp_float(
        &mut login.y,
        COORDINATE_LIMIT,
        DEFAULT_LOGIN_POSITION.y,
        &login_path,
    );
    normalize_layouts(&mut profile.layouts, &format!("{path}.layouts"), fixer);

    // 按角色的高亮颜色：非法值直接删除，回退到全局高亮颜色。BTreeMap 按名字排序遍历，路径顺序每次相同。
    let invalid: Vec<String> = profile
        .highlight_colors
        .iter()
        .filter(|(_, c)| !hex_color::is_valid(c))
        .map(|(n, _)| n.clone())
        .collect();
    for name in invalid {
        profile.highlight_colors.remove(&name);
        fixer.record(format!("{path}.highlightColors[{name}]"));
    }

    let mut group_ids: HashSet<String> = HashSet::new();
    for (index, group) in profile.cycle_groups.iter_mut().enumerate() {
        if group.id.is_empty() || group_ids.contains(&group.id) {
            group.id = make_id();
            fixer.record(format!("{path}.cycleGroups[{index}].id"));
        }
        group_ids.insert(group.id.clone());
        remove_duplicate_members(
            &mut group.members,
            &format!("{path}.cycleGroups[{index}].members"),
            fixer,
        );
    }
}

/// 去掉循环组成员里的重复项，保留第一次出现的位置。
/// 重复成员会让循环停在前几个成员之间（引擎按角色名定位起点，总取第一次出现），所以在这里去掉。
fn remove_duplicate_members(members: &mut Vec<String>, path: &str, fixer: &mut FieldFixer) {
    let mut seen: HashSet<String> = HashSet::new();
    let before = members.len();
    members.retain(|m| seen.insert(m.clone()));
    if members.len() != before {
        fixer.record(path);
    }
}

/// 改正缩略图设置：尺寸关系、透明度与放大倍数。
fn normalize_thumbnail(t: &mut ThumbnailSettings, path: &str, fixer: &mut FieldFixer) {
    let d = ThumbnailSettings::default();
    fixer.clamp_size(
        &mut t.minimum_size,
        SIZE_LIMIT,
        d.minimum_size,
        &format!("{path}.minimumSize"),
    );
    fixer.clamp_size(
        &mut t.maximum_size,
        SIZE_LIMIT,
        d.maximum_size,
        &format!("{path}.maximumSize"),
    );
    // 最大尺寸不小于最小尺寸；两者冲突时以最小尺寸为准。
    let (min_w, min_h) = (t.minimum_size.width, t.minimum_size.height);
    fixer.clamp_float(
        &mut t.maximum_size.width,
        (min_w, SIZE_LIMIT.1),
        d.maximum_size.width,
        &format!("{path}.maximumSize.width"),
    );
    fixer.clamp_float(
        &mut t.maximum_size.height,
        (min_h, SIZE_LIMIT.1),
        d.maximum_size.height,
        &format!("{path}.maximumSize.height"),
    );
    let (max_w, max_h) = (t.maximum_size.width, t.maximum_size.height);
    fixer.clamp_float(
        &mut t.default_size.width,
        (min_w, max_w),
        d.default_size.width,
        &format!("{path}.defaultSize.width"),
    );
    fixer.clamp_float(
        &mut t.default_size.height,
        (min_h, max_h),
        d.default_size.height,
        &format!("{path}.defaultSize.height"),
    );
    fixer.clamp_float(&mut t.opacity, (0.2, 1.0), d.opacity, &format!("{path}.opacity"));
    fixer.clamp_int(&mut t.zoom_factor, (2, 10), &format!("{path}.zoomFactor"));
}

/// 改正叠层设置：字号、高亮与中性边框的粗细和颜色。
fn normalize_overlay(o: &mut OverlaySettings, path: &str, fixer: &mut FieldFixer) {
    let d = OverlaySettings::default();
    fixer.clamp_float(
        &mut o.title_font_size,
        (8.0, 36.0),
        d.title_font_size,
        &format!("{path}.titleFontSize"),
    );
    fixer.clamp_int(
        &mut o.highlight_thickness,
        (1, 6),
        &format!("{path}.highlightThickness"),
    );
    fixer.clamp_int(
        &mut o.border_thickness,
        (1, 6),
        &format!("{path}.borderThickness"),
    );
    fixer.require_hex_color(
        &mut o.border_color,
        &d.border_color,
        &format!("{path}.borderColor"),
    );
    fixer.require_hex_color(&mut o.title_color, &d.title_color, &format!("{path}.titleColor"));
    fixer.require_hex_color(
        &mut o.highlight_color,
        &d.highlight_color,
        &format!("{path}.highlightColor"),
    );
}

/// 改正战斗提醒设置：持续时间、最小伤害与颜色。
fn normalize_combat_alert(a: &mut CombatAlertSettings, path: &str, fixer: &mut FieldFixer) {
    let d = CombatAlertSettings::default();
    fixer.clamp_float(
        &mut a.duration_seconds,
        COMBAT_ALERT_DURATION_RANGE,
        d.duration_seconds,
        &format!("{path}.durationSeconds"),
    );
    fixer.clamp_int(
        &mut a.minimum_damage,
        COMBAT_ALERT_MINIMUM_DAMAGE_RANGE,
        &format!("{path}.minimumDamage"),
    );
    fixer.require_hex_color(&mut a.color, &d.color, &format!("{path}.color"));
}

// ---- 预警与翻译（docs/macos/design-intel-translate.md 3.2 节） ----

/// 改正预警设置：3 个整数夹到范围内（先夹 maxJumps，再让 alertJumps 不超过它），频道、参考星系与浮窗。
fn normalize_intel(intel: &mut IntelSettings, path: &str, fixer: &mut FieldFixer) {
    fixer.clamp_int(
        &mut intel.window_minutes,
        INTEL_WINDOW_MINUTES_RANGE,
        &format!("{path}.windowMinutes"),
    );
    fixer.clamp_int(
        &mut intel.max_jumps,
        INTEL_MAX_JUMPS_RANGE,
        &format!("{path}.maxJumps"),
    );
    fixer.clamp_int(
        &mut intel.alert_jumps,
        INTEL_ALERT_JUMPS_RANGE,
        &format!("{path}.alertJumps"),
    );
    // 高亮距离不超过计算上限。
    if intel.alert_jumps > intel.max_jumps {
        intel.alert_jumps = intel.max_jumps;
        fixer.record(format!("{path}.alertJumps"));
    }
    normalize_channels(&mut intel.channels, &format!("{path}.channels"), fixer);
    // 只把空白串改成 None；名称是否存在由预警功能在使用时按星图数据判断。
    if intel
        .reference_system
        .as_deref()
        .is_some_and(|r| text::trim_whitespace_and_newlines(r).is_empty())
    {
        intel.reference_system = None;
        fixer.record(format!("{path}.referenceSystem"));
    }
    normalize_overlay_panel(&mut intel.overlay, &format!("{path}.overlay"), fixer);
}

/// 改正翻译设置：频道与浮窗。目标语言已在解码时由宽松解码兜底。
fn normalize_translation(translation: &mut TranslationSettings, path: &str, fixer: &mut FieldFixer) {
    normalize_channels(&mut translation.channels, &format!("{path}.channels"), fixer);
    normalize_overlay_panel(&mut translation.overlay, &format!("{path}.overlay"), fixer);
}

/// 改正频道列表：名字去掉首尾空白；空白的 id 改成 `None`；名字与 id 都空的项、私聊频道的项删除；
/// 按「id 相同，或都没有 id 且名字不区分大小写相同」去重，保留靠前的一项；超过 16 项时保留前 16 项。
fn normalize_channels(channels: &mut Vec<ChannelRef>, path: &str, fixer: &mut FieldFixer) {
    let mut result: Vec<ChannelRef> = Vec::new();
    for channel in channels.iter() {
        let mut channel = channel.clone();
        channel.name = text::trim_whitespace_and_newlines(&channel.name).to_owned();
        if channel
            .id
            .as_deref()
            .is_some_and(|id| text::trim_whitespace_and_newlines(id).is_empty())
        {
            channel.id = None;
        }
        if channel.name.is_empty() && channel.id.is_none() {
            continue;
        }
        if channel
            .id
            .as_deref()
            .is_some_and(|id| id.to_lowercase().starts_with("private_"))
        {
            continue;
        }
        let duplicate = result.iter().any(|kept| match &channel.id {
            Some(id) => kept.id.as_ref() == Some(id),
            None => kept.id.is_none() && text::eq_ignore_case(&kept.name, &channel.name),
        });
        if !duplicate {
            result.push(channel);
        }
    }
    result.truncate(MAX_CHANNELS);
    if result != *channels {
        *channels = result;
        fixer.record(path);
    }
}

/// 改正浮窗设置：不透明度与字号夹到范围内，非有限值改回默认值；
/// frame 的宽或高不是有限的正数、或坐标不是有限值时整个改成 `None`。
fn normalize_overlay_panel(overlay: &mut OverlayPanelSettings, path: &str, fixer: &mut FieldFixer) {
    let d = OverlayPanelSettings::default();
    fixer.clamp_float(
        &mut overlay.opacity,
        OVERLAY_OPACITY_RANGE,
        d.opacity,
        &format!("{path}.opacity"),
    );
    fixer.clamp_float(
        &mut overlay.font_size,
        OVERLAY_FONT_SIZE_RANGE,
        d.font_size,
        &format!("{path}.fontSize"),
    );
    if let Some(frame) = overlay.frame {
        let usable = frame.width.is_finite()
            && frame.width > 0.0
            && frame.height.is_finite()
            && frame.height > 0.0
            && frame.x.is_finite()
            && frame.y.is_finite();
        if !usable {
            overlay.frame = None;
            fixer.record(format!("{path}.frame"));
        }
    }
}

/// 改正模型服务的设置：地址与模型名去掉首尾空白，地址末尾的 `/` 全部去掉。
fn normalize_endpoint(endpoint: &mut TranslationEndpointSettings, path: &str, fixer: &mut FieldFixer) {
    let base_url = text::trim_whitespace_and_newlines(&endpoint.base_url)
        .trim_end_matches('/')
        .to_owned();
    if base_url != endpoint.base_url {
        endpoint.base_url = base_url;
        fixer.record(format!("{path}.baseURL"));
    }
    let model = text::trim_whitespace_and_newlines(&endpoint.model).to_owned();
    if model != endpoint.model {
        endpoint.model = model;
        fixer.record(format!("{path}.model"));
    }
}

/// 改正布局记录里无法使用的数值。尺寸范围由布局计算在使用时夹取，这里不改。
fn normalize_layouts(layouts: &mut BTreeMap<String, ThumbnailLayout>, path: &str, fixer: &mut FieldFixer) {
    let (low, high) = COORDINATE_LIMIT;
    for (name, layout) in layouts.iter_mut() {
        let original = layout.clone();
        // 非有限值改为 0，再把坐标夹到范围内；0 本身在范围内，所以再调一次不变。
        layout.x = if layout.x.is_finite() {
            layout.x.clamp(low, high)
        } else {
            0.0
        };
        layout.y = if layout.y.is_finite() {
            layout.y.clamp(low, high)
        } else {
            0.0
        };
        if layout.width.is_some_and(|w| !(w.is_finite() && w > 0.0)) {
            layout.width = None;
        }
        if layout.height.is_some_and(|h| !(h.is_finite() && h > 0.0)) {
            layout.height = None;
        }
        if *layout != original {
            fixer.record(format!("{path}[{name}]"));
        }
    }
}

/// 收集被改正字段路径的辅助类型。
#[derive(Default)]
struct FieldFixer {
    /// 被改正字段的路径，按改正顺序，不重复。
    paths: Vec<String>,
}

impl FieldFixer {
    /// 记下一个被改正的字段。
    fn record(&mut self, path: impl Into<String>) {
        let path = path.into();
        if !self.paths.contains(&path) {
            self.paths.push(path);
        }
    }

    /// 把整数夹到闭区间内。
    fn clamp_int(&mut self, value: &mut i64, (low, high): (i64, i64), path: &str) {
        let fixed = (*value).max(low).min(high);
        if fixed != *value {
            *value = fixed;
            self.record(path);
        }
    }

    /// 把浮点数夹到闭区间内；NaN 或无穷大先改为 `fallback`，`fallback` 同样夹到范围内，保证再调一次不变。
    ///
    /// 用 `max` 再 `min`，与 macOS 的 `min(max(v, lower), upper)` 相同：下限大于上限时结果是上限。
    fn clamp_float(&mut self, value: &mut f64, (low, high): (f64, f64), fallback: f64, path: &str) {
        let source = if value.is_finite() { *value } else { fallback };
        let fixed = source.max(low).min(high);
        if fixed != *value || value.is_nan() {
            *value = fixed;
            self.record(path);
        }
    }

    /// 颜色不是合法的 `#RRGGBB` 时改回 `fallback`。
    fn require_hex_color(&mut self, value: &mut String, fallback: &str, path: &str) {
        if !hex_color::is_valid(value) {
            *value = fallback.to_owned();
            self.record(path);
        }
    }

    /// 把尺寸的每一维夹到范围内。
    fn clamp_size(&mut self, size: &mut ScreenSize, range: (f64, f64), fallback: ScreenSize, path: &str) {
        self.clamp_float(&mut size.width, range, fallback.width, &format!("{path}.width"));
        self.clamp_float(
            &mut size.height,
            range,
            fallback.height,
            &format!("{path}.height"),
        );
    }
}
