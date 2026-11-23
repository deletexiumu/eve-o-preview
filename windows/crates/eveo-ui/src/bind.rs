// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口与配置之间的转换，对应 macOS SettingsViewModel 的 binding（架构文档 3.3 节）。
// - show_*：把配置里的值填进各页的全局模型。协调器每次采用新配置后都调一次，窗口与配置保持一致。
// - read_*：把页上的值读回配置。用户改了任何一项，应用就读回整页、组成完整配置交给协调器，
//   取值范围由协调器里的配置校验夹取，这里只做界面特有的换算（百分比、步长、颜色写法）。
// 颜色输入框允许输入到一半：只有完整的 #RRGGBB 才会写回配置，否则保留原值，样本颜色也不变。
//
// 为什么读回整页而不是逐项回调：页上的值与配置字段一一对应，整页读回只有几十次属性读取，
// 却省掉了几十个回调的接线；读回后与原配置比较，没变就不交给协调器，不会多出一次重算与写盘。
// 这个模块不依赖 Windows，转换规则在 Linux 上用软件渲染平台做单元测试。

//! 设置窗口的各页与配置互相转换。

use eveo_core::model::{Profile, ZoomAnchor};
use eveo_core::support::hex_color;
use slint::{Color, ComponentHandle, SharedString};

use crate::{PreviewsModel, SettingsWindow};

/// 锚点下拉框的顺序：与 previews.slint 里的选项一一对应。
/// 按方位排成 3×3 的阅读顺序（先上排，再中排，最后下排），与配置的枚举顺序相同。
pub const ANCHORS: [ZoomAnchor; 9] = [
    ZoomAnchor::Nw,
    ZoomAnchor::N,
    ZoomAnchor::Ne,
    ZoomAnchor::W,
    ZoomAnchor::Center,
    ZoomAnchor::E,
    ZoomAnchor::Sw,
    ZoomAnchor::S,
    ZoomAnchor::Se,
];

/// 把配置方案的缩略图、叠层与行为设置填进「预览与布局」页。
pub fn show_previews(ui: &SettingsWindow, profile: &Profile) {
    let model = ui.global::<PreviewsModel>();
    let thumbnail = &profile.thumbnail;
    let overlay = &profile.overlay;
    let behavior = &profile.behavior;
    // 尺寸、字号与粗细在配置里是浮点或 64 位整数，界面上是整数：校验已把它们夹在小范围内，换算不会溢出。
    model.set_default_width(thumbnail.default_size.width.round() as i32);
    model.set_default_height(thumbnail.default_size.height.round() as i32);
    model.set_opacity(thumbnail.opacity as f32);
    model.set_show_title(overlay.show_title);
    model.set_title_font_size(overlay.title_font_size.round() as i32);
    set_color(&model, Field::Title, &overlay.title_color);
    model.set_highlight_enabled(overlay.highlight_enabled);
    set_color(&model, Field::Highlight, &overlay.highlight_color);
    model.set_highlight_thickness(overlay.highlight_thickness as i32);
    model.set_border_enabled(overlay.border_enabled);
    set_color(&model, Field::Border, &overlay.border_color);
    model.set_border_thickness(overlay.border_thickness as i32);
    model.set_zoom_enabled(thumbnail.zoom_enabled);
    model.set_zoom_factor(thumbnail.zoom_factor as i32);
    // 锚点是枚举，下拉框要下标；ANCHORS 覆盖了全部取值，找不到只可能是将来新增了锚点，先显示成左上角。
    let anchor = ANCHORS
        .iter()
        .position(|a| *a == thumbnail.zoom_anchor)
        .unwrap_or(0);
    model.set_zoom_anchor(anchor as i32);
    // 行为与布局：开关一一对应，隐藏延迟在界面上是秒数滑块。
    model.set_always_on_top(behavior.always_on_top);
    model.set_hide_active(behavior.hide_active_client_thumbnail);
    model.set_hide_when_not_eve(behavior.hide_when_eve_not_frontmost);
    model.set_hide_delay(behavior.hide_delay_seconds as f32);
    model.set_snap_enabled(thumbnail.snap_enabled);
    model.set_lock_aspect(thumbnail.lock_aspect_ratio);
    model.set_lock_layout(behavior.lock_layout);
}

