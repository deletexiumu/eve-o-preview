// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断域的德文文字（v1.1 设计 11.4 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 11.3 节的词表：报告 Bericht、崩溃报告 Absturzbericht（macOS 德文的说法）、日志 Protokoll、
// 占位符 Platzhalter；菜单项「报告问题…」用 „Problem melden …“，访达保留 Finder，压缩包写 ZIP-Datei。
// 德文与英文一样只区分单数与复数，由 replacements 直接判断。

import Foundation

/// 诊断域的德文文字。
struct DiagnosticsStringsDE: DiagnosticsStrings {
    // MARK: 菜单栏菜单
    var menuReportProblem: String { "Problem melden …" }
    // 「意外退出」取 macOS 德文崩溃对话框的说法 „wurde unerwartet beendet“。
    var menuCrashPending: String { "EVE-O Preview wurde unerwartet beendet – Melden …" }

    // MARK: 「通用」页的诊断一组
    var sectionHeader: String { "Diagnose" }
    var verboseLoggingToggle: String { "Ausführliche Protokollierung" }
    var verboseLoggingHelp: String {
        "Schreibt mehr Details in die Protokolldatei. Vor dem Nachstellen eines Problems einschalten."
    }
    var logLocationLabel: String { "Protokolldateien" }
    var showLogsButton: String { "Protokolle im Finder zeigen" }
    var reportButton: String { "Problem melden …" }

    // MARK: 报告窗口的说明
    var windowTitle: String { "Problem melden" }
    // 不称呼用户：「你自己把文件附到 Issue」改写成「附加由手动完成」。
    var intro: String {
        "Erstellt eine ZIP-Datei mit den unten aufgeführten Elementen. Nichts wird automatisch gesendet: "
            + "Das Anhängen an ein GitHub-Issue erfolgt von Hand."
    }
    var crashIntro: String {
        "EVE-O Preview wurde beim letzten Mal unerwartet beendet. Ein Bericht hilft, die Ursache zu beheben."
    }
    var redactionNote: String {
        "macOS-Benutzername, Computername und EVE-Charakternamen werden durch Platzhalter ersetzt."
    }

    // MARK: 报告窗口的文件列表与预览
    var itemsHeader: String { "Im Bericht enthalten" }
    var itemSummary: String { "Umgebungsübersicht" }
    var itemConfig: String { "Einstellungen (ohne Namen)" }
    var itemLog: String { "App-Protokoll" }
    func itemCrash(_ number: Int) -> String { "Absturzbericht \(number)" }
    var itemManifest: String { "Dateiliste" }
    var previewTruncated: String { "Nur der Anfang wird angezeigt. Der Bericht enthält die ganze Datei." }
    // 1 Ersetzung、2 Ersetzungen。
    func replacements(_ count: Int) -> String { count == 1 ? "1 Ersetzung" : "\(count) Ersetzungen" }
    var collecting: String { "Wird gesammelt …" }

    // MARK: 报告窗口的按钮
    var createAndOpenButton: String { "Bericht erstellen und GitHub öffnen" }
    var createOnlyButton: String { "Nur Bericht erstellen" }
    var cancelButton: String { "Abbrechen" }
    var notNowButton: String { "Nicht jetzt" }
    var dontReportButton: String { "Nicht melden" }

    // MARK: 完成页
    var doneTitle: String { "Bericht erstellt" }
    // 三步操作写成不定式，与其他说明的文体一致。
    var doneHelp: String {
        "Der Finder zeigt die ZIP-Datei. Diese in die Issue-Seite im Browser ziehen, das Geschehen beschreiben "
            + "und absenden."
    }
    var revealButton: String { "Im Finder zeigen" }
    var openIssueButton: String { "GitHub erneut öffnen" }
    var closeButton: String { "Schließen" }

    // MARK: 错误
    func createFailed(_ reason: String) -> String { "Der Bericht konnte nicht erstellt werden: \(reason)" }
}
