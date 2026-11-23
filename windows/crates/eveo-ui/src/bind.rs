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
//
// 「客户端」页除了配置，还要协调器的在线客户端与「全部隐藏」状态，应用在每次处理完事件后刷新它。
// 刷新很频繁（每秒的轮询都会触发），所以逐行比较、只改变了的行；颜色输入框只在配置里的值变了时才改写，
// 用户输到一半的颜色不会被下一次轮询冲掉。角色的改动是单项的（某个角色的颜色或开关），
// 由 ClientEdit 描述，应用把它作用到当前配置上再交给协调器。

//! 设置窗口的各页与配置互相转换。

use std::rc::Rc;

use eveo_core::clients::title::display_title;
use eveo_core::hotkeys::{HotkeyScope, HotkeySpec};
use eveo_core::model::{EveClient, Profile, ZoomAnchor};
use eveo_core::support::hex_color;
use slint::{Color, ComponentHandle, Model, ModelRc, SharedString, VecModel};

use crate::{CharacterRow, ClientsModel, PreviewsModel, SettingsWindow};

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

// MARK: 客户端

/// 「客户端」页上对某个角色的一次改动。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientEdit {
    /// 显示或隐藏该角色的缩略图（隐藏名单，持久化）。
    Shown {
        /// 角色名。
        name: String,
        /// 是否显示。
        shown: bool,
    },
    /// 改了该角色颜色输入框里的文字。
    Color {
        /// 角色名。
        name: String,
        /// 输入框里的文字，可能还没输完。
        text: String,
    },
    /// 「默认」：回到跟随全局高亮颜色。
    ResetColor {
        /// 角色名。
        name: String,
    },
}

/// 把一次改动作用到配置方案上。没有效果的改动（颜色还没输完、开关与现状相同）不改配置。
pub fn apply_client_edit(profile: &mut Profile, edit: &ClientEdit) {
    match edit {
        // 隐藏名单是配置的一部分，关掉后重启、换机器（同步配置文件）都保持隐藏。
        ClientEdit::Shown { name, shown } => {
            // 先去掉再按需加回，名单里不会出现重复的名字。
            profile.hidden_characters.retain(|n| n != name);
            if !shown {
                profile.hidden_characters.push(name.clone());
            }
        }
        ClientEdit::Color { name, text } => {
            // 清空输入框等于「默认」；完整的颜色才写回，输到一半的不动。
            if text.trim().is_empty() {
                profile.highlight_colors.remove(name);
            } else if let Some(hex) = normalized_hex(text) {
                profile.highlight_colors.insert(name.clone(), hex);
            }
        }
        // 「默认」按钮：删掉按角色的颜色，样本与缩略图都回到全局高亮颜色。
        ClientEdit::ResetColor { name } => {
            profile.highlight_colors.remove(name);
        }
    }
}

/// 全部已知角色：在线的，加上配置方案里出现过的（布局、隐藏名单、颜色、直达热键、循环组），
/// 按名称排序，不区分大小写；只差大小写的两个名字再按原样排，顺序稳定。
pub fn character_names(profile: &Profile, clients: &[EveClient]) -> Vec<String> {
    let mut names: Vec<String> = clients
        .iter()
        .filter_map(|c| c.character_name().map(str::to_owned))
        .chain(profile.layouts.keys().cloned())
        .chain(profile.hidden_characters.iter().cloned())
        .chain(profile.highlight_colors.keys().cloned())
        .chain(profile.character_hotkeys.keys().cloned())
        .chain(
            profile
                .cycle_groups
                .iter()
                .flat_map(|g| g.members.iter().cloned()),
        )
        .collect();
    names.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()).then_with(|| a.cmp(b)));
    // 排序后相同的名字相邻，去重只去完全相同的；只差大小写的两个角色是不同的角色（EVE 角色名不区分大小写，
    // 但配置是手改的也可能出现，两行都显示，用户能看出来）。
    names.dedup();
    names
}