/// 把「预览与布局」页的值读回配置方案。没变的字段保持原样，所以读回再显示不会抖动。
pub fn read_previews(ui: &SettingsWindow, profile: &mut Profile) {
    let model = ui.global::<PreviewsModel>();
    // 按配置的三个分组依次写回；只写本页管的字段，layouts、热键等其余部分原样保留。
    let thumbnail = &mut profile.thumbnail;
    thumbnail.default_size.width = f64::from(model.get_default_width());
    thumbnail.default_size.height = f64::from(model.get_default_height());
    // 滑块是连续的；存两位小数，配置文件里不出现 0.4999999 这样的值。
    thumbnail.opacity = (f64::from(model.get_opacity()) * 100.0).round() / 100.0;
    thumbnail.zoom_enabled = model.get_zoom_enabled();
    thumbnail.zoom_factor = i64::from(model.get_zoom_factor());
    // 下拉框没有选中项时下标是 -1，这时保留原来的锚点。
    if let Some(anchor) = usize::try_from(model.get_zoom_anchor())
        .ok()
        .and_then(|i| ANCHORS.get(i))
    {
        thumbnail.zoom_anchor = *anchor;
    }
    thumbnail.snap_enabled = model.get_snap_enabled();
    thumbnail.lock_aspect_ratio = model.get_lock_aspect();

    // 叠层：字号与粗细从整数换回配置的类型；颜色只在输入完整时才写回。
    let overlay = &mut profile.overlay;
    overlay.show_title = model.get_show_title();
    overlay.title_font_size = f64::from(model.get_title_font_size());
    read_color(&model.get_title_color(), &mut overlay.title_color);
    overlay.highlight_enabled = model.get_highlight_enabled();
    read_color(&model.get_highlight_color(), &mut overlay.highlight_color);
    overlay.highlight_thickness = i64::from(model.get_highlight_thickness());
    overlay.border_enabled = model.get_border_enabled();
    read_color(&model.get_border_color(), &mut overlay.border_color);
    overlay.border_thickness = i64::from(model.get_border_thickness());

    // 行为：隐藏当前客户端、EVE 不在前台时隐藏、锁定布局等。
    let behavior = &mut profile.behavior;
    behavior.always_on_top = model.get_always_on_top();
    behavior.hide_active_client_thumbnail = model.get_hide_active();
    behavior.hide_when_eve_not_frontmost = model.get_hide_when_not_eve();
    // 步长 0.5 秒：滑块拖动时可能停在中间值，这里取最近的半秒。
    behavior.hide_delay_seconds = (f64::from(model.get_hide_delay()) * 2.0).round() / 2.0;
    behavior.lock_layout = model.get_lock_layout();
}

/// 「统一尺寸」：清掉各角色单独调过的宽高，位置保留，缩略图回到默认尺寸（同 macOS）。
pub fn unify_sizes(profile: &mut Profile) {
    // 只清尺寸，不删条目：条目里还记着位置与所在显示器。
    for layout in profile.layouts.values_mut() {
        layout.width = None;
        layout.height = None;
    }
}

/// 页上的三个颜色字段。
#[derive(Clone, Copy)]
enum Field {
    /// 角色名颜色。
    Title,
    /// 高亮颜色。
    Highlight,
    /// 边框颜色。
    Border,
}

/// 设一个颜色字段的文字与样本。三个颜色字段的属性名不同，用 Field 区分，规则只写一遍。
/// 文字统一写成大写的 #RRGGBB；解析不了时样本用灰色，文字照原样显示。
fn set_color(model: &PreviewsModel<'_>, field: Field, hex: &str) {
    // 灰色在明暗两种背景上都看得见，提示这个值没被采用。
    let swatch = swatch(hex).unwrap_or(Color::from_rgb_u8(0x80, 0x80, 0x80));
    let text = SharedString::from(normalized_hex(hex).unwrap_or_else(|| hex.to_owned()));
    match field {
        Field::Title => {
            set_if_changed(model.get_title_color(), text, |t| model.set_title_color(t));
            model.set_title_swatch(swatch);
        }
        Field::Highlight => {
            set_if_changed(model.get_highlight_color(), text, |t| {
                model.set_highlight_color(t)
            });
            model.set_highlight_swatch(swatch);
        }
        Field::Border => {
            set_if_changed(model.get_border_color(), text, |t| model.set_border_color(t));
            model.set_border_swatch(swatch);
        }
    }
}

/// 文字不同时才写：输入框正在编辑时，写入相同的文字也可能把光标移到末尾。
/// 大小写不同（用户输入了小写）视为相同，不改用户正在输入的文字。
fn set_if_changed(current: SharedString, text: SharedString, set: impl FnOnce(SharedString)) {
    if !current.eq_ignore_ascii_case(&text) {
        set(text);
    }
}

/// 输入框里的文字是完整的 `#RRGGBB` 时写回配置（统一成大写），否则保留原值。
fn read_color(text: &str, target: &mut String) {
    if let Some(hex) = normalized_hex(text) {
        *target = hex;
    }
}

/// `#rrggbb`（可带首尾空白，`#` 可省略，同 Core 的解析）规范成大写的 `#RRGGBB`；其他写法返回 `None`。
fn normalized_hex(text: &str) -> Option<String> {
    let trimmed = text.trim();
    // 合法性交给 Core 判断，与配置校验用同一套规则；这里只负责统一写法。
    hex_color::components(trimmed)?;
    let digits = trimmed.trim_start_matches('#');
    Some(format!("#{}", digits.to_ascii_uppercase()))
}

