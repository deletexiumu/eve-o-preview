// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断域的界面文字（v1.1 设计 11.4 节）：菜单栏的「报告问题…」与崩溃提示项、「通用」页的诊断一组、报告窗口与完成页。
// 每种语言一个不含存储属性的结构体实现本协议（Localization/<语言>/DiagnosticsStrings+<语言>.swift），
// 漏了一条时结构体不满足协议，编译不过。带参数的文字写成函数，各语言自己拼接（俄语的复数由俄语实现处理）。
// 访问方式是 L10n.diagnostics；它按 L10n.language 每次访问时取，切换语言后下次访问即是新语言。
//
// Issue 的标题与正文、压缩包里的文件一律用英文，不在这里（v1.1 设计 7.5 节）。

import Foundation

/// 诊断域的文字。
protocol DiagnosticsStrings: Sendable {
    // MARK: 菜单栏菜单
    /// 工具项「报告问题…」。
    var menuReportProblem: String { get }
    /// 顶部的提示项：上次意外退出，点开报告。
    var menuCrashPending: String { get }

    // MARK: 「通用」页的诊断一组
    /// 一组的标题。
    var sectionHeader: String { get }
    /// 「详细日志」开关。
    var verboseLoggingToggle: String { get }
    /// 「详细日志」的说明。
    var verboseLoggingHelp: String { get }
    /// 日志文件位置一行的标签。
    var logLocationLabel: String { get }
    /// 「在访达中显示日志」按钮。
    var showLogsButton: String { get }
    /// 「报告问题…」按钮。
    var reportButton: String { get }

    // MARK: 报告窗口的说明
    /// 窗口标题。
    var windowTitle: String { get }
    /// 手动情境的说明。
    var intro: String { get }
    /// 崩溃情境的说明。
    var crashIntro: String { get }
    /// 脱敏的说明。
    var redactionNote: String { get }

    // MARK: 报告窗口的文件列表与预览
    /// 文件列表的标题。
    var itemsHeader: String { get }
    /// `summary.md`。
    var itemSummary: String { get }
    /// `config-summary.json`。
    var itemConfig: String { get }
    /// 日志文件。
    var itemLog: String { get }
    /// 第 number 个崩溃报告。
    func itemCrash(_ number: Int) -> String
    /// `manifest.json`。
    var itemManifest: String { get }
    /// 预览只显示了开头时的说明。
    var previewTruncated: String { get }
    /// 替换次数，如「12 replacements」。
    func replacements(_ count: Int) -> String
    /// 收集中的进度文字。
    var collecting: String { get }

    // MARK: 报告窗口的按钮
    /// 「生成报告并打开 GitHub」。
    var createAndOpenButton: String { get }
    /// 「只生成报告」。
    var createOnlyButton: String { get }
    /// 「取消」（手动情境）。
    var cancelButton: String { get }
    /// 「以后再说」（崩溃情境）。
    var notNowButton: String { get }
    /// 「不报告」（崩溃情境）。
    var dontReportButton: String { get }

    // MARK: 完成页
    /// 完成页的标题。
    var doneTitle: String { get }
    /// 完成页的说明：把 zip 拖进浏览器里的 Issue 页面。
    var doneHelp: String { get }
    /// 「在访达中显示」。
    var revealButton: String { get }
    /// 「再次打开 GitHub」。
    var openIssueButton: String { get }
    /// 「关闭」。
    var closeButton: String { get }

    // MARK: 错误
    /// 生成失败，附原因（系统的说明，不翻译）。
    func createFailed(_ reason: String) -> String
}

extension L10n {
    /// 诊断域的文字。`switch` 不写 `default`：以后加语言时编译器会指出这里要补。
    static var diagnostics: any DiagnosticsStrings {
        switch L10n.language {
        case .en: return DiagnosticsStringsEN()
        case .zh: return DiagnosticsStringsZH()
        case .ru: return DiagnosticsStringsRU()
        case .ja: return DiagnosticsStringsJA()
        case .ko: return DiagnosticsStringsKO()
        case .fr: return DiagnosticsStringsFR()
        case .de: return DiagnosticsStringsDE()
        case .es: return DiagnosticsStringsES()
        }
    }
}
