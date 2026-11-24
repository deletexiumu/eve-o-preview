// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」与「翻译」两页的绑定：当前方案的 intel、translation，与全局的 general.translationEndpoint。
// - 标量的值（开关、数值、下拉、输入框、浮窗外观）与其他页一样整页显示、整页读回，数值按配置的范围与步长取整。
// - 频道列表的增删是动作（ChannelEdit），规则与 macOS 的 ChannelListEditor 相同：已选的不重复加，满 16 项不加。
// - 换服务预设时清掉自定义的地址与模型名，新预设用自己的默认值（与 macOS 的 selectTranslationProvider 相同）。
// 越界的值最终还会被配置校验夹回；这里的取整只是让读回的值与界面一致。

//! 「预警」与「翻译」两页。

use slint::{ComponentHandle, ModelRc, SharedString, VecModel};

use eveo_core::chat_log::ChatLogStatus;
use eveo_core::model::{
    AppLanguage, ChannelRef, INTEL_ALERT_JUMPS_RANGE, INTEL_MAX_JUMPS_RANGE, INTEL_WINDOW_MINUTES_RANGE,
    IntelSettings, MAX_CHANNELS, OVERLAY_FONT_SIZE_RANGE, OVERLAY_OPACITY_RANGE, OverlayPanelSettings,
    OverlayVisibility, TranslationEndpointSettings, TranslationProviderId, TranslationSettings,
    TranslationTarget,
};
use eveo_core::support::StringEnum;

use crate::{IntelModel, SettingsWindow, TranslationModel};

/// 频道列表的一次改动，来自页上的按钮与输入框。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelEdit {
    /// 移除第几项。
    Remove(usize),
    /// 按名称添加一项只有名字的频道。
    AddName(String),
    /// 添加第几个内置频道（ChannelRef::built_ins 的顺序：本地、军团、联盟、舰队）。
    AddBuiltIn(usize),
}

/// 按改动修改频道列表；返回列表是否变了。已选的、已满的、空白名字的添加什么也不做。
pub fn apply_channel_edit(channels: &mut Vec<ChannelRef>, edit: &ChannelEdit) -> bool {
    let candidate = match edit {
        ChannelEdit::Remove(index) => {
            // 下标来自页上的列表；列表与配置不同步（例如别处刚改过）时越界，什么也不做，下一次刷新后对上。
            if *index >= channels.len() {
                return false;
            }
            channels.remove(*index);
            return true;
        }
        ChannelEdit::AddName(name) => {
            let name = name.trim();
            if name.is_empty() {
                return false;
            }
            // 只有名字、没有 ID：按名字匹配日志里的频道（ChannelRef::matches 的第 2 条）。
            ChannelRef::new(name, None)
        }
        ChannelEdit::AddBuiltIn(index) => match ChannelRef::built_ins().into_iter().nth(*index) {
            Some(channel) => channel,
            None => return false,
        },
    };
    // 已满时页上的入口本已置灰；这里再挡一次，防止排队中的多次添加超过上限。
    if channels.len() >= MAX_CHANNELS || is_selected(channels, &candidate) {
        return false;
    }
    channels.push(candidate);
    true
}

