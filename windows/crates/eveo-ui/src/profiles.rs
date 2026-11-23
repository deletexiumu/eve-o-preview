// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「配置方案」页的绑定：方案列表的显示、名称的校验与提示、页上的操作作用到配置。
// 与其他页不同，这一页改的是整份配置（方案列表与当前方案），不是当前方案里的值，所以函数都以 AppConfig 为单位。
// 名称规则与增删改都用 Core 的 profile_editor，与 macOS 一致；这里只把「为什么不行」翻成界面上的话。
// 新建方案的默认值由应用给出（Windows 的默认热键在 app-core 里），绑定层不依赖 app-core。

//! 「配置方案」页。

use std::rc::Rc;

use slint::{ComponentHandle, Model, ModelRc, VecModel};

use eveo_core::config::profile_editor;
use eveo_core::model::{AppConfig, Profile};

use crate::{ProfileRow, ProfilesModel, SettingsWindow};

/// 页上的一个操作，由应用作用到协调器手里的配置。
#[derive(Debug, Clone, PartialEq)]
pub enum ProfileEdit {
    /// 切换到某个方案。
    Switch(String),
    /// 新建方案：`template` 是应用按 Windows 默认值建好的方案（id 已定），名称取 `name`。
    Add {
        /// 新方案的默认内容。
        template: Box<Profile>,
        /// 用户输入的名称。
        name: String,
    },
    /// 给方案改名。
    Rename {
        /// 方案 id。
        id: String,
        /// 新名称。
        name: String,
    },
    /// 复制方案，副本插在原方案之后。
    Clone {
        /// 源方案 id。
        id: String,
        /// 副本的名称。
        name: String,
    },
    /// 删除方案。
    Delete(String),
}

/// 页上正在进行的名称编辑，从 ProfilesModel 读出。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NameEdit {
    /// 编辑的种类："add"、"rename" 或 "clone"。
    pub mode: String,
    /// 被改名或复制的方案 id；新建时是 "new"。
    pub id: String,
    /// 输入框里的名称。
    pub name: String,
}

impl NameEdit {
    /// 转成配置操作。新建要用的默认方案由 `template` 现建（只在新建时调用，id 每次不同）。
    /// 编辑种类不认识时返回 `None`。
    pub fn to_edit(&self, template: impl FnOnce() -> Profile) -> Option<ProfileEdit> {
        // 名称原样交给 profile_editor，去空白与校验都在那边做。
        let (id, name) = (self.id.clone(), self.name.clone());
        match self.mode.as_str() {
            "add" => Some(ProfileEdit::Add {
                template: Box::new(template()),
                name,
            }),
            "rename" => Some(ProfileEdit::Rename { id, name }),
            "clone" => Some(ProfileEdit::Clone { id, name }),
            _ => None,
        }
    }
}

/// 读出页上正在进行的名称编辑；不在编辑时返回 `None`。
pub fn name_edit(ui: &SettingsWindow) -> Option<NameEdit> {
    let model = ui.global::<ProfilesModel>();
    let id = model.get_editing_id().to_string();
    if id.is_empty() {
        return None;
    }
    Some(NameEdit {
        mode: model.get_editing_mode().into(),
        id,
        name: model.get_editing_name().into(),
    })
}

/// 结束名称编辑：清掉页上的编辑状态与问题提示。操作成功后由应用调用。
pub fn finish_edit(ui: &SettingsWindow) {
    let model = ui.global::<ProfilesModel>();
    model.set_editing_id("".into());
    model.set_editing_mode("".into());
    model.set_editing_name("".into());
    model.set_name_error("".into());
}

/// 名称的问题，界面上的说法；可用时返回空串。规则同 [`profile_editor::is_valid_name`]：
/// 去掉首尾空白后 1～64 字，不区分大小写唯一；改名时排除被改名的方案自己。
pub fn name_problem(config: &AppConfig, edit: &NameEdit) -> String {
    // 只有改名排除自己：新建与复制都不能与任何现有方案重名。
    let excluding = (edit.mode == "rename").then_some(edit.id.as_str());
    if profile_editor::is_valid_name(&edit.name, config, excluding) {
        return String::new();
    }
    // 空、太长、重名都显示同一句规则（与 macOS 相同），用户一看就知道怎么改。
    eveo_l10n::settings(crate::language())
        .profile_name_rule()
        .to_owned()
}

