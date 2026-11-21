// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面语言（反馈文档 3.1 节、3.2 节、5.1 节）。
// AppLanguage 是界面实际使用的语言；LanguagePreference 是配置里的选项，多一个「跟随系统」。
// 加一种语言时两个枚举各加一个成员，再按编译错误补全各处 switch（反馈文档 5.3 节）。

import Foundation

/// 界面实际使用的语言。
public enum AppLanguage: String, Sendable, Codable, CaseIterable {
    /// 英文，默认语言。
    case en
    /// 中文（简体）。
    case zh
    /// 俄文。
    case ru
    /// 日文。
    case ja
    /// 韩文。
    case ko
    /// 法文。
    case fr
    /// 德文。
    case de
    /// 西班牙文。
    case es

    /// 语言的自称，不随界面语言变化：English、中文、Русский、日本語、한국어、Français、Deutsch、Español。
    public var autonym: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        case .ru: return "Русский"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        }
    }

    /// 按语言代码的第一个子标签找语言：去掉首尾空白并转小写，取第一个 `-` 或 `_` 之前的部分，
    /// 与某个受支持的代码完全相同时返回它。
    ///
    /// 例如 `zh-Hans-CN` 对应 `zh`，`ru-RU` 对应 `ru`，`zh_CN` 对应 `zh`，`de-DE` 对应 `de`；`it-IT` 与空串返回 nil。
    /// 只比子标签、不比前缀：`kok-IN`（孔卡尼语）、`rue`（卢森尼亚语）、`jam`、`zha` 不会被当成 ko、ru、ja、zh。
    static func matching(prefixOf code: String) -> AppLanguage? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let primary = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return allCases.first { $0.rawValue == primary }
    }
}

/// 配置里的语言选项（`general.language`），默认 `en`。
public enum LanguagePreference: String, Sendable, Codable, CaseIterable {
    /// 英文。
    case en
    /// 中文（简体）。
    case zh
    /// 俄文。
    case ru
    /// 日文。
    case ja
    /// 韩文。
    case ko
    /// 法文。
    case fr
    /// 德文。
    case de
    /// 西班牙文。
    case es
    /// 跟随系统的首选语言。
    case system

    /// 求出界面实际使用的语言（反馈文档 3.2 节）。
    ///
    /// 规则依次是：
    /// 1. `override`（环境变量 `EVEO_LANG`，只用于调试）的第一个子标签是受支持的语言代码时，返回该语言。
    /// 2. 选项不是 `system` 时，返回同名的语言。
    /// 3. 选项是 `system` 时，取 `preferredLanguages` 里第一个子标签是受支持语言代码的；都不匹配时返回 `en`。
    ///
    /// - Parameters:
    ///   - preferredLanguages: 系统的首选语言列表，通常是 `Locale.preferredLanguages`。
    ///   - override: 调试用的覆盖值；nil 或不认识的值被忽略。
    public func resolved(preferredLanguages: [String], override: String?) -> AppLanguage {
        if let override, let forced = AppLanguage.matching(prefixOf: override) { return forced }
        switch self {
        case .en: return .en
        case .zh: return .zh
        case .ru: return .ru
        case .ja: return .ja
        case .ko: return .ko
        case .fr: return .fr
        case .de: return .de
        case .es: return .es
        case .system:
            for code in preferredLanguages {
                if let language = AppLanguage.matching(prefixOf: code) { return language }
            }
            return .en
        }
    }
}