/// 是否已选：两边都有 ID 时比 ID，否则比名字（都不区分大小写，名字去掉首尾空白）。
fn is_selected(channels: &[ChannelRef], candidate: &ChannelRef) -> bool {
    // 与配置校验去重的规则一致：校验会删掉重复项，这里不先加进去，界面就不会闪一下。
    channels
        .iter()
        .any(|existing| match (&existing.id, &candidate.id) {
            (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
            _ => existing.name.trim().to_lowercase() == candidate.name.trim().to_lowercase(),
        })
}

/// 列表里显示的名字：内置频道取本地化的名字，名字为空时显示 ID。
pub fn channel_name(channel: &ChannelRef, language: AppLanguage) -> String {
    // 内置频道的名字随客户端语言变（Local、本地……），列表里按界面语言显示，与配置里存的英文名无关。
    if channel.is_built_in() {
        let text = eveo_l10n::overlay(language);
        let id = channel.id.as_deref().unwrap_or_default().to_lowercase();
        let built_in = match id.as_str() {
            "local" => Some(text.built_in_local()),
            "corp" => Some(text.built_in_corp()),
            "alliance" => Some(text.built_in_alliance()),
            "fleet" => Some(text.built_in_fleet()),
            _ => None,
        };
        if let Some(name) = built_in {
            return name.to_owned();
        }
    }
    let name = channel.name.trim();
    if name.is_empty() {
        channel.id.clone().unwrap_or_default()
    } else {
        name.to_owned()
    }
}

/// 字符串列表转成 Slint 的模型。
fn strings(items: impl IntoIterator<Item = String>) -> ModelRc<SharedString> {
    let items: Vec<SharedString> = items.into_iter().map(SharedString::from).collect();
    ModelRc::new(VecModel::from(items))
}

/// 频道列表显示的名字。
fn channel_names(channels: &[ChannelRef]) -> ModelRc<SharedString> {
    let language = crate::language();
    strings(channels.iter().map(|c| channel_name(c, language)))
}

/// 声明顺序里的下标，找不到时取 0（每个枚举的第一项都是默认值）。
fn index_of<T: StringEnum + PartialEq>(value: T) -> i32 {
    T::ALL.iter().position(|v| *v == value).unwrap_or(0) as i32
}

/// 按下标取枚举值；下标越界（下拉框没有选中项为 -1）时返回 `None`，保留原值。
fn at_index<T: StringEnum + Copy>(index: i32) -> Option<T> {
    usize::try_from(index).ok().and_then(|i| T::ALL.get(i).copied())
}

/// 夹到范围内并按步长取最近的值。
/// 例如保留时长：范围 5～120、步长 5，输入框里打的 43 读回为 45。
fn stepped(value: i32, range: (i64, i64), step: i64) -> i64 {
    let value = i64::from(value).clamp(range.0, range.1);
    let base = range.0;
    (base + ((value - base) as f64 / step as f64).round() as i64 * step).clamp(range.0, range.1)
}

/// 浮窗外观的四个值：显示范围的下标、不透明度、字号、是否保存过位置。
/// 两页的浮窗设置字段相同，只是在两个全局里，用这个结构共用取值与写回的规则。
struct OverlayValues {
    visibility: i32,
    opacity: f32,
    font_size: f32,
    has_frame: bool,
}

impl OverlayValues {
    /// 从配置取值。
    fn of(panel: &OverlayPanelSettings) -> Self {
        Self {
            visibility: index_of(panel.visibility),
            opacity: panel.opacity as f32,
            font_size: panel.font_size as f32,
            has_frame: panel.frame.is_some(),
        }
    }

    /// 写回配置：不透明度取两位小数（滑块停在中间值），字号取整；位置不在这里改。
    fn write(&self, panel: &mut OverlayPanelSettings) {
        if let Some(visibility) = at_index::<OverlayVisibility>(self.visibility) {
            panel.visibility = visibility;
        }
        let (low, high) = OVERLAY_OPACITY_RANGE;
        panel.opacity = ((f64::from(self.opacity) * 100.0).round() / 100.0).clamp(low, high);
        let (low, high) = OVERLAY_FONT_SIZE_RANGE;
        panel.font_size = f64::from(self.font_size).round().clamp(low, high);
    }
}

/// 把预警设置显示到页上。
pub fn show_intel(ui: &SettingsWindow, intel: &IntelSettings) {
    let model = ui.global::<IntelModel>();
    model.set_enabled(intel.enabled);
    // 频道列表整个换掉：最多 16 项，重建模型的开销可以忽略，也不用逐行比较。
    model.set_channels(channel_names(&intel.channels));
    model.set_channels_full(intel.channels.len() >= MAX_CHANNELS);
    // 正在输入的文字与配置相同时不重写（不打扰光标）。
    let reference = intel.reference_system.clone().unwrap_or_default();
    if model.get_reference_system() != reference.as_str() {
        model.set_reference_system(reference.into());
    }
    // 三个数值的范围都在 0～120 内，放得进 i32。
    model.set_window_minutes(intel.window_minutes as i32);
    model.set_max_jumps(intel.max_jumps as i32);
    model.set_alert_jumps(intel.alert_jumps as i32);
    model.set_show_original(intel.show_original);
    model.set_resolve_pilots(intel.resolve_pilot_names);
    // 浮窗外观：拖滑块时每一步都触发 edited，这里再填回取整后的值，滑块停在合法的位置上。
    let overlay = OverlayValues::of(&intel.overlay);
    model.set_overlay_visibility(overlay.visibility);
    model.set_overlay_opacity(overlay.opacity);
    model.set_overlay_font_size(overlay.font_size);
    model.set_overlay_has_frame(overlay.has_frame);
}

/// 显示聊天日志的跟踪状态，同 macOS 的 intelStatusText。文字没变时不重设。
pub fn show_intel_status(ui: &SettingsWindow, status: &ChatLogStatus) {
    let text = chat_log_status_text(status);
    let model = ui.global::<IntelModel>();
    if model.get_status_text() != text.as_str() {
        model.set_status_text(text.into());
    }
}

/// 聊天日志状态的文字：未启用、监视中（目录与文件数）、找不到目录、没有读取权限（预警页与翻译页共用）。
pub fn chat_log_status_text(status: &ChatLogStatus) -> String {
    let strings = eveo_l10n::settings(crate::language());
    match status {
        ChatLogStatus::Stopped => strings.chat_log_status_stopped().to_owned(),
        ChatLogStatus::Watching {
            directory,
            followed_files,
        } => strings.chat_log_status_watching(directory, i64::try_from(*followed_files).unwrap_or(i64::MAX)),
        ChatLogStatus::DirectoryNotFound(path) => strings.chat_log_status_directory_not_found(path),
        ChatLogStatus::AccessDenied(path) => strings.chat_log_status_access_denied(path),
    }
}

/// 从页上读回预警设置。频道列表与浮窗位置不在这里改（见 ChannelEdit 与「恢复默认位置」）。
pub fn read_intel(ui: &SettingsWindow, intel: &mut IntelSettings) {
    let model = ui.global::<IntelModel>();
    intel.enabled = model.get_enabled();
    // 参考星系：去掉首尾空白后为空表示没有。
    let reference = model.get_reference_system();
    let trimmed = reference.trim();
    intel.reference_system = (!trimmed.is_empty()).then(|| trimmed.to_owned());
    // 数字框可以直接打字，打的数不一定在范围内或落在步长上，按配置的规则取整。
    intel.window_minutes = stepped(model.get_window_minutes(), INTEL_WINDOW_MINUTES_RANGE, 5);
    intel.max_jumps = stepped(model.get_max_jumps(), INTEL_MAX_JUMPS_RANGE, 1);
    intel.alert_jumps = stepped(model.get_alert_jumps(), INTEL_ALERT_JUMPS_RANGE, 1);
    intel.show_original = model.get_show_original();
    intel.resolve_pilot_names = model.get_resolve_pilots();
    OverlayValues {
        visibility: model.get_overlay_visibility(),
        opacity: model.get_overlay_opacity(),
        font_size: model.get_overlay_font_size(),
        has_frame: false,
    }
    .write(&mut intel.overlay);
}

/// 目标语言下拉的选项：「跟随界面语言」加 8 种语言的自称，顺序同 TranslationTarget。
/// 语言自称不翻译：用户找自己会读的语言时，认的是它本来的写法。
fn target_names(language: AppLanguage) -> Vec<String> {
    TranslationTarget::ALL
        .iter()
        .map(|target| match AppLanguage::from_raw(target.raw()) {
            Some(lang) => lang.autonym().to_owned(),
            None => eveo_l10n::translation(language).target_follow_ui().to_owned(),
        })
        .collect()
}

/// 服务下拉的名字：「自定义」一项用界面文字，其余用不翻译的服务名。
fn provider_names(language: AppLanguage) -> Vec<String> {
    TranslationProviderId::ALL
        .iter()
        .map(|&id| match id {
            TranslationProviderId::Custom => eveo_l10n::translation(language).provider_custom().to_owned(),
            _ => id.preset().display_name.to_owned(),
        })
        .collect()
}

/// 把翻译设置与模型服务显示到页上。
pub fn show_translation(
    ui: &SettingsWindow,
    translation: &TranslationSettings,
    endpoint: &TranslationEndpointSettings,
) {
    let model = ui.global::<TranslationModel>();
    let language = crate::language();
    // 下拉的文字随界面语言变，每次显示都重新填（换语言后各页整页重填）。
    model.set_enabled(translation.enabled);
    model.set_channels(channel_names(&translation.channels));
    model.set_channels_full(translation.channels.len() >= MAX_CHANNELS);
    // 内置频道的按钮：已选的置灰，顺序同 ChannelRef::built_ins。
    let selected: Vec<bool> = ChannelRef::built_ins()
        .iter()
        .map(|c| is_selected(&translation.channels, c))
        .collect();
    model.set_built_in_selected(ModelRc::new(VecModel::from(selected)));
    model.set_target_names(strings(target_names(language)));
    model.set_target(index_of(translation.target_language));
    model.set_show_original(translation.show_original);
    model.set_foreign_only(translation.foreign_only);
    model.set_provider_names(strings(provider_names(language)));
    model.set_provider(index_of(endpoint.provider));
    // 输入框的文字与配置相同时不重写（不打扰光标）。
    if model.get_base_url() != endpoint.base_url.as_str() {
        model.set_base_url(endpoint.base_url.as_str().into());
    }
    if model.get_model() != endpoint.model.as_str() {
        model.set_model(endpoint.model.as_str().into());
    }
    // 提示文字是预设的默认值：留空就用它，与 macOS 的输入框相同。
    let preset = endpoint.provider.preset();
    model.set_base_url_placeholder(preset.base_url.into());
    model.set_model_placeholder(preset.model.into());
    // 「自定义」的接口要不要 Key 由用户决定，所以也显示 Key 一行。
    model.set_uses_key(preset.requires_key || endpoint.provider == TranslationProviderId::Custom);
    let overlay = OverlayValues::of(&translation.overlay);
    model.set_overlay_visibility(overlay.visibility);
    model.set_overlay_opacity(overlay.opacity);
    model.set_overlay_font_size(overlay.font_size);
    model.set_overlay_has_frame(overlay.has_frame);
}

/// 从页上读回翻译设置与模型服务。换了预设时地址与模型名回到预设值（清空）。
pub fn read_translation(
    ui: &SettingsWindow,
    translation: &mut TranslationSettings,
    endpoint: &mut TranslationEndpointSettings,
) {
    let model = ui.global::<TranslationModel>();
    translation.enabled = model.get_enabled();
    if let Some(target) = at_index::<TranslationTarget>(model.get_target()) {
        translation.target_language = target;
    }
    translation.show_original = model.get_show_original();
    translation.foreign_only = model.get_foreign_only();
    OverlayValues {
        visibility: model.get_overlay_visibility(),
        opacity: model.get_overlay_opacity(),
        font_size: model.get_overlay_font_size(),
        has_frame: false,
    }
    .write(&mut translation.overlay);
    // 地址与模型名属于预设：换了预设还留着旧地址，请求就会发到旧服务，所以一并清掉。
    match at_index::<TranslationProviderId>(model.get_provider()) {
        Some(provider) if provider != endpoint.provider => {
            *endpoint = TranslationEndpointSettings {
                provider,
                ..TranslationEndpointSettings::default()
            };
        }
        _ => {
            endpoint.base_url = model.get_base_url().trim().to_owned();
            endpoint.model = model.get_model().trim().to_owned();
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// 频道的增删：不重复、不超过 16 项、空白名字与越界下标什么也不做。
    #[test]
    fn channel_edits() {
        // 从空列表开始，依次试添加、重复添加、空白名字、内置频道与越界下标。
        let mut channels = Vec::new();
        assert!(apply_channel_edit(
            &mut channels,
            &ChannelEdit::AddName(" Intel.North ".into())
        ));
        assert_eq!(channels[0].name, "Intel.North");
        // 大小写不同的名字视为同一个。
        assert!(!apply_channel_edit(
            &mut channels,
            &ChannelEdit::AddName("intel.north".into())
        ));
        assert!(!apply_channel_edit(
            &mut channels,
            &ChannelEdit::AddName("   ".into())
        ));
        assert!(apply_channel_edit(&mut channels, &ChannelEdit::AddBuiltIn(0)));
        assert!(!apply_channel_edit(&mut channels, &ChannelEdit::AddBuiltIn(0)));
        assert!(!apply_channel_edit(&mut channels, &ChannelEdit::AddBuiltIn(9)));
        assert_eq!(channels[1].id.as_deref(), Some("local"));
        assert!(!apply_channel_edit(&mut channels, &ChannelEdit::Remove(5)));
        assert!(apply_channel_edit(&mut channels, &ChannelEdit::Remove(0)));
        assert_eq!(channels.len(), 1);
        // 加满：超过 16 项的添加被忽略。
        for i in 0..20 {
            apply_channel_edit(&mut channels, &ChannelEdit::AddName(format!("c{i}")));
        }
        assert_eq!(channels.len(), MAX_CHANNELS);
    }

    /// 内置频道显示本地化的名字，名字为空的频道显示 ID。
    #[test]
    fn channel_names_follow_language() {
        let local = &ChannelRef::built_ins()[0];
        assert_eq!(channel_name(local, AppLanguage::Zh), "本地");
        assert_eq!(channel_name(local, AppLanguage::En), "Local");
        assert_eq!(
            channel_name(&ChannelRef::new(" ", Some("player_9")), AppLanguage::En),
            "player_9"
        );
    }

    /// 页面内容：显示再读回不变；用户的改动按规则写回。由 bind 的 Slint 用例调用。
    pub(crate) fn check_page(ui: &SettingsWindow) {
        // 页上的名字按中文显示；读回只看值，与语言无关。
        crate::language::set_for_test(AppLanguage::Zh);
        let mut intel = IntelSettings {
            enabled: true,
            reference_system: Some("Jita".to_owned()),
            window_minutes: 45,
            ..IntelSettings::default()
        };
        intel.overlay.visibility = OverlayVisibility::GameOnly;
        show_intel(ui, &intel);
        let mut read = intel.clone();
        read_intel(ui, &mut read);
        assert_eq!(read, intel);
        // 步长 5、夹到范围、空白的参考星系。
        let model = ui.global::<IntelModel>();
        model.set_window_minutes(43);
        model.set_alert_jumps(99);
        model.set_reference_system("  ".into());
        model.set_overlay_opacity(0.333);
        read_intel(ui, &mut read);
        assert_eq!((read.window_minutes, read.alert_jumps), (45, 30));
        assert_eq!(read.reference_system, None);
        assert_eq!(read.overlay.opacity, 0.33);

        // 翻译页：俄语目标、选了本地频道、OpenAI 预设加自定义地址。
        let translation = TranslationSettings {
            target_language: TranslationTarget::Ru,
            channels: ChannelRef::built_ins()[..1].to_vec(),
            ..TranslationSettings::default()
        };
        let endpoint = TranslationEndpointSettings {
            provider: TranslationProviderId::OpenAi,
            base_url: "https://proxy.example/v1".to_owned(),
            model: String::new(),
        };
        show_translation(ui, &translation, &endpoint);
        let model = ui.global::<TranslationModel>();
        assert_eq!(model.get_target(), 3);
        assert_eq!(model.get_model_placeholder(), "gpt-6-luna");
        assert!(slint::Model::row_data(&model.get_built_in_selected(), 0).unwrap());
        let (mut t, mut e) = (translation.clone(), endpoint.clone());
        read_translation(ui, &mut t, &mut e);
        assert_eq!((t.clone(), e.clone()), (translation.clone(), endpoint.clone()));
        // 换预设：地址与模型名清空。
        model.set_provider(index_of(TranslationProviderId::Ollama));
        read_translation(ui, &mut t, &mut e);
        assert_eq!(
            e,
            TranslationEndpointSettings {
                provider: TranslationProviderId::Ollama,
                ..TranslationEndpointSettings::default()
            }
        );
    }
}