/// 把操作作用到配置上，返回新配置；操作不合法（名称不可用、方案不存在、删最后一个）时返回 `None`，原配置不变。
pub fn apply_profile_edit(config: &AppConfig, edit: &ProfileEdit) -> Option<AppConfig> {
    match edit {
        // 切换只改当前方案的 id；不存在的方案不切。
        ProfileEdit::Switch(id) => {
            if !config.profiles.iter().any(|p| &p.id == id) {
                return None;
            }
            // 在副本上改，原配置保持不变（与 profile_editor 的约定相同）。
            let mut result = config.clone();
            result.active_profile_id = id.clone();
            Some(result)
        }
        // 新建：名称规则交给 profile_editor，再换上应用给的默认内容（Windows 的默认热键）。新方案追加到末尾，不切换。
        ProfileEdit::Add { template, name } => {
            let mut result = profile_editor::add_with_id(name, config, template.id.clone())?;
            let added = result.profiles.last_mut()?;
            let trimmed = std::mem::take(&mut added.name);
            *added = (**template).clone();
            added.name = trimmed;
            Some(result)
        }
        ProfileEdit::Rename { id, name } => profile_editor::rename(id, name, config),
        ProfileEdit::Clone { id, name } => profile_editor::clone_profile(id, name, config),
        ProfileEdit::Delete(id) => profile_editor::delete(id, config),
    }
}