/// 按协调器的状态填「客户端」页。`clients` 是当前在线的客户端，`hide_all` 是会话里的「全部隐藏」。
pub fn show_clients(ui: &SettingsWindow, profile: &Profile, clients: &[EveClient], hide_all: bool) {
    let model = ui.global::<ClientsModel>();
    // 页首：「全部隐藏」与它的快捷键（只读，修改在「切换与热键」页）。
    model.set_hide_all(hide_all);
    model.set_hide_all_hotkeys(hotkey_text(profile, &profile.hotkeys.toggle_hide_all).into());
    // 全局高亮颜色：跟随时作为输入框的提示文字，也是样本的颜色。
    let global = normalized_hex(&profile.overlay.highlight_color)
        .unwrap_or_else(|| profile.overlay.highlight_color.clone());
    model.set_default_highlight(global.as_str().into());

    // 角色卡片：每个已知角色一行，在线与否看当前的客户端列表。
    let online: Vec<&str> = clients.iter().filter_map(EveClient::character_name).collect();
    let rows: Vec<CharacterRow> = character_names(profile, clients)
        .into_iter()
        .map(|name| {
            let applied = profile
                .highlight_colors
                .get(&name)
                .map(|hex| normalized_hex(hex).unwrap_or_else(|| hex.clone()))
                .unwrap_or_default();
            // 样本：按角色的颜色，没有（或写坏了）时用全局颜色，再不行用灰色。
            let swatch = swatch(&applied)
                .or_else(|| swatch(&global))
                .unwrap_or(Color::from_rgb_u8(0x80, 0x80, 0x80));
            CharacterRow {
                online: online.contains(&name.as_str()),
                shown: !profile.hidden_characters.contains(&name),
                color: applied.as_str().into(),
                applied: applied.into(),
                swatch,
                name: name.into(),
            }
        })
        .collect();
    update_rows(&model, rows);

    // 登录界面与未知的客户端：只列标题，与缩略图上的标题一致。
    let logins: Vec<SharedString> = clients
        .iter()
        .filter(|c| c.character_name().is_none())
        .map(|c| display_title(&c.identity, c.pid).into())
        .collect();
    // 登录客户端不常变；内容相同时不换模型，避免重建卡片。
    let current = model.get_login_clients();
    if current.iter().ne(logins.iter().cloned()) {
        model.set_login_clients(ModelRc::new(VecModel::from(logins)));
    }
}

/// 更新角色列表。角色名的顺序没变时逐行比较、只改变了的行（卡片不重建，输入框不丢焦点）；
/// 颜色文字只在配置里的值变了时改写，保留用户正在输入的文字。顺序变了（有新角色）时整份换掉。
fn update_rows(model: &ClientsModel<'_>, rows: Vec<CharacterRow>) {
    let current = model.get_characters();
    // 只比角色名的顺序：在线状态、颜色、开关的变化都能逐行更新。
    let same_names =
        current.row_count() == rows.len() && current.iter().zip(&rows).all(|(old, new)| old.name == new.name);
    // 模型一直是这里建的 VecModel；取不到（第一次显示时是 Slint 的空模型）就整份建一个。
    let vec = current.as_any().downcast_ref::<VecModel<CharacterRow>>();
    match vec {
        Some(vec) if same_names => {
            for (index, mut row) in rows.into_iter().enumerate() {
                let Some(old) = vec.row_data(index) else {
                    continue;
                };
                // 配置里的颜色没变：保留输入框里的文字（可能正输到一半，或是小写的同一个颜色）。
                if old.applied == row.applied {
                    row.color = old.color.clone();
                }
                // 整行相同就不写，避免无谓的重绘。
                if old != row {
                    vec.set_row_data(index, row);
                }
            }
        }
        _ => model.set_characters(ModelRc::from(Rc::new(VecModel::from(rows)))),
    }
}

/// 热键列表的界面写法：每条是「组合键（作用范围）」，多条用顿号隔开；解析不了的照原样显示。
fn hotkey_text(profile: &Profile, list: &[String]) -> String {
    list.iter()
        .map(|raw| match HotkeySpec::parse(raw) {
            // 没写作用范围的热键跟随配置方案的默认范围，显示解析后的范围，用户不必再去查默认值。
            Some(spec) => {
                let scope = match spec.resolved_scope(profile.hotkey_default_scope) {
                    HotkeyScope::Global => "全局",
                    HotkeyScope::Game => "仅游戏内",
                };
                format!("{}（{scope}）", spec.hotkey.display_string())
            }
            // 手改坏的热键照原样显示，用户能认出来去「切换与热键」页修正。
            None => raw.clone(),
        })
        .collect::<Vec<_>>()
        .join("、")
}

#[cfg(test)]
mod tests {
    use super::*;
    use eveo_core::geometry::ScreenRect;
    use eveo_core::model::{ClientIdentity, Pid, ThumbnailLayout, WindowId};

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

