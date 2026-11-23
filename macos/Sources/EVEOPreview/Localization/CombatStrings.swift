// SPDX-License-Identifier: GPL-3.0-or-later
//
// 战斗提醒域的界面文字（反馈文档 5.3 节）：设置窗口「提醒」页的全部文字。
// 每种语言一个不含存储属性的结构体实现本协议（Localization/<语言>/CombatStrings+<语言>.swift），
// 漏了一条时结构体不满足协议，编译不过。带参数的文字写成函数，各语言自己拼接（俄语的复数由俄语实现处理）。
// 访问方式是 L10n.combat；它按 L10n.language 每次访问时取，切换语言后下次访问即是新语言。

import Foundation

/// 「提醒」页的文字。
protocol CombatStrings: Sendable {
    // MARK: 页头
    /// 页标题下的一句说明。
    var pageSubtitle: String { get }

    // MARK: 开关与状态行
    /// 总开关。
    var enableToggle: String { get }
    /// 状态行的标签。
    var statusLabel: String { get }
    /// 状态：未启用。
    var statusStopped: String { get }
    /// 状态：监视中，附目录与跟踪的文件数。
    func statusWatching(directory: String, files: Int) -> String
    /// 状态：找不到日志目录，附查找的路径。
    func statusDirectoryNotFound(_ path: String) -> String
    /// 状态：没有访问权限，附目录。
    func statusAccessDenied(_ path: String) -> String
    /// 没有访问权限时的说明（「文件与文件夹」权限）。
    var accessDeniedHelp: String { get }
    /// 「打开系统设置」按钮。
    var openSystemSettings: String { get }

    // MARK: 日志目录
    /// 日志目录一组的标题。
    var logDirectoryHeader: String { get }
    /// 日志目录一行的标签。
    var logDirectoryLabel: String { get }
    /// 没有指定目录时，路径后面的「自动」标注。
    var automaticSuffix: String { get }
    /// 「选择…」按钮。
    var chooseDirectory: String { get }
    /// 「使用自动位置」按钮。
    var useAutomaticLocation: String { get }
    /// 选择目录的对话框里的说明。
    var chooseDirectoryMessage: String { get }

    // MARK: 闪烁的外观
    /// 外观一组的标题。
    var appearanceHeader: String { get }
    /// 闪烁颜色。
    var flashColor: String { get }
    /// 持续时间。
    var duration: String { get }
    /// 秒数的显示，如「3.5 秒」。
    func seconds(_ value: Double) -> String
    /// 样式。
    var style: String { get }
    /// 样式：边框。
    var styleBorder: String { get }
    /// 样式：底色。
    var styleWash: String { get }
    /// 样式：两者。
    var styleBoth: String { get }

    // MARK: 触发条件
    /// 触发条件一组的标题。
    var triggersHeader: String { get }
    /// 「未命中的攻击也提醒」开关。
    var includeMisses: String { get }
    /// 最小伤害。
    var minimumDamage: String { get }
    /// 最小伤害的说明。
    var minimumDamageHelp: String { get }

    // MARK: 测试与说明
    /// 「测试闪烁」按钮。
    var testFlash: String { get }
    /// 「测试闪烁」的说明。
    var testFlashHelp: String { get }
    /// 页尾的说明：游戏日志的设置与只读的承诺。
    var footnote: String { get }
}

extension L10n {
    /// 战斗提醒域的文字。`switch` 不写 `default`：以后加语言时编译器会指出这里要补。
    static var combat: any CombatStrings {
        switch L10n.language {
        case .en: return CombatStringsEN()
        case .zh: return CombatStringsZH()
        case .ru: return CombatStringsRU()
        case .ja: return CombatStringsJA()
        case .ko: return CombatStringsKO()
        case .fr: return CombatStringsFR()
        case .de: return CombatStringsDE()
        case .es: return CombatStringsES()
        }
    }
}

/// 秒数的数字部分：整数不带小数点，其余保留一位。各语言共用，单位由各语言自己拼。
func combatSecondsNumber(_ value: Double) -> String {
    // 时长已被校验夹到 1～10 秒；非有限值或过大的数不能转成 Int（会崩溃），按原样显示。
    guard value.isFinite, abs(value) < 1e9 else { return String(value) }
    return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}