/// 把配置的方案列表与配置文件路径显示到页上。行没变时不碰模型（刷新很频繁，见应用的 refresh_settings_pages）。
/// 正在编辑或待删除的方案已经不在了（例如别处删掉了）时，取消那次编辑。
pub fn show_profiles(ui: &SettingsWindow, config: &AppConfig, config_path: &str) {
    let model = ui.global::<ProfilesModel>();
    // 当前方案只看 active_profile_id；id 找不到时没有一行标成当前。
    let rows: Vec<ProfileRow> = config
        .profiles
        .iter()
        .map(|p| ProfileRow {
            id: p.id.as_str().into(),
            name: p.name.as_str().into(),
            active: p.id == config.active_profile_id,
        })
        .collect();
    let current = model.get_profiles();
    // 方案很少（通常不到十个），整份比较、变了整份换掉即可，不必逐行同步。
    if !current.iter().eq(rows.iter().cloned()) {
        model.set_profiles(ModelRc::from(Rc::new(VecModel::from(rows))));
    }
    if model.get_config_path() != config_path {
        model.set_config_path(config_path.into());
    }
    // 编辑或待删除的目标不在了：清掉状态，否则确定按钮会作用到不存在的方案。
    // 新建（"new"）不对应现有方案，不受影响。
    let exists = |id: &str| config.profiles.iter().any(|p| p.id == id);
    let editing = model.get_editing_id();
    if !editing.is_empty() && editing != "new" && !exists(&editing) {
        finish_edit(ui);
    }
    let pending = model.get_pending_delete();
    if !pending.is_empty() && !exists(&pending) {
        model.set_pending_delete("".into());
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// 两个方案 Alpha、Bravo，当前是 Alpha。
    fn sample() -> AppConfig {
        AppConfig {
            active_profile_id: "a".into(),
            profiles: vec![Profile::new("a", "Alpha"), Profile::new("b", "Bravo")],
            ..AppConfig::default()
        }
    }

    /// 一次名称编辑。
    fn edit(mode: &str, id: &str, name: &str) -> NameEdit {
        NameEdit {
            mode: mode.into(),
            id: id.into(),
            name: name.into(),
        }
    }

    /// 名称的问题：空、超长、重名都显示规则；改名时自己的旧名（含只改大小写）可用。
    #[test]
    fn name_problems() {
        let config = sample();
        let rule = eveo_l10n::settings(crate::language()).profile_name_rule();
        assert_eq!(name_problem(&config, &edit("add", "new", "  ")), rule);
        assert!(name_problem(&config, &edit("add", "new", &"字".repeat(65))).contains("64"));
        assert_eq!(name_problem(&config, &edit("add", "new", &"字".repeat(64))), "");
        assert_eq!(name_problem(&config, &edit("clone", "a", "bravo")), rule);
        assert_eq!(name_problem(&config, &edit("rename", "a", "ALPHA")), "");
        assert_ne!(name_problem(&config, &edit("rename", "a", "Bravo")), "");
    }

    /// 各种操作作用到配置：新建用应用给的默认内容、复制插在原方案之后、切换与删除改当前方案。
    #[test]
    fn edits_change_config() {
        let config = sample();
        // 新建：名称去掉首尾空白，内容来自模板（这里用热键区分），不切换。
        let mut template = Profile::make_new("c", "");
        template.hotkeys.toggle_hide_all = vec!["F9".to_owned()];
        let add = edit("add", "new", " Charlie ")
            .to_edit(|| template.clone())
            .unwrap();
        let added = apply_profile_edit(&config, &add).unwrap();
        let charlie = added.profiles.last().unwrap();
        assert_eq!((charlie.id.as_str(), charlie.name.as_str()), ("c", "Charlie"));
        assert_eq!(charlie.hotkeys.toggle_hide_all, ["F9"]);
        assert_eq!(added.active_profile_id, "a");
        // 重名的新建不做。
        let duplicate = edit("add", "new", "alpha").to_edit(|| template.clone()).unwrap();
        assert!(apply_profile_edit(&config, &duplicate).is_none());

        // 复制：副本紧跟在原方案之后。
        let cloned = apply_profile_edit(
            &config,
            &ProfileEdit::Clone {
                id: "a".into(),
                name: "Alpha 副本".into(),
            },
        )
        .unwrap();
        assert_eq!(cloned.profiles[1].name, "Alpha 副本");

        // 改名、切换、删除当前方案（当前方案移到下一个）。
        let renamed = apply_profile_edit(
            &config,
            &ProfileEdit::Rename {
                id: "b".into(),
                name: "Beta".into(),
            },
        )
        .unwrap();
        assert_eq!(renamed.profiles[1].name, "Beta");
        let switched = apply_profile_edit(&config, &ProfileEdit::Switch("b".into())).unwrap();
        assert_eq!(switched.active_profile_id, "b");
        assert!(apply_profile_edit(&config, &ProfileEdit::Switch("nope".into())).is_none());
        let deleted = apply_profile_edit(&config, &ProfileEdit::Delete("a".into())).unwrap();
        assert_eq!(deleted.active_profile_id, "b");
        // 最后一个不能删。
        assert!(apply_profile_edit(&deleted, &ProfileEdit::Delete("b".into())).is_none());
        // 不认识的编辑种类不转换。
        assert!(edit("move", "a", "x").to_edit(|| template.clone()).is_none());
    }

    /// 页面内容：行与当前标记、路径；编辑中的方案被删后编辑取消。由 bind 的 Slint 用例调用。
    pub(crate) fn check_page(ui: &SettingsWindow) {
        let config = sample();
        show_profiles(ui, &config, "C:\\config.json");
        let model = ui.global::<ProfilesModel>();
        let rows: Vec<ProfileRow> = model.get_profiles().iter().collect();
        assert_eq!(rows.len(), 2);
        assert!(rows[0].active && !rows[1].active);
        assert_eq!(model.get_config_path(), "C:\\config.json");

        // 开始给 Bravo 改名：页面函数记下状态，读出的编辑与之一致。
        model.invoke_start_edit("rename".into(), "b".into(), "Bee".into());
        assert_eq!(name_edit(ui), Some(edit("rename", "b", "Bee")));

        // Bravo 在别处被删掉：刷新时编辑取消。
        let deleted = apply_profile_edit(&config, &ProfileEdit::Delete("b".into())).unwrap();
        show_profiles(ui, &deleted, "C:\\config.json");
        assert_eq!(name_edit(ui), None);
        assert_eq!(model.get_profiles().row_count(), 1);
    }
}