/// 颜色字符串换成样本颜色。
fn swatch(hex: &str) -> Option<Color> {
    let (r, g, b) = hex_color::components(hex.trim())?;
    // Core 给出 0～1 的分量，换回 0～255 的字节。
    let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    Some(Color::from_rgb_u8(byte(r), byte(g), byte(b)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use eveo_core::model::ThumbnailLayout;

    /// 一个改过若干默认值的配置方案，用来核对每个字段都能来回。
    fn sample() -> Profile {
        let mut profile = Profile::make_new("p1", "Main");
        profile.thumbnail.default_size.width = 400.0;
        profile.thumbnail.default_size.height = 225.0;
        profile.thumbnail.opacity = 0.75;
        profile.thumbnail.zoom_enabled = true;
        profile.thumbnail.zoom_factor = 3;
        profile.thumbnail.zoom_anchor = ZoomAnchor::Se;
        profile.thumbnail.snap_enabled = false;
        profile.thumbnail.lock_aspect_ratio = true;
        profile.overlay.show_title = false;
        profile.overlay.title_font_size = 14.0;
        profile.overlay.title_color = "#112233".to_owned();
        profile.overlay.highlight_color = "#AABBCC".to_owned();
        profile.overlay.highlight_thickness = 5;
        profile.overlay.border_enabled = false;
        profile.overlay.border_thickness = 4;
        profile.behavior.always_on_top = false;
        profile.behavior.hide_active_client_thumbnail = true;
        profile.behavior.hide_when_eve_not_frontmost = true;
        profile.behavior.hide_delay_seconds = 2.5;
        profile.behavior.lock_layout = true;
        profile
    }

    /// Slint 的平台每个进程只能设一次，所以全部断言放在一个用例里，按场景分段。
    #[test]
    fn previews_page_round_trips_and_reads_edits() {
        crate::screenshot::ensure_platform().expect("软件渲染平台");
        let ui = SettingsWindow::new().expect("建窗口");

        // 显示再读回：每个字段都不变。
        let original = sample();
        show_previews(&ui, &original);
        let mut read = original.clone();
        read_previews(&ui, &mut read);
        assert_eq!(read, original);
        let model = ui.global::<PreviewsModel>();
        assert_eq!(model.get_zoom_anchor(), 8);
        assert_eq!(model.get_title_swatch(), Color::from_rgb_u8(0x11, 0x22, 0x33));

        // 用户的改动：滑块停在中间值时按百分比与半秒取整；小写颜色统一成大写。
        model.set_opacity(0.4271);
        model.set_hide_delay(3.3);
        model.set_border_color("#00ff7f".into());
        model.set_zoom_anchor(4);
        let mut edited = original.clone();
        read_previews(&ui, &mut edited);
        assert_eq!(edited.thumbnail.opacity, 0.43);
        assert_eq!(edited.behavior.hide_delay_seconds, 3.5);
        assert_eq!(edited.overlay.border_color, "#00FF7F");
        assert_eq!(edited.thumbnail.zoom_anchor, ZoomAnchor::Center);

        // 输入到一半的颜色不写回配置；之后再显示配置（例如别处改了配置）时恢复成已采用的值。
        model.set_title_color("#12".into());
        let mut partial = original.clone();
        read_previews(&ui, &mut partial);
        assert_eq!(partial.overlay.title_color, "#112233");
        show_previews(&ui, &partial);
        assert_eq!(model.get_title_color(), "#112233");
        // 小写的完整颜色与配置相同：显示时不改写用户的输入。
        model.set_highlight_color("#aabbcc".into());
        show_previews(&ui, &original);
        assert_eq!(model.get_highlight_color(), "#aabbcc");
    }

    /// 统一尺寸只清宽高，位置不动。
    #[test]
    fn unify_sizes_keeps_positions() {
        let mut profile = sample();
        profile.layouts.insert(
            "Aria".to_owned(),
            ThumbnailLayout {
                x: 10.0,
                y: 20.0,
                width: Some(500.0),
                height: Some(280.0),
            },
        );
        unify_sizes(&mut profile);
        let layout = &profile.layouts["Aria"];
        assert_eq!(
            (layout.x, layout.y, layout.width, layout.height),
            (10.0, 20.0, None, None)
        );
    }

    /// 颜色写法：首尾空白去掉、补上 #、统一大写；不完整或不合法的返回 None。
    #[test]
    fn hex_normalization() {
        assert_eq!(normalized_hex(" #a1b2c3 ").as_deref(), Some("#A1B2C3"));
        assert_eq!(normalized_hex("#a1b2c"), None);
        assert_eq!(normalized_hex("a1b2c3").as_deref(), Some("#A1B2C3"));
        assert_eq!(normalized_hex("#GGGGGG"), None);
    }
}
