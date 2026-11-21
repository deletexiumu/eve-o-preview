// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面文字的入口（反馈文档 5.3 节）。界面有英、中、俄、日、韩、法、德、西 8 种语言，默认英文。
//
// 组织方式：每个域一个协议（Strings.swift、SettingsStrings.swift，热键与战斗提醒的协议由各自的工作包定义），
// 每种语言对每个协议各有一个不含存储属性的结构体实现，放在 `Localization/<语言>/` 下。
// 某种语言漏了一条文字时，结构体不满足协议，编译不过；完整性由编译器保证，不靠运行时检查。
// 结构体的命名是「协议名 + 大写语言代码」，如 `MenuStringsEN`、`SettingsStringsRU`。
//
// 访问器每次被调用时按当前语言返回对应的结构体，所以语言切换后下次访问即取到新语言，不用重启。
// 访问器里的 switch 不写 default：以后加语言时，编译器会指出每一处要补的地方。
//
// 不用 `.strings` 资源：SwiftPM 的资源包放进手工组装的 .app 后，查找路径与签名都有额外问题（架构文档 7.4 节）。

import Foundation
import EVEOPreviewCore
import os

/// 界面文字表。
enum L10n {
    /// 应用名，菜单与窗口标题共用，不翻译。
    static let appName = "EVE-O Preview"

    /// 当前界面语言的存储。用锁保护，所以 `L10n` 不受 actor 隔离限制，可在任何线程读取。
    ///
    /// 初始值是英文。AppDelegate 在读完配置、建任何界面之前按 `general.language` 设置一次（反馈文档 5.4 节）。
    private static let languageStorage = OSAllocatedUnfairLock<AppLanguage>(initialState: .en)

    /// 当前界面语言。用锁保护，可在任何线程读取。
    static var language: AppLanguage {
        languageStorage.withLock { $0 }
    }

    /// 设置界面语言，返回语言是否变了。
    @discardableResult
    static func setLanguage(_ language: AppLanguage) -> Bool {
        languageStorage.withLock { current in
            guard current != language else { return false }
            current = language
            return true
        }
    }

    /// 把配置里的语言选项求成界面实际使用的语言。
    ///
    /// 环境变量 `EVEO_LANG`（只用于调试）优先；选项是「跟随系统」时看 `Locale.preferredLanguages`。
    /// 规则在 Core 的 `LanguagePreference.resolved`，启动时与配置变化时都经这里，两处结果一致。
    static func resolve(_ preference: LanguagePreference) -> AppLanguage {
        preference.resolved(preferredLanguages: Locale.preferredLanguages,
                            override: ProcessInfo.processInfo.environment["EVEO_LANG"])
    }

    /// 菜单栏菜单的文字。
    static var menu: any MenuStrings {
        switch language {
        case .en: return MenuStringsEN()
        case .zh: return MenuStringsZH()
        case .ru: return MenuStringsRU()
        case .ja: return MenuStringsJA()
        case .ko: return MenuStringsKO()
        case .fr: return MenuStringsFR()
        case .de: return MenuStringsDE()
        case .es: return MenuStringsES()
        }
    }

    /// 主菜单「编辑」菜单的文字。
    static var editMenu: any EditMenuStrings {
        switch language {
        case .en: return EditMenuStringsEN()
        case .zh: return EditMenuStringsZH()
        case .ru: return EditMenuStringsRU()
        case .ja: return EditMenuStringsJA()
        case .ko: return EditMenuStringsKO()
        case .fr: return EditMenuStringsFR()
        case .de: return EditMenuStringsDE()
        case .es: return EditMenuStringsES()
        }
    }

    /// 缩略图的右键菜单与占位文字。
    static var thumbnail: any ThumbnailStrings {
        switch language {
        case .en: return ThumbnailStringsEN()
        case .zh: return ThumbnailStringsZH()
        case .ru: return ThumbnailStringsRU()
        case .ja: return ThumbnailStringsJA()
        case .ko: return ThumbnailStringsKO()
        case .fr: return ThumbnailStringsFR()
        case .de: return ThumbnailStringsDE()
        case .es: return ThumbnailStringsES()
        }
    }

    /// 设置窗口的文字（「切换与热键」页与「提醒」页除外）。
    static var settings: any SettingsStrings {
        switch language {
        case .en: return SettingsStringsEN()
        case .zh: return SettingsStringsZH()
        case .ru: return SettingsStringsRU()
        case .ja: return SettingsStringsJA()
        case .ko: return SettingsStringsKO()
        case .fr: return SettingsStringsFR()
        case .de: return SettingsStringsDE()
        case .es: return SettingsStringsES()
        }
    }
}
