// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页的运行时状态，对应 macOS 的 SettingsViewModel+Intel.swift 里读控制器的那几项：
// - 我的位置：每个在线角色一行（名字、位置文字、有没有记录、上次输入的星系是否查不到）。
// - 参考星系查不到的提示、人名核对的状态与缓存条数、星图数据一行。
// 配置（开关、频道、参考星系、显示、浮窗）在 chat 模块里整页显示与读回；这里只显示应用层算好的状态。
// 文字都由应用层按界面语言算好（eveo-app-core::chat::intel_page），这里不再拼字符串。
// 值没变时不重写：位置一栏是列表，重写会重建行，正在输入的星系名会丢。

//! 「预警」页的位置、人名核对与星图数据。

use slint::{ComponentHandle, Model, ModelRc, VecModel};

use crate::{IntelLocationRow, IntelModel, SettingsWindow};

/// 「我的位置」的一行。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LocationView {
    /// 角色名。
    pub name: String,
    /// 位置文字。
    pub text: String,
    /// 有没有位置记录。
    pub has_location: bool,
    /// 上次输入的星系名查不到。
    pub not_found: bool,
}

/// 「预警」页要显示的运行时状态。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IntelView {
    /// 在线角色的位置，按名字排序。
    pub locations: Vec<LocationView>,
    /// 参考星系填了却查不到。
    pub reference_not_found: bool,
    /// 人名核对的状态文字；功能关着时为空。
    pub pilot_status: String,
    /// 人名缓存的条数文字；缓存文件还没读完时为空。
    pub pilot_cache: String,
    /// 星图数据一行的文字。
    pub static_data: String,
}

/// 把运行时状态显示到页上。只改变了的部分。
pub fn show_intel_view(ui: &SettingsWindow, view: &IntelView) {
    let model = ui.global::<IntelModel>();
    let rows: Vec<IntelLocationRow> = view
        .locations
        .iter()
        .map(|row| IntelLocationRow {
            name: row.name.as_str().into(),
            text: row.text.as_str().into(),
            has_location: row.has_location,
            not_found: row.not_found,
        })
        .collect();
    // 名字的集合不变时逐行改（行内的输入框保留），集合变了才整表换掉。
    let current = model.get_locations();
    let same_names =
        current.row_count() == rows.len() && current.iter().zip(&rows).all(|(old, new)| old.name == new.name);
    if same_names {
        for (index, row) in rows.into_iter().enumerate() {
            if current.row_data(index).as_ref() != Some(&row) {
                current.set_row_data(index, row);
            }
        }
    } else {
        model.set_locations(ModelRc::new(VecModel::from(rows)));
    }
    model.set_reference_not_found(view.reference_not_found);
    set_text(&model.get_pilot_status(), &view.pilot_status, |v| {
        model.set_pilot_status(v)
    });
    set_text(&model.get_pilot_cache(), &view.pilot_cache, |v| {
        model.set_pilot_cache(v)
    });
    set_text(&model.get_static_data(), &view.static_data, |v| {
        model.set_static_data(v)
    });
}

/// 文字变了才写：Slint 的属性每写一次都会重新排版与重画。
fn set_text(current: &str, wanted: &str, set: impl FnOnce(slint::SharedString)) {
    if current != wanted {
        set(wanted.into());
    }
}
