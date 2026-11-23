// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面语言，对应 macOS 的 Model/AppLanguage.swift。
// AppLanguage 是界面实际使用的语言；LanguagePreference 是配置里的选项，多一个「跟随系统」。

use crate::support::StringEnum;

string_enum! {
    /// 界面实际使用的语言。
    pub enum AppLanguage {
        /// 英文，默认语言。
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

impl AppLanguage {
    /// 语言的自称，不随界面语言变化。
    pub fn autonym(self) -> &'static str {
        match self {
            AppLanguage::En => "English",
            AppLanguage::Zh => "中文",
            AppLanguage::Ru => "Русский",
            AppLanguage::Ja => "日本語",
            AppLanguage::Ko => "한국어",
            AppLanguage::Fr => "Français",
            AppLanguage::De => "Deutsch",
            AppLanguage::Es => "Español",
        }
    }

    /// 按语言代码的第一个子标签找语言：去掉首尾空白并转小写，取第一个 `-` 或 `_` 之前的部分，
    /// 与某个受支持的代码完全相同时返回它。
    ///
    /// 例如 `zh-Hans-CN`、`zh_CN` 对应 `zh`；`it-IT` 与空串返回 `None`。
    /// 只比子标签、不比前缀：`kok-IN`、`rue` 不会被当成 ko、ru。
    pub fn matching_prefix_of(code: &str) -> Option<AppLanguage> {
        let normalized = code.trim().to_lowercase();
        let primary = normalized
            .split(['-', '_'])
            .find(|part| !part.is_empty())
            .unwrap_or("");
        Self::from_raw(primary)
    }
}

string_enum! {
    /// 配置里的语言选项（`general.language`），默认 `en`。
    pub enum LanguagePreference {
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
        /// 跟随系统的首选语言。
        System => "system",
    }
}

impl LanguagePreference {
    /// 求出界面实际使用的语言。
    ///
    /// 1. `override_code`（环境变量 `EVEO_LANG`，只用于调试）的第一个子标签是受支持的语言代码时，返回该语言。
    /// 2. 选项不是 `system` 时，返回同名的语言。
    /// 3. 选项是 `system` 时，取 `preferred` 里第一个子标签受支持的语言；都不匹配时返回 `en`。
    pub fn resolved(self, preferred: &[String], override_code: Option<&str>) -> AppLanguage {
        if let Some(forced) = override_code.and_then(AppLanguage::matching_prefix_of) {
            return forced;
        }
        if let Some(language) = AppLanguage::from_raw(self.raw()) {
            return language;
        }
        preferred
            .iter()
            .find_map(|code| AppLanguage::matching_prefix_of(code))
            .unwrap_or(AppLanguage::En)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 子标签匹配，不按前缀匹配。
    #[test]
    fn matching_subtags() {
        assert_eq!(
            AppLanguage::matching_prefix_of("zh-Hans-CN"),
            Some(AppLanguage::Zh)
        );
        assert_eq!(AppLanguage::matching_prefix_of(" ZH_cn "), Some(AppLanguage::Zh));
        assert_eq!(AppLanguage::matching_prefix_of("kok-IN"), None);
        assert_eq!(AppLanguage::matching_prefix_of("it-IT"), None);
        assert_eq!(AppLanguage::matching_prefix_of(""), None);
    }

    /// 覆盖值、固定选项与跟随系统。
    #[test]
    fn resolution() {
        let preferred = vec!["it-IT".to_owned(), "ja-JP".to_owned()];
        assert_eq!(LanguagePreference::De.resolved(&preferred, None), AppLanguage::De);
        assert_eq!(
            LanguagePreference::System.resolved(&preferred, None),
            AppLanguage::Ja
        );
        assert_eq!(LanguagePreference::System.resolved(&[], None), AppLanguage::En);
        assert_eq!(
            LanguagePreference::De.resolved(&preferred, Some("ru")),
            AppLanguage::Ru
        );
        assert_eq!(
            LanguagePreference::De.resolved(&preferred, Some("xx")),
            AppLanguage::De
        );
    }
}
