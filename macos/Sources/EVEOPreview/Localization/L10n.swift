// SPDX-License-Identifier: GPL-3.0-or-later
//
// 界面文字的入口（反馈文档 5.3 节）。界面有英、中、俄、日、韩、法、德、西 8 种语言，默认英文。
//
// 组织方式：文案写在 shared/l10n/ 的 TOML 里（架构文档 5.2 节），由 shared/tools/gen_l10n.py 生成 Generated/ 下的代码：
// 每个域一个协议，每种语言对每个协议各有一个不含存储属性的结构体，命名是「协议名 + 大写语言代码」，
// 如 `MenuStringsEN`、`SettingsStringsRU`；各域在 `L10n` 上的访问器（`L10n.menu`、`L10n.combat` 等）也是生成的。
// 某种语言漏了一条时生成器校验不过；CI 用 `gen_l10n.py --check` 核对生成结果没有过期。
// 改文案：改 TOML，运行 `python3 shared/tools/gen_l10n.py`，生成结果一起提交。
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
}

/// 秒数的数字部分：整数不带小数点，其余保留一位。生成的文案里 `{名字:secs}` 占位符用它，单位由各语言自己写。
func combatSecondsNumber(_ value: Double) -> String {
    // 时长已被校验夹到 1～10 秒；非有限值或过大的数不能转成 Int（会崩溃），按原样显示。
    guard value.isFinite, abs(value) < 1e9 else { return String(value) }
    return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}