        clients_page(&ui);
    }

    /// 「客户端」页：行的内容、刷新时保留输入到一半的颜色、配置变了才改写。
    fn clients_page(ui: &SettingsWindow) {
        let mut profile = Profile::make_new("p1", "Main");
        profile.hidden_characters.push("Zed".to_owned());
        profile
            .highlight_colors
            .insert("bravo".to_owned(), "#ff8c00".to_owned());
        let clients = vec![client(1, "Alpha"), client(2, "bravo"), login(3)];
        show_clients(ui, &profile, &clients, true);
        let model = ui.global::<ClientsModel>();
        assert!(model.get_hide_all());
        let rows: Vec<CharacterRow> = model.get_characters().iter().collect();
        let names: Vec<&str> = rows.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["Alpha", "bravo", "Zed"]);
        assert!(rows[0].online && rows[0].shown && rows[0].color.is_empty());
        assert_eq!(rows[1].color, "#FF8C00");
        assert_eq!(rows[1].swatch, Color::from_rgb_u8(0xFF, 0x8C, 0x00));
        assert!(!rows[2].online && !rows[2].shown);
        let logins: Vec<SharedString> = model.get_login_clients().iter().collect();
        assert_eq!(logins, ["EVE"]);

        // 用户在 Alpha 的输入框里输到一半；下一次刷新（配置没变）保留输入。
        // 这里直接改模型的行，相当于界面里双向绑定写回的效果。
        let characters = model.get_characters();
        let mut alpha = characters.row_data(0).unwrap();
        alpha.color = "#12".into();
        characters.set_row_data(0, alpha);
        show_clients(ui, &profile, &clients, false);
        assert_eq!(model.get_characters().row_data(0).unwrap().color, "#12");
        assert!(!model.get_hide_all());
        // 配置里 Alpha 的颜色变了（例如在别处设了）：改写成新值。
        profile
            .highlight_colors
            .insert("Alpha".to_owned(), "#00FF00".to_owned());
        show_clients(ui, &profile, &clients, false);
        assert_eq!(model.get_characters().row_data(0).unwrap().color, "#00FF00");
        // 新角色上线：列表整份换掉，顺序仍按名称。
        let more = vec![client(1, "Alpha"), client(2, "bravo"), client(4, "Charlie")];
        show_clients(ui, &profile, &more, false);
        let names: Vec<SharedString> = model.get_characters().iter().map(|r| r.name).collect();
        assert_eq!(names, ["Alpha", "bravo", "Charlie", "Zed"]);
        assert_eq!(model.get_login_clients().row_count(), 0);
    }

    /// 在线的角色客户端。
    fn client(id: u64, name: &str) -> EveClient {
        EveClient {
            id: WindowId(id),
            pid: id as Pid,
            identity: ClientIdentity::Character(name.to_owned()),
            window_frame: ScreenRect::new(0.0, 0.0, 1280.0, 720.0),
            is_on_screen: true,
            is_minimized: Some(false),
            is_full_screen: Some(false),
        }
    }

    /// 在线的登录界面客户端。
    fn login(id: u64) -> EveClient {
        EveClient {
            identity: ClientIdentity::Login,
            ..client(id, "")
        }
    }

    /// 角色的改动：开关改隐藏名单（不重复），颜色只在完整时写回，清空与「默认」都回到跟随。
    #[test]
    fn client_edits_change_profile() {
        let mut profile = Profile::make_new("p1", "Main");
        let shown = |name: &str, shown: bool| ClientEdit::Shown {
            name: name.to_owned(),
            shown,
        };
        // 关两次也只记一次。
        apply_client_edit(&mut profile, &shown("Aria", false));
        apply_client_edit(&mut profile, &shown("Aria", false));
        assert_eq!(profile.hidden_characters, ["Aria"]);
        apply_client_edit(&mut profile, &shown("Aria", true));
        assert!(profile.hidden_characters.is_empty());

        let color = |text: &str| ClientEdit::Color {
            name: "Aria".to_owned(),
            text: text.to_owned(),
        };
        // 输到一半不写；完整的写成大写；清空回到跟随；「默认」同样回到跟随。
        apply_client_edit(&mut profile, &color("#ab"));
        assert!(profile.highlight_colors.is_empty());
        apply_client_edit(&mut profile, &color("#abcdef"));
        assert_eq!(profile.highlight_colors["Aria"], "#ABCDEF");
        apply_client_edit(&mut profile, &color("  "));
        assert!(profile.highlight_colors.is_empty());
        apply_client_edit(&mut profile, &color("#abcdef"));
        apply_client_edit(
            &mut profile,
            &ClientEdit::ResetColor {
                name: "Aria".to_owned(),
            },
        );
        assert!(profile.highlight_colors.is_empty());
    }

    /// 角色名来自在线客户端与配置的各处，去重后不区分大小写排序；热键按界面写法显示作用范围。
    #[test]
    fn character_names_and_hotkey_text() {
        let mut profile = Profile::make_new("p1", "Main");
        profile
            .layouts
            .insert("delta".to_owned(), ThumbnailLayout::default());
        profile.character_hotkeys.insert("Charlie".to_owned(), vec![]);
        profile.cycle_groups.push(eveo_core::model::CycleGroup {
            members: vec!["Bravo".to_owned(), "Alpha".to_owned()],
            ..Default::default()
        });
        // Alpha 在线又在循环组里，只出现一次；登录客户端没有角色名，不出现。
        let names = character_names(&profile, &[client(1, "Alpha"), login(2)]);
        assert_eq!(names, ["Alpha", "Bravo", "Charlie", "delta"]);

        // 默认范围设成仅游戏内：没写后缀的 F13 显示为仅游戏内。
        profile.hotkey_default_scope = HotkeyScope::Game;
        let list = vec![
            "ctrl+alt+shift+H@global".to_owned(),
            "F13".to_owned(),
            "bogus+".to_owned(),
        ];
        assert_eq!(
            hotkey_text(&profile, &list),
            "Ctrl+Alt+Shift+H（全局）、F13（仅游戏内）、bogus+"
        );
        assert_eq!(hotkey_text(&profile, &[]), "");
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
