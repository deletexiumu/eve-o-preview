// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置方案的新建、克隆、改名、删除，对应 macOS 的 Config/ProfileEditor.swift（架构文档 5.2 节）。
// 都是纯函数：成功时返回改好的新配置，操作不合法时返回 None，原配置不变。
// 名称规则：去掉首尾空白后 1～64 字（按字素簇计），不区分大小写唯一。

//! 配置方案的增删改。

use crate::config::{MAX_PROFILE_NAME_LENGTH, new_id};
use crate::model::{AppConfig, Profile};
use crate::support::text;

/// 名称是否可用。比较前去掉首尾空白；`excluding` 是比较时排除的配置方案 id（改名时传被改名的方案，
/// 使「改回原名」或只改大小写合法），`None` 表示不排除。
pub fn is_valid_name(name: &str, config: &AppConfig, excluding: Option<&str>) -> bool {
    let candidate = text::trim_whitespace_and_newlines(name);
    let length = text::char_count(candidate);
    if !(1..=MAX_PROFILE_NAME_LENGTH).contains(&length) {
        return false;
    }
    !config.profiles.iter().any(|profile| {
        Some(profile.id.as_str()) != excluding
            && text::eq_ignore_case(text::trim_whitespace_and_newlines(&profile.name), candidate)
    })
}

/// 新建一个全部取默认值的配置方案（见 [`Profile::make_new`]），追加到末尾，不切换当前方案。名称非法时返回 `None`。
pub fn add(name: &str, config: &AppConfig) -> Option<AppConfig> {
    add_with_id(name, config, new_id())
}

/// 同 [`add`]，新方案的 id 由调用方给出（测试用）。
pub fn add_with_id(name: &str, config: &AppConfig, id: String) -> Option<AppConfig> {
    if !is_valid_name(name, config, None) {
        return None;
    }
    let mut result = config.clone();
    result
        .profiles
        .push(Profile::make_new(id, text::trim_whitespace_and_newlines(name)));
    Some(result)
}

/// 复制一个配置方案，内容相同、id 与名称不同，插在原方案之后，不切换当前方案。
/// 源方案不存在或名称非法时返回 `None`。
pub fn clone_profile(id: &str, new_name: &str, config: &AppConfig) -> Option<AppConfig> {
    let index = config.profiles.iter().position(|p| p.id == id)?;
    if !is_valid_name(new_name, config, None) {
        return None;
    }
    let mut copy = config.profiles[index].clone();
    copy.id = new_id();
    copy.name = text::trim_whitespace_and_newlines(new_name).to_owned();
    let mut result = config.clone();
    result.profiles.insert(index + 1, copy);
    Some(result)
}

/// 给配置方案改名。方案不存在或名称非法时返回 `None`；新名称与自己的旧名称只差大小写时合法。
pub fn rename(id: &str, name: &str, config: &AppConfig) -> Option<AppConfig> {
    let index = config.profiles.iter().position(|p| p.id == id)?;
    if !is_valid_name(name, config, Some(id)) {
        return None;
    }
    let mut result = config.clone();
    result.profiles[index].name = text::trim_whitespace_and_newlines(name).to_owned();
    Some(result)
}

/// 删除配置方案。最后一个不能删，方案不存在时也返回 `None`。
///
/// 删除的是当前方案时，当前方案改为删除位置上的下一个方案；删的是末尾的方案时改为新的末尾。
pub fn delete(id: &str, config: &AppConfig) -> Option<AppConfig> {
    if config.profiles.len() <= 1 {
        return None;
    }
    let index = config.profiles.iter().position(|p| p.id == id)?;
    let mut result = config.clone();
    result.profiles.remove(index);
    if config.active_profile_id == id {
        result.active_profile_id = result.profiles[index.min(result.profiles.len() - 1)].id.clone();
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个方案 A、B，当前是 A。
    fn sample() -> AppConfig {
        AppConfig {
            active_profile_id: "a".into(),
            profiles: vec![Profile::new("a", "Alpha"), Profile::new("b", "Bravo")],
            ..AppConfig::default()
        }
    }

    /// 名称规则：空白、超长、不区分大小写重名都不合法；改名时排除自己。
    #[test]
    fn name_rules() {
        let config = sample();
        assert!(is_valid_name(" Charlie ", &config, None));
        assert!(!is_valid_name("   ", &config, None));
        assert!(!is_valid_name(&"x".repeat(65), &config, None));
        assert!(is_valid_name(&"x".repeat(64), &config, None));
        assert!(!is_valid_name("ALPHA", &config, None));
        assert!(is_valid_name("ALPHA", &config, Some("a")));
    }

    /// 新建追加到末尾、带默认热键，不切换当前方案。
    #[test]
    fn add_appends() {
        let result = add_with_id(" Charlie ", &sample(), "c".into()).unwrap();
        assert_eq!(result.profiles[2].name, "Charlie");
        assert!(!result.profiles[2].hotkeys.toggle_hide_all.is_empty());
        assert_eq!(result.active_profile_id, "a");
        assert!(add("bravo", &sample()).is_none());
    }

    /// 克隆插在原方案之后，id 不同。
    #[test]
    fn clone_inserts_after_source() {
        let result = clone_profile("a", "Alpha 2", &sample()).unwrap();
        let names: Vec<_> = result.profiles.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Alpha", "Alpha 2", "Bravo"]);
        assert_ne!(result.profiles[1].id, "a");
        assert!(clone_profile("zz", "X", &sample()).is_none());
    }

    /// 改名：只差大小写合法，与别的方案重名不合法。
    #[test]
    fn rename_rules() {
        assert_eq!(rename("a", "ALPHA", &sample()).unwrap().profiles[0].name, "ALPHA");
        assert!(rename("a", "bravo", &sample()).is_none());
    }

    /// 删除：最后一个不能删；删当前方案时改到下一个，删末尾时改到新的末尾。
    #[test]
    fn delete_rules() {
        let result = delete("a", &sample()).unwrap();
        assert_eq!(result.active_profile_id, "b");
        let mut config = sample();
        config.active_profile_id = "b".into();
        assert_eq!(delete("b", &config).unwrap().active_profile_id, "a");
        assert!(delete("a", &result).is_none());
        assert!(delete("zz", &sample()).is_none());
    }
}
